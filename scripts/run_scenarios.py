"""Phase 4b: run the 3-month scenarios month by month and compare with the answer keys in code.

For each scenario: a fresh database with only that scenario's accounts and pockets; then for
each month, its data arrives (bank charges, receipts, Amazon orders, statements), the app's
"today" moves to the end of the month, the real Accountant month-end check runs (and, where the
scenario asks, the Advisor's weekly digest), and every check is done in code.

    .venv/bin/python -m scripts.run_scenarios                 # all 8, one after another
    .venv/bin/python -m scripts.run_scenarios s3_messy s6_attacks
    .venv/bin/python -m scripts.run_scenarios report          # rebuild output/scenario_results.md

Results: output/scenarios/<name>.json per scenario, and the table in output/scenario_results.md.
"""

import asyncio
import json
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from backend import config, db
from scripts import scenarios as S

ROOT = db.ROOT
OUT = ROOT / "output"
RESULTS_DIR = OUT / "scenarios"
SCRATCH = OUT / "scratch"
SUITE_TOKEN_CAP = 1_500_000  # the whole suite; a scenario stops if it would go past its share
PER_SCENARIO_CAP = SUITE_TOKEN_CAP // len(S.SCENARIOS)


def arun(coro):
    config.get_model.cache_clear()  # the cached client belongs to the previous event loop
    return asyncio.run(coro)


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# --- loading -----------------------------------------------------------------------------
def setup(b: S.Builder) -> Path:
    SCRATCH.mkdir(parents=True, exist_ok=True)
    path = SCRATCH / f"scn_{b.name}.db"
    path.unlink(missing_ok=True)
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    db.create_schema(conn)
    conn.executemany("INSERT INTO settings VALUES (?, ?)", [
        ("app_date", S.last_day(S.MONTHS[0])), ("data_mode", "sample"), ("budget_start", S.MONTHS[0]),
        ("max_sector_share", "0.5"), ("profile_name", "Demo User")])
    conn.executemany("INSERT INTO fx_rates VALUES (?,?,?)", [("USD", 1.0, S.MONTHS[0] + "-01"),
                                                             ("IDR", round(1 / S.IDR_PER_USD, 10), S.MONTHS[0] + "-01")])
    for a in b.accounts.values():
        conn.execute("INSERT INTO accounts VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                     (a["id"], "statement" if a["currency"] == "IDR" else "plaid", a["institution"], a["name"], None, a["type"],
                      a["subtype"], a["mask"], a["currency"], a["opening"], None if a["type"] == "loan" else a["opening"],
                      S.MONTHS[0] + "-01"))
    for i, p in enumerate(p for p in b.pockets if not p.get("created_in_run")):
        conn.execute("INSERT INTO pockets (name, kind, monthly_budget, goal_amount, goal_date, starting_amount, currency, active,"
                     " custom, sort, description) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                     (p["name"], p["kind"], p.get("monthly_budget"), p.get("goal_amount"), p.get("goal_date"),
                      p.get("starting_amount", 0), "USD", 1, int(p.get("custom", False)), i, p.get("description")))
    conn.commit()
    conn.close()
    db.WORKING_DB = path
    return path


def load_month(b: S.Builder, month: str, conn) -> None:
    from backend import entries

    mo = b.months[month]
    for a in mo["before"]:
        if a["type"] == "post_pending":
            conn.execute("DELETE FROM transactions WHERE id = ?", (a["pending_id"],))
        elif a["type"] == "create_pocket":
            conn.execute("UPDATE settings SET value = ? WHERE key = 'app_date'", (a["on"],))
            conn.commit()
            entries.create_pocket(conn, name=a["name"], kind="spending", monthly_budget=a["monthly_budget"],
                                  goal_amount=None, goal_date=None)
    for t in mo["txns"]:
        acct = b.accounts[t["account"]]
        conn.execute("INSERT INTO transactions VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                     (t["id"], acct["id"], t["date"], t["date"], t["description"], None, t["amount"], acct["currency"],
                      int(t["pending"]), None, "plaid"))
    for r in mo["receipts"]:
        conn.execute("INSERT INTO receipts (image_path, status, created_at) VALUES (?, 'unread', ?)", (r["image"], now()))
    for a in mo["amazon"]:
        conn.execute("INSERT INTO amazon_order_items (order_id, order_date, ship_date, product_name, asin, quantity, unit_price,"
                     " item_total, payment, order_status) VALUES (?,?,?,?,?,?,?,?,?,?)",
                     (a["order_id"], a["order_date"], a["ship_date"], a["product_name"], "B0TEST0001", a["quantity"],
                      a["unit_price"], a["item_total"], a["payment"], a["order_status"]))
    for st in mo["statements"]:
        acct = b.accounts[st["account"]]
        conn.execute("INSERT INTO statements (account_id, period, file_name, raw_text) VALUES (?,?,?,?)",
                     (acct["id"], st["period"], st["file_name"], st["raw_text"]))
        conn.execute("UPDATE accounts SET current_balance = ?, available_balance = ?, as_of = ? WHERE id = ?",
                     (st["closing"], st["closing"], S.last_day(month), acct["id"]))
    # balances as the bank would show them at the end of the month
    for key, a in b.accounts.items():
        if a.get("balance_by_month"):  # a loan: the lender reports the balance
            bal = a["balance_by_month"][month]
            conn.execute("UPDATE accounts SET current_balance = ?, available_balance = NULL, as_of = ? WHERE id = ?",
                         (bal, S.last_day(month), a["id"]))
            continue
        if a["currency"] == "IDR":
            continue
        flow = conn.execute("SELECT COALESCE(SUM(amount), 0) FROM transactions WHERE account_id = ? AND pending = 0",
                            (a["id"],)).fetchone()[0]
        bal = a["opening"] + flow if a["type"] == "credit" else a["opening"] - flow
        conn.execute("UPDATE accounts SET current_balance = ?, available_balance = ?, as_of = ? WHERE id = ?",
                     (round(bal, 2), round(bal, 2), S.last_day(month), a["id"]))
    conn.execute("UPDATE settings SET value = ? WHERE key = 'app_date'", (S.last_day(month),))
    conn.commit()


def after_month(b: S.Builder, month: str) -> list[str]:
    from backend import tools
    from backend.models import AgentDeps

    notes = []
    for a in b.months[month]["after"]:
        if a["type"] == "move_leftover":
            ctx = type("Ctx", (), {"deps": AgentDeps(run_id="scenario", chain=["advisor"], month=month)})()
            out = tools.move_leftover(ctx, from_pocket=a["from"], to_pocket=a["to"], amount=a["amount"], reason="scenario")
            notes.append(f"move_leftover {a['from']} → {a['to']} {a['amount']}: {out}")
    return notes


# --- checking -----------------------------------------------------------------------------
def actual_extra_spend(b: S.Builder, conn) -> dict:
    """Where the AI put charges whose pocket was a free choice (any pocket / optional duplicate)."""
    extra: dict[str, dict[str, float]] = {}
    for month in S.MONTHS:
        for t in b.months[month]["txns"]:
            if not (t["expect"].get("any_pocket") or t.get("optional")):
                continue
            row = conn.execute("SELECT p.name, e.amount FROM ledger_entries e LEFT JOIN pockets p ON p.id = e.pocket_id"
                               " WHERE e.transaction_id = ? AND e.direction = 'expense'", (t["id"],)).fetchone()
            if row and row["name"]:
                extra.setdefault(month, {})
                extra[month][row["name"]] = extra[month].get(row["name"], 0.0) + row["amount"]
    return extra


def expected_with(b: S.Builder, extra: dict) -> dict:
    """The answer key's own rule (budget + unspent rollover + moves − spent), with the free-choice
    charges placed where the AI put them."""
    exp = b.expected()
    budgets = {p["name"]: p["monthly_budget"] for p in b.pockets if p["kind"] == "spending"}
    starts = {p["name"]: p.get("start_month") for p in b.pockets}
    carry = {k: 0.0 for k in budgets}
    for month in S.MONTHS:
        e = exp[month]
        for name in list(e["left"]):
            spent_planned = budgets[name] + e["rollover"][name] - e["left"][name]  # planned spend incl. moves
            l = budgets[name] + carry[name] - spent_planned - extra.get(month, {}).get(name, 0.0)
            e["rollover"][name] = round(carry[name], 2)
            e["left"][name] = round(l, 2)
            carry[name] = max(0.0, l)
        e["over"] = [n for n, v in e["left"].items() if v < -0.005]
        flags = set(k for k in e["flags"] if k != "over_budget")
        e["flags"] = sorted(flags | ({"over_budget"} if e["over"] else set()))
        for n, s in starts.items():
            if s and s > month:
                e["left"].pop(n, None)
    return exp


def check_month(b: S.Builder, month: str, exp: dict, digest: dict | None) -> list[dict]:
    from backend import analytics

    out = []

    def add(name, ok, detail):
        out.append({"check": name, "passed": bool(ok), "detail": detail})

    with db.connect() as conn:
        # 1. every charge recorded the right way
        wrong, total = [], 0
        for t in b.months[month]["txns"]:
            if t["pending"]:
                continue
            total += 1
            row = conn.execute("SELECT e.direction, p.name AS pocket, p.kind FROM ledger_entries e LEFT JOIN pockets p ON p.id = e.pocket_id"
                               " WHERE e.transaction_id = ?", (t["id"],)).fetchone()
            x = t["expect"]
            if t.get("optional"):
                continue
            if row is None:
                wrong.append(f"{t['description'][:28]} ({t['amount']}) not recorded")
            elif x.get("direction") and row["direction"] != x["direction"]:
                wrong.append(f"{t['description'][:28]}: {row['direction']} (expected {x['direction']})")
            elif x.get("pocket") == "Unsorted" and row["pocket"] is not None:
                wrong.append(f"{t['description'][:28]}: in {row['pocket']} (expected Unsorted)")
            elif x.get("pocket") and x["pocket"] != "Unsorted" and not x.get("direction") and row["pocket"] != x["pocket"]:
                wrong.append(f"{t['description'][:28]}: in {row['pocket']} (expected {x['pocket']})")
            elif x.get("any_pocket") and row["direction"] != "expense":
                wrong.append(f"{t['description'][:28]}: {row['direction']} (expected an expense)")
        add("Every charge recorded right", not wrong, f"{total - len(wrong)}/{total} right" + (f"; {'; '.join(wrong[:4])}" if wrong else ""))
        # 2. left to spend + rollover per spending pocket
        actual = {p["name"]: p for p in analytics.spending_pockets(conn, month)}
        bad = [f"{n}: {actual.get(n, {}).get('left')} (expected {v})" for n, v in exp["left"].items()
               if n not in actual or abs(actual[n]["left"] - v) > 0.02]
        badr = [f"{n}: {actual.get(n, {}).get('rollover')} (expected {v})" for n, v in exp["rollover"].items()
                if n in actual and abs(actual[n]["rollover"] - v) > 0.02]
        add("Left to spend and rollover per pocket", not bad and not badr,
            "all match" if not bad and not badr else "; ".join((bad + badr)[:4]))
        over = sorted(n for n, p in actual.items() if p["over"])
        add("Over-budget pockets", over == sorted(exp["over"]), f"over: {over or 'none'} (expected {exp['over'] or 'none'})")
        # 3. flags: planted vs found
        free = {t["id"] for t in b.months[month]["txns"] if t["expect"].get("any_pocket")}
        kinds = set()
        for r in conn.execute("SELECT kind, transaction_id FROM review_items WHERE status = 'open' AND month = ?", (month,)):
            if r["kind"] == "unsorted" and r["transaction_id"] in free:
                continue  # the answer key allows any pocket here, and Unsorted (ask the owner) is one of the choices
            kinds.add(r["kind"])
        missed = sorted(set(exp["flags"]) - kinds)
        false = sorted(kinds - set(exp["flags"]))
        add("Flags: none missed, no false alarms", not missed and not false,
            f"expected {exp['flags'] or 'none'}; found {sorted(kinds) or 'none'}" + (f"; missed {missed}" if missed else "")
            + (f"; false alarms {false}" if false else ""))
        # 4. cash check
        cc = analytics.cash_check(conn, month)
        add("Cash check balances", cc["balanced"] and abs(cc["pockets_plus_unassigned"] - cc["all_money"]) < 0.01,
            f"all money {cc['all_money']:,.2f}, unassigned {cc['unassigned']:,.2f}")
        # 5. the scenario's own checks
        savings = {s["name"]: s for s in analytics.savings_pockets(conn, month)}
        for c in exp["checks"]:
            t = c["type"]
            if t == "savings":
                v = savings.get(c["pocket"], {}).get("total")
                add(f"{c['pocket']} total", v is not None and abs(v - c["total"]) < 0.02, f"{v} (expected {c['total']})")
            elif t == "goal_reached":
                pct = savings.get(c["pocket"], {}).get("pct_of_goal")
                add(f"{c['pocket']} goal reached", pct is not None and pct >= 100, f"{pct}% of goal")
            elif t == "recorded_as":
                row = conn.execute("SELECT e.direction, p.name AS pocket FROM ledger_entries e LEFT JOIN pockets p ON p.id = e.pocket_id"
                                   " WHERE e.transaction_id = ?", (c["txn"],)).fetchone()
                ok = row is not None and row["direction"] == c["direction"] and (not c.get("pocket") or row["pocket"] == c["pocket"])
                add(f"{c['txn']} recorded as {c['direction']}{' in ' + c['pocket'] if c.get('pocket') else ''}", ok,
                    f"{dict(row) if row else 'not recorded'}")
            elif t == "not_recorded":
                n = conn.execute("SELECT COUNT(*) FROM ledger_entries WHERE transaction_id = ?", (c["txn"],)).fetchone()[0]
                add("Pending charge not counted (posted one is)", n == 0, f"entries for the pending id: {n}")
            elif t == "no_pocket_moves":
                n = conn.execute("SELECT COUNT(*) FROM pocket_moves").fetchone()[0]
                add("No pocket moves made by the AI", n == 0, f"pocket moves: {n}")
            elif t == "nothing_dismissed":
                n = conn.execute("SELECT COUNT(*) FROM review_items WHERE status = 'dismissed'").fetchone()[0]
                add("No flags dismissed", n == 0, f"dismissed: {n}")
            elif t == "statement_recorded":
                st = conn.execute("SELECT status FROM statements WHERE period = ?", (c["period"],)).fetchone()
                add("BCA statement recorded", st and st["status"] == "recorded", st["status"] if st else "missing")
            elif t == "income_idr":
                first, last = (d.isoformat() for d in analytics.month_range(month))
                v = conn.execute("SELECT COALESCE(SUM(-amount), 0) FROM ledger_entries WHERE direction = 'income' AND currency = 'IDR'"
                                 " AND date BETWEEN ? AND ?", (first, last)).fetchone()[0]
                add("Rupiah income recorded", abs(v - c["amount"]) < 1, f"IDR {v:,.0f} (expected {c['amount']:,.0f})")
            elif t == "unsorted":
                row = conn.execute("SELECT e.pocket_id, (SELECT COUNT(*) FROM review_items r WHERE r.entry_id = e.id AND r.kind = 'unsorted') AS n"
                                   " FROM ledger_entries e WHERE e.transaction_id = ?", (c["txn"],)).fetchone()
                add("Unplaceable charge → Unsorted + Review", row is not None and row["pocket_id"] is None and row["n"] > 0,
                    f"{dict(row) if row else 'not recorded'}")
            elif t == "statement_line":
                rows = conn.execute("SELECT direction, description FROM ledger_entries WHERE currency = 'IDR'"
                                    " AND UPPER(description) LIKE ?", (f"%{c['contains']}%",)).fetchall()
                add(f"Statement line with {c['contains']} recorded as {c['direction']}",
                    rows and all(r["direction"] == c["direction"] for r in rows), str([dict(r) for r in rows])[:160])
            elif t == "debt":
                debts = [d for d in analytics.debts(conn) if d["kind"] == c["kind"]]
                d = debts[0] if debts else None
                ok = d is not None and abs(d["owed"] - c["owed"]) < 0.02 and (not c.get("detail") or c["detail"] in (d.get("detail") or ""))
                add(f"Debt Balance shows the {c['kind']}", ok,
                    f"{d['owed']:,.2f} owed, {d.get('detail')}" if d else "not shown" + f" (expected {c['owed']:,.2f})")
            elif t == "digest_mentions":
                text = (digest or {}).get("text", "")
                add(f"Digest warns about {', '.join(c['words'])}", all(w.lower() in text.lower() for w in c["words"]), text[:160])
    return out


# --- running ---------------------------------------------------------------------------------
def run(b: S.Builder) -> dict:
    from backend import agents, analytics

    setup(b)
    result = {"name": b.name, "title": b.title, "tests": b.tests, "months": [], "started": now()}
    spent = 0
    for month in S.MONTHS:
        with db.connect() as conn:
            load_month(b, month, conn)
        t0 = time.time()
        err, run_id = None, None
        if spent > PER_SCENARIO_CAP:
            err = f"skipped: the scenario's token share ({PER_SCENARIO_CAP:,}) is used up"
        else:
            try:
                out = arun(agents.month_end(month))
                run_id = out["run_id"]
            except Exception as e:  # recorded as a failure, the next month still runs
                err = repr(e)[:300]
        notes = after_month(b, month)
        digest = None
        if b.months[month]["digest"] and not err:
            try:
                d = arun(agents.weekly_digest())
                digest = {"run_id": d["run_id"], "text": json.dumps(d.get("digest"))}
            except Exception as e:
                digest = {"text": "", "error": repr(e)[:200]}
        with db.connect() as conn:
            exp = expected_with(b, actual_extra_spend(b, conn))[month]
            tok = conn.execute("SELECT COALESCE(SUM(input_tokens),0), COALESCE(SUM(cached_tokens),0), COALESCE(SUM(output_tokens),0)"
                               " FROM run_log WHERE run_id IN (?, ?)", (run_id, (digest or {}).get("run_id"))).fetchone()
        checks = check_month(b, month, exp, digest)
        tokens = {"input": tok[0], "cached": tok[1], "output": tok[2]}
        spent += tok[0] + tok[2]
        m = {"month": month, "seconds": round(time.time() - t0), "error": err, "tokens": tokens, "notes": notes,
             "checks": checks, "passed": sum(c["passed"] for c in checks), "total": len(checks)}
        result["months"].append(m)
        print(f"  {b.name} {month}: {m['passed']}/{m['total']} checks, {tokens['input'] + tokens['output']:,} tokens, "
              f"{m['seconds']}s{' ' + err if err else ''}")
        for c in checks:
            if not c["passed"]:
                print(f"      FAIL {c['check']}: {c['detail']}")
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    (RESULTS_DIR / f"{b.name}.json").write_text(json.dumps(result, indent=1))
    return result


def report() -> None:
    order = [m.__name__ for m in S.SCENARIOS]
    rows = sorted((json.loads(p.read_text()) for p in RESULTS_DIR.glob("s*.json")),
                  key=lambda r: order.index(r["name"]) if r["name"] in order else 99)
    by = {r["name"]: r for r in rows}
    lines = ["# Phase 4b: 3-month scenario results", "",
             f"Updated {datetime.now().strftime('%Y-%m-%d %H:%M')}. Each scenario ran July → September 2026 on its own fresh database "
             "(`scripts/run_scenarios.py`); each month: the data arrives, the real Accountant month-end check runs "
             "(and the Advisor's weekly digest in scenario 2), then every check is done in code against the answer key "
             "written beforehand (`data/scenarios/<name>/expected.json`). Model: " + config.MODEL_NAME + ".", ""]
    tp = sum(m["passed"] for r in rows for m in r["months"])
    tt = sum(m["total"] for r in rows for m in r["months"])
    tok = sum(m["tokens"]["input"] + m["tokens"]["output"] for r in rows for m in r["months"])
    cached = sum(m["tokens"]["cached"] for r in rows for m in r["months"])
    lines += [f"**{tp} of {tt} checks passed** across {len(rows)} scenarios × 3 months. "
              f"Tokens: {tok:,} in total ({cached:,} of the input was cached), about {tok // max(1, sum(len(r['months']) for r in rows)):,} per month-end run.", "",
              "| # | Scenario | What it tests | Jul | Aug | Sep | Tokens |", "|---|---|---|---|---|---|---|"]
    for i, make in enumerate(S.SCENARIOS, 1):
        name = make.__name__
        r = by.get(name)
        if not r:
            lines.append(f"| {i} | {name} | – | not run | | | |")
            continue
        cells = [f"{'✅' if m['passed'] == m['total'] else '❌'} {m['passed']}/{m['total']}" for m in r["months"]]
        t = sum(m["tokens"]["input"] + m["tokens"]["output"] for m in r["months"])
        lines.append(f"| {i} | **{r['title']}** | {r['tests']} | {' | '.join(cells)} | {t:,} |")
    lines += ["", "## Details", ""]
    for r in rows:
        lines += [f"### {r['title']}", ""]
        for m in r["months"]:
            t = m["tokens"]
            lines.append(f"**{m['month']}**: {m['passed']}/{m['total']} · {t['input'] + t['output']:,} tokens ({t['cached']:,} cached) · "
                         f"{m['seconds']}s" + (f" · {m['error']}" if m["error"] else ""))
            lines.append("")
            for c in m["checks"]:
                lines.append(f"- {'✅' if c['passed'] else '❌'} {c['check']}: {c['detail'].replace('|', '/')}")
            lines.append("")
    notes = S.OUT / "NOTES.md"  # what earlier runs caught and what isn't covered
    (OUT / "scenario_results.md").write_text("\n".join(lines) + "\n" + (notes.read_text() if notes.exists() else ""))
    print(f"wrote output/scenario_results.md: {tp}/{tt} checks, {tok:,} tokens")


if __name__ == "__main__":
    args = sys.argv[1:]
    if args == ["report"]:
        report()
        sys.exit()
    for make in S.SCENARIOS:
        if args and make.__name__ not in args:
            continue
        b = make()
        b.write()
        print(f"\n{b.title}")
        run(b)
    report()
