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


def _insight(budget: dict) -> str | None:
    """The one pocket furthest above its usual spending (plain math, no AI)."""
    best = None
    for p in budget["pockets"]:
        if p["usual"] and p["spent"] > 0 and budget["days_elapsed"]:
            expected = p["usual"] * budget["days_elapsed"] / budget["days_in_month"]
            if expected > 0:
                ratio = p["spent"] / expected - 1
                if ratio > 0.1 and (best is None or ratio > best[1]):
                    best = (p["name"], ratio)
    return f"{best[0]} is {round(best[1] * 100)}% above your usual" if best else None


@app.get("/home")
def home(month: str | None = None) -> dict:
    """Everything the Home screen shows (see the render in PLAN.md)."""
    with db.connect() as conn:
        month = month or analytics.today(conn).strftime("%Y-%m")
    agents.rules_through(month)  # free pre-pass so the month is categorized
    with db.connect() as conn:
        budget = analytics.budget_status(conn, month)
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
            "next_steps": _setting(conn, "latest_next_steps") or [],
            "open_review_items": conn.execute("SELECT COUNT(*) FROM review_items WHERE status = 'open'").fetchone()[0],
        }


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
