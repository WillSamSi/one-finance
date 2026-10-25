"""Budget setup (Wallet → Edit pockets): income pockets, the plan, saving it, archiving.

Pockets are USD only. Money held or spent in IDR is converted to USD (fx_rates) whenever it is
counted into a pocket, and the rate and its date are shown in the app.

A pocket's monthly amount can change from a given month on ("Changes apply: this month / from
next month"); `pocket_budgets` keeps those changes so past months never change.

Income pockets (Salary, Freelance, Dividends, Other income) hold what the owner expects to
earn per month. Deposits are sorted into them: payroll → Salary, dividends → Dividends,
anything else → Other income. Transfers between the owner's accounts and refunds are not income.
"""

import sqlite3
from datetime import date, datetime, timedelta, timezone

from backend import analytics

KINDS = ("income", "spending", "saving", "investing")
PLAN_KINDS = ("spending", "saving", "investing")  # what the income is planned into
FREQUENCIES = ("monthly", "twice a month", "every 2 weeks", "weekly", "irregular")
INCOME_POCKETS = [  # name, active by default, description
    ("Salary", True, "Your paycheck"),
    ("Freelance", False, "Side jobs and gigs"),
    ("Dividends", False, "Dividends and interest paid to your bank"),
    ("Other income", True, "Deposits that don't fit the others (the Accountant puts unknown ones here)"),
]
OTHER_INCOME = "Other income"


class BudgetError(ValueError):
    pass


class OverIncome(BudgetError):
    """Saving would plan more than the expected income: the owner picks where the extra comes from."""

    def __init__(self, over: float, extra: float, sources: list[dict]):
        super().__init__(f"Your plan is ${over:,.2f} over your income.")
        self.over = over      # how far over income the plan is
        self.extra = extra    # how much of that this save adds (what has to come from somewhere)
        self.sources = sources


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def this_month(conn: sqlite3.Connection) -> str:
    return analytics.current_budget_month(conn)


def next_month(month: str) -> str:
    first, last = analytics.month_range(month)
    return (last + timedelta(days=1)).strftime("%Y-%m")


# --- Income pockets ----------------------------------------------------------------------
def add_income_pockets(conn: sqlite3.Connection) -> None:
    """Create the income pockets (once). Salary's expected amount and account come from the
    payroll deposits of the last two full months; past deposits are sorted into the pockets."""
    sort = conn.execute("SELECT COALESCE(MIN(sort), 0) FROM pockets").fetchone()[0] - len(INCOME_POCKETS)
    month = this_month(conn)
    prev = analytics.previous_months(month, 2)
    payroll = conn.execute(
        "SELECT account_id, -SUM(amount) AS total FROM transactions WHERE amount < 0 AND UPPER(description) LIKE '%PAYROLL%'"
        " AND substr(date, 1, 7) IN (?, ?) GROUP BY account_id ORDER BY total DESC", tuple(prev)).fetchone()
    for i, (name, active, description) in enumerate(INCOME_POCKETS):
        expected, account, freq = None, None, None
        if name == "Salary" and payroll:
            expected, account, freq = round(payroll["total"] / 2, 2), payroll["account_id"], "twice a month"
        if not conn.execute("SELECT 1 FROM pockets WHERE name = ?", (name,)).fetchone():
            conn.execute(
                "INSERT INTO pockets (name, kind, monthly_budget, active, custom, sort, description, frequency, received_in)"
                " VALUES (?,?,?,?,?,?,?,?,?)",
                (name, "income", expected, int(active), 0, sort + i, description, freq, account))
    sort_income_entries(conn)
    conn.commit()


def income_pocket_for(conn: sqlite3.Connection, description: str) -> int | None:
    """Which income pocket a deposit belongs to: payroll → Salary, dividends → Dividends (if it's
    switched on), anything else → Other income."""
    text = (description or "").upper()
    active = {r["name"]: r["id"] for r in conn.execute("SELECT id, name FROM pockets WHERE kind = 'income' AND active = 1")}
    if "PAYROLL" in text and "Salary" in active:
        return active["Salary"]
    if ("DIVIDEND" in text or "DIV " in text) and "Dividends" in active:
        return active["Dividends"]
    if "Freelance" in active and any(w in text for w in ("UPWORK", "FIVERR", "INVOICE")):
        return active["Freelance"]
    return active.get(OTHER_INCOME)


def sort_income_entries(conn: sqlite3.Connection) -> int:
    """Give every recorded income without a pocket its income pocket."""
    rows = conn.execute("SELECT id, description FROM ledger_entries WHERE direction = 'income' AND pocket_id IS NULL").fetchall()
    for r in rows:
        conn.execute("UPDATE ledger_entries SET pocket_id = ? WHERE id = ?", (income_pocket_for(conn, r["description"]), r["id"]))
    return len(rows)


# --- Monthly amounts over time -----------------------------------------------------------
def amounts(conn: sqlite3.Connection):
    """amount(pocket_id, month): the monthly amount in effect that month."""
    sched: dict[int, list[tuple[str, float]]] = {}
    for r in conn.execute("SELECT pocket_id, from_month, amount FROM pocket_budgets ORDER BY from_month"):
        sched.setdefault(r["pocket_id"], []).append((r["from_month"], r["amount"]))
    base = {r["id"]: r["monthly_budget"] or 0.0 for r in conn.execute("SELECT id, monthly_budget FROM pockets")}

    def amount(pocket_id: int, month: str) -> float:
        rows = sched.get(pocket_id)
        if not rows:
            return base.get(pocket_id, 0.0)
        value = rows[0][1]
        for m, a in rows:
            if m <= month:
                value = a
        return value

    return amount


def set_amount(conn: sqlite3.Connection, pocket: sqlite3.Row, new: float, from_month: str) -> None:
    """Change a pocket's monthly amount from `from_month` on; earlier months keep the old one."""
    if not conn.execute("SELECT 1 FROM pocket_budgets WHERE pocket_id = ?", (pocket["id"],)).fetchone():
        first = pocket["start_month"] or analytics.budget_start(conn)
        if first < from_month:
            conn.execute("INSERT INTO pocket_budgets VALUES (?,?,?)", (pocket["id"], first, pocket["monthly_budget"] or 0.0))
    conn.execute("DELETE FROM pocket_budgets WHERE pocket_id = ? AND from_month >= ?", (pocket["id"], from_month))
    conn.execute("INSERT INTO pocket_budgets VALUES (?,?,?)", (pocket["id"], from_month, round(new, 2)))


# --- The plan (what Budget setup shows) ------------------------------------------------------
def display_name(name: str) -> str:
    return "Ready to invest" if name == "Investment" else name


def _account_name(a) -> str:
    """"Chase Total Checking", not "Chase Chase Total Checking"."""
    return a["name"] if a["name"].startswith(a["institution"]) else f"{a['institution']} {a['name']}"


def history_months(conn: sqlite3.Connection) -> int:
    """Full months of bank history before this month (the AI draft needs about 2)."""
    month = this_month(conn)
    return conn.execute("SELECT COUNT(DISTINCT substr(date, 1, 7)) FROM transactions WHERE substr(date, 1, 7) < ?",
                        (month,)).fetchone()[0]


def plan(conn: sqlite3.Connection) -> dict:
    month = this_month(conn)
    nxt = next_month(month)
    amount = amounts(conn)
    rates = fx(conn)
    first, last = (d.isoformat() for d in analytics.budget_range(conn, month))
    spending = {p["name"]: p for p in analytics.spending_pockets(conn, month)}
    savings = {p["name"]: p for p in analytics.savings_pockets(conn, month)}
    received = {}
    for r in conn.execute("SELECT pocket_id, amount, currency FROM ledger_entries WHERE direction = 'income'"
                          " AND pocket_id IS NOT NULL AND date BETWEEN ? AND ?", (first, last)):
        received[r["pocket_id"]] = received.get(r["pocket_id"], 0.0) + abs(r["amount"]) * rates.get(r["currency"], 1.0)
    accounts = {r["id"]: r for r in conn.execute("SELECT id, institution, name, mask, currency FROM accounts WHERE type = 'depository'")}

    pockets, catalog = [], []
    for p in conn.execute("SELECT * FROM pockets ORDER BY sort"):
        row = {
            "name": p["name"], "display_name": display_name(p["name"]), "kind": p["kind"], "custom": bool(p["custom"]),
            "description": p["description"],
            "monthly": round(amount(p["id"], month), 2) if p["kind"] != "income" else (p["monthly_budget"] or 0.0),
            "next_month": round(amount(p["id"], nxt), 2) if p["kind"] != "income" else (p["monthly_budget"] or 0.0),
            "goal_amount": p["goal_amount"], "goal_date": p["goal_date"], "starting_amount": p["starting_amount"],
            "frequency": p["frequency"], "received_in": p["received_in"],
        }
        if p["kind"] == "income":
            a = accounts.get(p["received_in"])
            row["received_in_label"] = f"{a['institution']} ••{a['mask']}" if a else None
            row["received_this_month"] = round(received.get(p["id"], 0.0), 2)
        elif p["kind"] == "spending" and p["name"] in spending:
            s = spending[p["name"]]
            row.update(spent=s["spent"], left=s["left"], available=s["available"], usual=s["usual"])
        elif p["name"] in savings:
            row.update(saved=savings[p["name"]]["total"])
        (pockets if p["active"] else catalog).append(row)

    income = sum(p["monthly"] for p in pockets if p["kind"] == "income")
    planned = {k: round(sum(p["monthly"] for p in pockets if p["kind"] == k), 2) for k in PLAN_KINDS}
    unspent = sum(max(0.0, p.get("left", 0.0)) for p in pockets if p["kind"] == "spending")
    available = sum(p.get("available", 0.0) for p in pockets if p["kind"] == "spending")
    fx_row = conn.execute("SELECT usd_per_unit, as_of FROM fx_rates WHERE currency = 'IDR'").fetchone()
    months = history_months(conn)
    return {
        "month": month, "next_month": nxt,
        "pockets": pockets, "catalog": catalog,
        "expected_income": round(income, 2),
        "planned": planned,
        "not_planned": round(income - sum(planned.values()), 2),
        "unspent": round(unspent, 2),
        "spending_available": round(available, 2),
        "accounts": [{"id": a["id"], "label": f"{_account_name(a)} ••{a['mask']}", "currency": a["currency"]}
                     for a in accounts.values()],
        "frequencies": list(FREQUENCIES),
        "fx": {"idr_per_usd": round(1 / fx_row["usd_per_unit"]) if fx_row else None, "as_of": fx_row["as_of"] if fx_row else None},
        "first_time": not any(p["kind"] in PLAN_KINDS for p in pockets),
        "history_months": months,
        "ai_draft_available": months >= 2,
        "ai_draft_reason": None if months >= 2 else
            f"The AI needs about 2 months of bank history to see your spending; you have {months}.",
    }


def fx(conn: sqlite3.Connection) -> dict[str, float]:
    return analytics.fx(conn)


# --- Saving the plan -----------------------------------------------------------------------
def _validate(name: str, kind: str, monthly: float) -> str:
    name = (name or "").strip()[:40]
    if not name:
        raise BudgetError("Give the pocket a name.")
    if kind not in KINDS:
        raise BudgetError("Kind must be income, spending, saving or investing.")
    if not 0 <= monthly <= 1_000_000:
        raise BudgetError(f"{name}: the monthly amount must be $0 or more.")
    return name


def save_plan(conn: sqlite3.Connection, *, apply: str, pockets: list[dict], cover_from: str | None = None) -> dict:
    """Apply Budget setup in one go: changed amounts, goals, renames and new pockets.

    `apply` is 'this_month' or 'next_month'. If the plan (spending + saving + investing) is more
    than the expected income, OverIncome is raised unless `cover_from` names a saving/investing
    pocket that holds enough: that pocket then gives up the extra (an in-app move to Unassigned)."""
    if apply not in ("this_month", "next_month"):
        raise BudgetError("Changes apply this month or from next month.")
    month = this_month(conn)
    eff = month if apply == "this_month" else next_month(month)
    existing = {r["name"]: r for r in conn.execute("SELECT * FROM pockets")}
    for p in pockets:  # "Ready to invest" is how the app shows the Investment pocket
        for key in ("name", "new_name"):
            if (p.get(key) or "").strip().lower() == "ready to invest":
                p[key] = "Investment"
    amount = amounts(conn)

    seen: set[str] = set()
    for p in pockets:
        name = _validate(p.get("new_name") or p["name"], p.get("kind") or existing.get(p["name"], {"kind": "spending"})["kind"],
                         float(p.get("monthly") or 0))
        if name.lower() in seen:
            raise BudgetError(f"There are two pockets called {name}.")
        seen.add(name.lower())
        clash = conn.execute("SELECT name, active FROM pockets WHERE name = ? COLLATE NOCASE", (name,)).fetchone()
        renaming = p.get("new_name") and p["new_name"] != p["name"]
        if clash and clash["active"] and (p.get("is_new") or (renaming and clash["name"] != p["name"])):
            raise BudgetError(f"There's already a pocket called {name}.")
        if renaming and p["name"] in existing and not existing[p["name"]]["custom"]:
            raise BudgetError(f"{p['name']} can't be renamed (only pockets you added can).")
        if float(p.get("starting_amount") or 0) < 0 or float(p.get("goal_amount") or 0) < 0:
            raise BudgetError(f"{name}: amounts can't be below $0.")

    # The plan before and after these changes, for the month they apply to. Only a save that
    # pushes the plan (further) over income asks where the extra comes from.
    before: dict[str, tuple[str, float]] = {}
    for r in existing.values():
        if r["active"]:
            before[r["name"]] = (r["kind"], (r["monthly_budget"] or 0.0) if r["kind"] == "income" else amount(r["id"], eff))
    after = dict(before)
    for p in pockets:
        after[p["name"]] = (p.get("kind") or existing[p["name"]]["kind"], float(p.get("monthly") or 0))

    def over_income(rows: dict) -> float:
        return round(sum(v for k, v in rows.values() if k in PLAN_KINDS) - sum(v for k, v in rows.values() if k == "income"), 2)

    over = over_income(after)
    extra = round(over - max(0.0, over_income(before)), 2)
    if over > 0.005 and extra > 0.005:
        sources = [{"name": s["name"], "display_name": display_name(s["name"]), "available": round(max(0.0, s["total"]), 2)}
                   for s in analytics.savings_pockets(conn, month)]
        if not cover_from:
            raise OverIncome(over, extra, sources)
        src = next((s for s in sources if s["name"] == cover_from), None)
        if not src:
            raise BudgetError("Pick one of your savings or investing pockets.")
        if src["available"] + 0.005 < extra:
            raise BudgetError(f"{src['display_name']} has only ${src['available']:,.2f}; it can't cover ${extra:,.2f}.")
    else:
        extra = 0.0

    created, changed = [], []
    for p in pockets:
        kind = p.get("kind") or existing[p["name"]]["kind"]
        monthly = round(float(p.get("monthly") or 0), 2)
        row = existing.get(p["name"])
        if p.get("is_new") or row is None or not row["active"]:
            if row is None:
                sort = conn.execute("SELECT COALESCE(MAX(sort), 0) + 1 FROM pockets").fetchone()[0]
                conn.execute("INSERT INTO pockets (name, kind, monthly_budget, active, custom, sort, description)"
                             " VALUES (?,?,?,1,1,?,?)", (p["name"].strip()[:40], kind, monthly, sort, "Added in Budget setup"))
            row = conn.execute("SELECT * FROM pockets WHERE name = ? COLLATE NOCASE", (p["name"].strip(),)).fetchone()
            conn.execute("DELETE FROM pocket_budgets WHERE pocket_id = ?", (row["id"],))
            conn.execute(
                "UPDATE pockets SET active = 1, kind = ?, monthly_budget = ?, goal_amount = ?, goal_date = ?,"
                " starting_amount = ?, start_month = ?, frequency = ?, received_in = ? WHERE id = ?",
                (kind, monthly, p.get("goal_amount") or None, p.get("goal_date") or None,
                 round(float(p.get("starting_amount") or 0), 2), eff if kind != "income" else None,
                 p.get("frequency"), p.get("received_in"), row["id"]))
            created.append(p["name"])
            continue
        if kind == "income":
            conn.execute("UPDATE pockets SET monthly_budget = ?, frequency = ?, received_in = ? WHERE id = ?",
                         (monthly, p.get("frequency", row["frequency"]), p.get("received_in", row["received_in"]), row["id"]))
        elif abs(monthly - amount(row["id"], eff)) > 0.004:
            set_amount(conn, row, monthly, eff)
            if eff == month:
                conn.execute("UPDATE pockets SET monthly_budget = ? WHERE id = ?", (monthly, row["id"]))
            changed.append(p["name"])
        if kind == "saving":
            conn.execute("UPDATE pockets SET goal_amount = ?, goal_date = ? WHERE id = ?",
                         (p.get("goal_amount") or None, p.get("goal_date") or None, row["id"]))
        if p.get("new_name") and p["new_name"].strip() != p["name"]:
            conn.execute("UPDATE pockets SET name = ? WHERE id = ?", (p["new_name"].strip()[:40], row["id"]))
    if extra > 0.005:
        src_id = conn.execute("SELECT id FROM pockets WHERE name = ?", (cover_from,)).fetchone()["id"]
        conn.execute("INSERT INTO pocket_moves (date, from_pocket_id, to_pocket_id, amount, note, created_by, created_at)"
                     " VALUES (?,?,?,?,?,?,?)", (analytics.today(conn).isoformat(), src_id, None, extra,
                                                 "Covers the budget going over income", "user", _now()))
    if created:
        sort_income_entries(conn)
    conn.commit()
    return {"ok": True, "applies_from": eff, "created": created, "changed": changed,
            "over_income": max(0.0, over), "covered": {"from": cover_from, "amount": extra} if extra > 0.005 else None}


# --- Archiving ------------------------------------------------------------------------------
def archive(conn: sqlite3.Connection, name: str, move_to: str | None) -> dict:
    """Archive a pocket (never deleted; past months keep their history).
    Spending: this month's expenses move to `move_to` (a spending pocket) or Unsorted.
    Savings/investing: the balance moves to `move_to` (a savings/investing pocket) or Unassigned.
    Income: future deposits go to Other income."""
    p = conn.execute("SELECT * FROM pockets WHERE name = ? AND active = 1", (name,)).fetchone()
    if not p:
        raise BudgetError("No such pocket.")
    if p["name"] == OTHER_INCOME:
        raise BudgetError("Other income catches deposits that fit nowhere else, so it stays.")
    month = this_month(conn)
    first, last = (d.isoformat() for d in analytics.budget_range(conn, month))
    target = None
    if move_to:
        target = conn.execute("SELECT * FROM pockets WHERE name = ? AND active = 1 AND id != ?", (move_to, p["id"])).fetchone()
        ok_kinds = ("spending",) if p["kind"] == "spending" else ("saving", "investing")
        if not target or target["kind"] not in ok_kinds:
            raise BudgetError("Pick another " + ("spending pocket." if p["kind"] == "spending" else "savings or investing pocket."))
    moved = 0.0
    if p["kind"] == "spending":
        rows = conn.execute("SELECT id, amount, description FROM ledger_entries WHERE pocket_id = ? AND direction = 'expense'"
                            " AND date BETWEEN ? AND ?", (p["id"], first, last)).fetchall()
        for r in rows:
            conn.execute("UPDATE ledger_entries SET pocket_id = ? WHERE id = ?", (target["id"] if target else None, r["id"]))
            if not target:
                conn.execute("INSERT INTO review_items (kind, month, entry_id, amount, detail, created_by, created_at)"
                             " VALUES (?,?,?,?,?,?,?)",
                             ("unsorted", month, r["id"], r["amount"],
                              f"{r['description']} was in {name}, which you archived. Pick a pocket for it.", "user", _now()))
            moved += r["amount"]
    elif p["kind"] in ("saving", "investing"):
        total = next((s["total"] for s in analytics.savings_pockets(conn, month) if s["name"] == name), 0.0)
        if total > 0:
            conn.execute("INSERT INTO pocket_moves (date, from_pocket_id, to_pocket_id, amount, note, created_by, created_at)"
                         " VALUES (?,?,?,?,?,?,?)", (analytics.today(conn).isoformat(), p["id"], target["id"] if target else None,
                                                     round(total, 2), f"{name} archived", "user", _now()))
            moved = total
    conn.execute("UPDATE pockets SET active = 0 WHERE id = ?", (p["id"],))
    conn.commit()
    return {"ok": True, "archived": name, "moved": round(moved, 2),
            "to": move_to or ("Unsorted" if p["kind"] == "spending" else "Unassigned" if p["kind"] != "income" else OTHER_INCOME)}


# --- Helpers for the forms ---------------------------------------------------------------------
def spending_hint(conn: sqlite3.Connection, name: str) -> dict | None:
    """What the owner spent on something like `name` in the last 3 full months (bank charges whose
    description, merchant or category mentions it, plus expenses already in a pocket by that name)."""
    words = [w for w in (name or "").upper().replace("&", " ").split() if len(w) >= 3]
    if not words:
        return None
    months = analytics.previous_months(this_month(conn), 3)
    first, last = analytics.month_range(months[-1])[0].isoformat(), analytics.month_range(months[0])[1].isoformat()
    total, hits = 0.0, 0
    rates = fx(conn)
    for t in conn.execute("SELECT description, merchant_name, category, amount, currency FROM transactions"
                          " WHERE amount > 0 AND date BETWEEN ? AND ?", (first, last)):
        text = f"{t['description']} {t['merchant_name'] or ''} {(t['category'] or '').replace('_', ' ')}".upper()
        if any(w in text for w in words):
            total += t["amount"] * rates.get(t["currency"], 1.0)
            hits += 1
    row = conn.execute("SELECT COALESCE(SUM(e.amount), 0), COUNT(*) FROM ledger_entries e JOIN pockets p ON p.id = e.pocket_id"
                       " WHERE p.name = ? COLLATE NOCASE AND e.direction = 'expense' AND e.transaction_id IS NULL"
                       " AND e.date BETWEEN ? AND ?", (name.strip(), first, last)).fetchone()
    total += row[0]
    hits += row[1]
    if not hits:
        return None
    return {"monthly": round(total / 3, 2), "matches": hits, "months": 3}


def start_over(conn: sqlite3.Connection) -> dict:
    """For testing and the demo: switch every pocket off (working copy only; Reset restores the
    sample). Transactions and past entries stay. Budget setup then opens on the first-time choice."""
    n = conn.execute("UPDATE pockets SET active = 0 WHERE active = 1 AND name != ?", (OTHER_INCOME,)).rowcount
    conn.execute("UPDATE pockets SET active = 1 WHERE name = ?", (OTHER_INCOME,))  # unknown deposits still land somewhere
    conn.commit()
    return {"ok": True, "switched_off": n}
