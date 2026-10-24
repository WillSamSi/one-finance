"""One Finance API (FastAPI). The iOS app talks only to this.

Start from the repo folder:
    .venv/bin/uvicorn backend.main:app --reload --port 8000
API docs: http://localhost:8000/docs
"""

import asyncio
import json
from typing import Literal

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from backend import agents, analytics, config, db
from backend.team import BudgetExceeded, tokens_used_today

app = FastAPI(title="One Finance API")
_run_lock = asyncio.Lock()  # one agent run at a time


def _setting(conn, key: str):
    row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    if not row:
        return None
    try:
        return json.loads(row["value"])
    except (json.JSONDecodeError, TypeError):
        return row["value"]


@app.get("/health")
def health() -> dict:
    with db.connect() as conn:
        return {
            "ok": True,
            "app_date": db.app_date(conn),
            "data_mode": _setting(conn, "data_mode") or "unknown",
            "plaid_keys": config.plaid_enabled(),
            "tokens_today": tokens_used_today(),
            "daily_token_limit": config.DAILY_TOKEN_LIMIT,
        }


@app.get("/accounts")
def accounts() -> dict:
    """Every account with its balance in its own currency and in USD, plus total assets."""
    with db.connect() as conn:
        rows = conn.execute(
            """SELECT a.id, a.institution, a.name, a.type, a.subtype, a.mask, a.currency,
                      a.current_balance, a.as_of, f.usd_per_unit
               FROM accounts a JOIN fx_rates f ON f.currency = a.currency
               ORDER BY a.source, a.institution, a.name"""
        ).fetchall()
    out = []
    total = 0.0
    for r in rows:
        usd = r["current_balance"] * r["usd_per_unit"]
        signed = -usd if r["type"] == "credit" else usd  # card balances are money owed
        total += signed
        out.append({**{k: r[k] for k in r.keys() if k != "usd_per_unit"}, "balance_usd": round(signed, 2)})
    return {"accounts": out, "total_assets_usd": round(total, 2)}


LUMPY_POCKETS = {"Rent / mortgage", "Utilities", "Entertainment"}  # monthly bills and subscriptions


def _insight(budget: dict) -> str | None:
    """The one pocket furthest above its usual spending (plain math, no AI)."""
    best = None
    for p in budget["pockets"]:
        # Only everyday spending: bills paid once a month can't be compared day by day.
        # Skip pockets whose usual spending is too small to compare against (e.g. $3 → $42 isn't news).
        if p["name"] in LUMPY_POCKETS:
            continue
        if p["usual"] and p["usual"] >= max(20, 0.1 * p["budget"]) and p["spent"] > 0 and budget["days_elapsed"]:
            expected = p["usual"] * budget["days_elapsed"] / budget["days_in_month"]
            if expected > 0:
                ratio = p["spent"] / expected - 1
                if ratio > 0.1 and (best is None or ratio > best[1]):
                    best = (p["name"], ratio)
    return f"{best[0]} is {round(best[1] * 100)}% above your usual" if best else None


def _savings(conn, month: str) -> list[dict]:
    """One card per saving/investing pocket: money kept, goal, this month's contribution."""
    first, last = (d.isoformat() for d in analytics.month_range(month))
    rates = analytics.fx(conn)
    out = []
    for p in conn.execute("SELECT * FROM pockets WHERE kind IN ('saving', 'investing') ORDER BY id"):
        linked = [r["account_id"] for r in conn.execute(
            "SELECT account_id FROM pocket_accounts WHERE pocket_id = ? AND status = 'active'", (p["id"],))]
        if not linked:  # until the Accountant links accounts, use the obvious ones
            if p["kind"] == "investing":
                where = "type = 'investment'"
            elif p["currency"] == "IDR":
                where = "currency = 'IDR'"
            else:
                where = "subtype = 'savings' AND currency = 'USD'"
            linked = [r["id"] for r in conn.execute(f"SELECT id FROM accounts WHERE {where}")]
        accts = [conn.execute("SELECT * FROM accounts WHERE id = ?", (a,)).fetchone() for a in linked]
        if p["kind"] == "investing":
            amount = sum(a["available_balance"] or 0 for a in accts)  # cash ready to invest
        else:
            amount = sum(a["current_balance"] or 0 for a in accts if a["currency"] == p["currency"])
        contributed = conn.execute(
            "SELECT COALESCE(SUM(ABS(amount)), 0) FROM ledger_entries WHERE pocket_id = ? AND direction = 'transfer'"
            " AND date BETWEEN ? AND ?", (p["id"], first, last)).fetchone()[0]
        out.append({
            "name": p["name"], "kind": p["kind"], "currency": p["currency"], "amount": round(amount, 2),
            "amount_usd": round(amount * rates.get(p["currency"], 1.0), 2),
            "goal": p["goal_amount"], "monthly_budget": p["monthly_budget"],
            "pct_of_goal": round(100 * amount / p["goal_amount"], 1) if p["goal_amount"] else None,
            "contributed_this_month": round(contributed, 2), "accounts": linked,
        })
    return out


def _default_next_steps(conn, budget: dict) -> list[dict]:
    """Next steps from the data alone (plain rules), shown until the Advisor writes a digest."""
    steps = []
    manual = conn.execute(
        "SELECT date, amount FROM ledger_entries WHERE recorded_by = 'user' AND transaction_id IS NULL AND receipt_id IS NULL"
        " ORDER BY date").fetchall()
    if manual:
        from datetime import date as _date
        listed = " and ".join(f"${m['amount']:,.0f} ({_date.fromisoformat(m['date']).strftime('%b')} {int(m['date'][8:])})"
                              for m in manual[:2])
        steps.append({"title": f"Verify {len(manual)} manual expense{'s' * (len(manual) > 1)}",
                      "detail": f"{listed} have no matching receipt or bank charge.", "action": "review"})
    for p in budget["pockets"]:
        if p["over"]:
            steps.append({"title": f"{p['name']} is ${p['spent'] - p['budget']:,.0f} over budget",
                          "detail": f"${p['spent']:,.0f} spent of ${p['budget']:,.0f}.", "action": "fix"})
    from backend.tools import portfolio_snapshot
    snap = portfolio_snapshot(conn)
    for sector, share in snap["sector_shares_pct"].items():
        if share > snap["max_sector_share_pct"] and not sector.startswith("Fund"):
            steps.append({"title": f"{sector} is {share:.0f}% of your portfolio",
                          "detail": f"Above the {snap['max_sector_share_pct']:.0f}% limit you set. Check before your next contribution.",
                          "action": "view"})
    open_items = conn.execute("SELECT COUNT(*) FROM review_items WHERE status = 'open'").fetchone()[0]
    if open_items:
        steps.append({"title": f"{open_items} item{'s' * (open_items > 1)} to review",
                      "detail": "The Accountant flagged problems in your month-end check.", "action": "review"})
    return steps[:4]


@app.get("/home")
def home(month: str | None = None) -> dict:
    """Everything the Home screen shows (see the render in PLAN.md)."""
    with db.connect() as conn:
        month = month or analytics.today(conn).strftime("%Y-%m")
    agents.rules_through(month)  # free pre-pass so the month is categorized
    with db.connect() as conn:
        budget = analytics.budget_status(conn, month)
        next_steps = _setting(conn, "latest_next_steps")
        return {
            "month": month,
            "today": analytics.today(conn).isoformat(),
            "balance": analytics.balance_change_this_month(conn),
            "summary": {
                "spent": budget["total_spent"],
                "budget": budget["total_budget"],
                "left": budget["total_left"],
                "spend_per_day_last_7_days": analytics.spend_per_day(conn),
                "insight": _insight(budget),
                "pct_used": budget["pct_used"],
                "pct_expected": budget["pct_expected"],
            },
            "budget": budget,
            "cashflow": analytics.cashflow(conn, month),
            "savings": _savings(conn, month),
            "next_steps": next_steps or _default_next_steps(conn, budget),
            "next_steps_by": "advisor" if next_steps else "rules",
            "open_review_items": conn.execute("SELECT COUNT(*) FROM review_items WHERE status = 'open'").fetchone()[0],
            "months": [r[0] for r in conn.execute("SELECT DISTINCT substr(date, 1, 7) FROM transactions ORDER BY 1 DESC")],
        }


@app.get("/pockets")
def pockets() -> dict:
    with db.connect() as conn:
        rows = conn.execute("SELECT name, kind, currency FROM pockets ORDER BY id").fetchall()
        links = conn.execute(
            """SELECT p.name AS pocket, a.name AS account, a.mask, pa.confidence, pa.reason, pa.linked_by, pa.status
               FROM pocket_accounts pa JOIN pockets p ON p.id = pa.pocket_id JOIN accounts a ON a.id = pa.account_id
               ORDER BY p.id""").fetchall()
    return {"pockets": [dict(r) for r in rows], "links": [dict(r) for r in links]}


class ManualEntry(BaseModel):
    date: str
    description: str
    amount: float
    pocket: str


@app.post("/entries/manual")
def add_manual_entry(body: ManualEntry) -> dict:
    """The + button: an expense typed in by hand (no receipt or bank charge yet)."""
    if body.amount <= 0 or body.amount > 100_000:
        raise HTTPException(400, "Amount must be between 0 and 100,000.")
    if not body.description.strip():
        raise HTTPException(400, "Add a short description.")
    with db.connect() as conn:
        p = conn.execute("SELECT id FROM pockets WHERE name = ? AND kind = 'spending'", (body.pocket,)).fetchone()
        if not p:
            raise HTTPException(400, "Pick a spending pocket.")
        cur = conn.execute(
            "INSERT INTO ledger_entries (date, description, amount, currency, direction, pocket_id, status, recorded_by,"
            " note, created_at) VALUES (?,?,?,?,?,?,?,?,?,datetime('now'))",
            (body.date, body.description.strip()[:120], round(body.amount, 2), "USD", "expense", p["id"], "recorded",
             "user", "Manual entry: no receipt or bank charge yet"))
        conn.commit()
    return {"ok": True, "id": cur.lastrowid}


@app.get("/portfolio")
def portfolio() -> dict:
    from backend.tools import portfolio_snapshot

    with db.connect() as conn:
        return {"snapshot": portfolio_snapshot(conn), "latest_brief": _setting(conn, "latest_portfolio_brief")}


@app.get("/transactions")
def transactions(q: str = "", limit: int = 100) -> dict:
    """Search charges, receipts' stores and Amazon products."""
    like = f"%{q.strip()}%"
    with db.connect() as conn:
        rows = conn.execute(
            """SELECT t.id, t.date, t.description, t.merchant_name, t.amount, t.currency, a.name AS account, a.mask,
                      p.name AS pocket, e.receipt_id, e.amazon_order_id
               FROM transactions t JOIN accounts a ON a.id = t.account_id
               LEFT JOIN ledger_entries e ON e.transaction_id = t.id LEFT JOIN pockets p ON p.id = e.pocket_id
               WHERE t.description LIKE ? OR COALESCE(t.merchant_name, '') LIKE ? OR COALESCE(p.name, '') LIKE ?
               OR e.amazon_order_id IN (SELECT order_id FROM amazon_order_items WHERE product_name LIKE ?)
               OR e.receipt_id IN (SELECT receipt_id FROM receipt_items WHERE name LIKE ?)
               ORDER BY t.date DESC LIMIT ?""", (like, like, like, like, like, min(limit, 500))).fetchall()
    return {"transactions": [dict(r) for r in rows]}


@app.get("/runs/{run_id}")
def run_steps(run_id: str) -> dict:
    """Every step of one agent run (the traced run for the report)."""
    with db.connect() as conn:
        rows = conn.execute(
            """SELECT step, agent, chain, step_type, tool, text, data_json, input_tokens, cached_tokens, output_tokens,
                      created_at FROM run_log WHERE run_id = ? ORDER BY step""", (run_id,)).fetchall()
    if not rows:
        raise HTTPException(404, "No such run.")
    return {"run_id": run_id, "steps": [dict(r) for r in rows]}


@app.get("/balance-history")
def balance_history(days: int = 30) -> dict:
    """Total assets per day (USD) for the area chart."""
    with db.connect() as conn:
        end = analytics.today(conn)
        rows = conn.execute(
            """SELECT h.date, ROUND(SUM(CASE WHEN a.type = 'credit' THEN -h.balance ELSE h.balance END * f.usd_per_unit), 2) AS total
               FROM balance_history h JOIN accounts a ON a.id = h.account_id JOIN fx_rates f ON f.currency = a.currency
               WHERE h.date > date(?, ?) AND h.date <= ? GROUP BY h.date ORDER BY h.date""",
            (end.isoformat(), f"-{max(1, min(days, 800))} day", end.isoformat())).fetchall()
        synthetic_before = _setting(conn, "synthetic_history_before")
    return {"points": [dict(r) for r in rows], "synthetic_before": synthetic_before}


# --- Review tray, notifications, runs ---------------------------------------------------
@app.get("/review")
def review(status: str = "open") -> dict:
    with db.connect() as conn:
        rows = conn.execute(
            """SELECT r.*, p.name AS pocket FROM review_items r LEFT JOIN pockets p ON p.id = r.pocket_id
               WHERE (? = 'all' OR r.status = ?) ORDER BY r.month DESC, r.id""", (status, status)).fetchall()
    return {"items": [dict(r) for r in rows]}


class Resolve(BaseModel):
    status: Literal["confirmed", "fixed", "dismissed"]


@app.post("/review/{item_id}/resolve")
def resolve_review(item_id: int, body: Resolve) -> dict:
    with db.connect() as conn:
        cur = conn.execute(
            "UPDATE review_items SET status = ?, resolved_at = datetime('now') WHERE id = ? AND status = 'open'",
            (body.status, item_id))
        conn.commit()
    if cur.rowcount == 0:
        raise HTTPException(404, "No open review item with that id.")
    return {"ok": True, "id": item_id, "status": body.status}


@app.get("/notifications")
def notifications() -> dict:
    with db.connect() as conn:
        return {"items": [dict(r) for r in conn.execute("SELECT * FROM notifications ORDER BY id DESC LIMIT 50")]}


@app.get("/runs")
def runs(limit: int = 20) -> dict:
    """Recent agent runs with their token totals (Tokenomics evidence)."""
    with db.connect() as conn:
        rows = conn.execute(
            """SELECT run_id, MIN(created_at) AS started, MAX(created_at) AS finished,
                      GROUP_CONCAT(DISTINCT agent) AS agents,
                      SUM(step_type = 'model_response') AS model_calls, SUM(step_type = 'tool_result') AS tool_calls,
                      COALESCE(SUM(input_tokens), 0) AS input_tokens, COALESCE(SUM(cached_tokens), 0) AS cached_tokens,
                      COALESCE(SUM(output_tokens), 0) AS output_tokens
               FROM run_log GROUP BY run_id ORDER BY started DESC LIMIT ?""", (limit,)).fetchall()
    return {"runs": [dict(r) for r in rows]}


@app.get("/events")
def events(after: int = 0, run_id: str | None = None, limit: int = 200) -> dict:
    """Agent steps after a given id, for the live agent panel."""
    with db.connect() as conn:
        rows = conn.execute(
            """SELECT id, run_id, agent, chain, step, step_type, tool, text, input_tokens, cached_tokens, output_tokens, created_at
               FROM run_log WHERE id > ? AND (? IS NULL OR run_id = ?) ORDER BY id LIMIT ?""",
            (after, run_id, run_id, limit)).fetchall()
    return {"events": [dict(r) for r in rows]}


@app.get("/events/latest-id")
def latest_event_id() -> dict:
    """The newest step id, so the app can watch only the steps of the run it's starting."""
    with db.connect() as conn:
        return {"id": conn.execute("SELECT COALESCE(MAX(id), 0) FROM run_log").fetchone()[0]}


@app.post("/reset")
def reset() -> dict:
    if _run_lock.locked():
        raise HTTPException(409, "An agent run is in progress.")
    db.reset_working_db()
    return {"ok": True}


# --- Agent runs -------------------------------------------------------------------------
async def _run(coro_fn, *args):
    if _run_lock.locked():
        raise HTTPException(409, "Another agent run is in progress. Try again when it finishes.")
    async with _run_lock:
        try:
            return await coro_fn(*args)
        except BudgetExceeded as exc:
            raise HTTPException(429, str(exc))


class MonthBody(BaseModel):
    month: str


class ChatBody(BaseModel):
    question: str


@app.post("/agents/month-end")
async def run_month_end(body: MonthBody) -> dict:
    return await _run(agents.month_end, body.month)


@app.post("/agents/receipts/{receipt_id}/read")
async def run_read_receipt(receipt_id: int) -> dict:
    return await _run(agents.read_receipt, receipt_id)


@app.post("/agents/portfolio-brief")
async def run_portfolio_brief() -> dict:
    return await _run(agents.portfolio_brief)


@app.post("/agents/weekly-digest")
async def run_weekly_digest() -> dict:
    return await _run(agents.weekly_digest)


@app.post("/agents/chat")
async def run_chat(body: ChatBody) -> dict:
    if not body.question.strip() or len(body.question) > 2000:
        raise HTTPException(400, "Ask a question of up to 2,000 characters.")
    return await _run(agents.chat, body.question)
