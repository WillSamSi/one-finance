"""One Finance API (FastAPI). The iOS app talks only to this.

Start from the repo folder:
    .venv/bin/uvicorn backend.main:app --reload --port 8000
API docs: http://localhost:8000/docs
"""

import asyncio
import json
import logging
from contextlib import asynccontextmanager
from typing import Literal

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from backend import agents, analytics, config, db, snaptrade_client
from backend.team import BudgetExceeded, tokens_used_today

log = logging.getLogger("one_finance")


async def _sync_investments() -> dict:
    """Live SnapTrade sandbox data when keys are set; otherwise (or on any error) the sample stays."""
    result = await asyncio.to_thread(snaptrade_client.sync)
    log.warning("Investments: %s", result.get("message") or f"live SnapTrade sandbox, {result.get('holdings')} holdings")
    return result


@asynccontextmanager
async def lifespan(_app: FastAPI):
    task = asyncio.create_task(_sync_investments()) if config.snaptrade_enabled() else None
    yield
    if task and not task.done():
        task.cancel()


app = FastAPI(title="One Finance API", lifespan=lifespan)
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
            "snaptrade_keys": config.snaptrade_enabled(),
            "investments_source": _setting(conn, "investments_source") or "sample",
            "investments_synced_at": _setting(conn, "investments_synced_at"),
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


LUMPY_POCKETS = {"Home Rent", "Utilities"}  # monthly bills


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
        month = month or analytics.current_budget_month(conn)
        calendar_now = analytics.today(conn).strftime("%Y-%m")
    agents.rules_through(max(month, calendar_now))  # free pre-pass so the month is categorized
    with db.connect() as conn:
        budget = analytics.budget_status(conn, month)
        next_steps = _setting(conn, "latest_next_steps")
        from backend import prefs

        salary = prefs.salary_status(conn)
        return {
            "month": month,
            "salary": salary,
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
            "savings": analytics.savings_pockets(conn, month),
            "cash_check": analytics.cash_check(conn, month),
            "next_steps": next_steps or _default_next_steps(conn, budget),
            "next_steps_by": "advisor" if next_steps else "rules",
            "open_review_items": conn.execute("SELECT COUNT(*) FROM review_items WHERE status = 'open'").fetchone()[0],
            "months": [r[0] for r in conn.execute("SELECT DISTINCT substr(date, 1, 7) FROM transactions ORDER BY 1 DESC")],
        }


@app.get("/pockets")
def pockets() -> dict:
    """Active pockets (spending, then savings/investing) and the catalog of ones that can be added."""
    with db.connect() as conn:
        rows = [dict(r) for r in conn.execute(
            "SELECT name, kind, monthly_budget, goal_amount, goal_date, currency, active, custom, description"
            " FROM pockets ORDER BY sort")]
    return {"pockets": [r for r in rows if r["active"]], "catalog": [r for r in rows if not r["active"]]}


class PocketUpdate(BaseModel):
    monthly_budget: float | None = None
    goal_amount: float | None = None
    goal_date: str | None = None
    new_name: str | None = None
    active: bool | None = None


@app.patch("/pockets/{name}")
def update_pocket(name: str, body: PocketUpdate) -> dict:
    """Budget setup: change a pocket's monthly amount or goal, rename a custom pocket, add or remove it."""
    with db.connect() as conn:
        p = conn.execute("SELECT * FROM pockets WHERE name = ?", (name,)).fetchone()
        if not p:
            raise HTTPException(404, "No such pocket.")
        if body.monthly_budget is not None:
            if not 0 <= body.monthly_budget <= 100_000:
                raise HTTPException(400, "Monthly amount must be between 0 and 100,000.")
            conn.execute("UPDATE pockets SET monthly_budget = ? WHERE id = ?", (round(body.monthly_budget, 2), p["id"]))
        if body.goal_amount is not None:
            conn.execute("UPDATE pockets SET goal_amount = ? WHERE id = ?", (body.goal_amount or None, p["id"]))
        if body.goal_date is not None:
            conn.execute("UPDATE pockets SET goal_date = ? WHERE id = ?", (body.goal_date or None, p["id"]))
        if body.active is not None:
            conn.execute("UPDATE pockets SET active = ? WHERE id = ?", (int(body.active), p["id"]))
            if body.active and not p["active"]:  # switched on now: its budget starts this month
                conn.execute("UPDATE pockets SET start_month = ? WHERE id = ?",
                             (analytics.current_budget_month(conn), p["id"]))
        if body.new_name:
            if not p["custom"]:
                raise HTTPException(400, "Only custom pockets can be renamed.")
            new = body.new_name.strip()[:40]
            if not new or conn.execute("SELECT 1 FROM pockets WHERE name = ? AND id != ?", (new, p["id"])).fetchone():
                raise HTTPException(400, "Pick a new, unused name.")
            conn.execute("UPDATE pockets SET name = ? WHERE id = ?", (new, p["id"]))
        conn.commit()
    return {"ok": True}


# --- More tab -------------------------------------------------------------------------------
@app.get("/settings")
def get_settings() -> dict:
    """Profile, AI preferences, the exchange rate and which data the app is showing."""
    from backend import prefs

    with db.connect() as conn:
        return prefs.all_settings(conn)


@app.patch("/settings")
def patch_settings(body: dict) -> dict:
    from backend import prefs

    with db.connect() as conn:
        try:
            return prefs.update(conn, body)
        except ValueError as exc:
            raise HTTPException(400, str(exc))


@app.get("/connections")
def get_connections() -> dict:
    from backend import prefs

    with db.connect() as conn:
        return {"connections": prefs.connections(conn)}


@app.post("/connections/snaptrade/refresh")
async def refresh_snaptrade() -> dict:
    return await _sync_investments()


@app.get("/privacy/ai")
def what_the_ai_sees() -> dict:
    from backend import prefs

    return prefs.WHAT_THE_AI_SEES


@app.get("/export.csv")
def export_csv():
    from fastapi.responses import PlainTextResponse

    from backend import prefs

    with db.connect() as conn:
        return PlainTextResponse(prefs.export_csv(conn), media_type="text/csv",
                                 headers={"Content-Disposition": 'attachment; filename="one-finance-export.csv"'})


@app.post("/delete-all")
def delete_all() -> dict:
    """Delete all my data (working copy): empty database, live connections off."""
    from backend import prefs

    if _run_lock.locked():
        raise HTTPException(409, "An agent run is in progress.")
    return prefs.delete_all()


class ProblemReport(BaseModel):
    text: str
    app_version: str | None = None


@app.post("/report-problem")
def report_problem(body: ProblemReport) -> dict:
    from backend import prefs

    with db.connect() as conn:
        try:
            return prefs.save_problem(conn, body.text, body.app_version)
        except ValueError as exc:
            raise HTTPException(400, str(exc))


# --- Budget setup (Wallet → Edit pockets) -------------------------------------------------
@app.get("/budget")
def budget_plan() -> dict:
    """Everything Budget setup shows: income, the plan in $ and %, every pocket with this month's
    numbers, the catalog, the IDR rate, and whether this is a first-time setup."""
    from backend import budget

    with db.connect() as conn:
        return budget.plan(conn)


class PlanPocket(BaseModel):
    name: str
    kind: Literal["income", "spending", "saving", "investing"] | None = None
    monthly: float = 0
    new_name: str | None = None
    is_new: bool = False
    goal_amount: float | None = None
    goal_date: str | None = None
    starting_amount: float | None = None
    frequency: str | None = None
    received_in: str | None = None


class PlanSave(BaseModel):
    apply: Literal["this_month", "next_month"] = "this_month"
    pockets: list[PlanPocket]
    cover_from: str | None = None


@app.post("/budget/save")
def budget_save(body: PlanSave):
    """Save Budget setup in one go. Over income → 409 with how much and the pockets that could cover it."""
    from fastapi.responses import JSONResponse

    from backend import budget

    with db.connect() as conn:
        try:
            return budget.save_plan(conn, apply=body.apply, pockets=[p.model_dump() for p in body.pockets],
                                    cover_from=body.cover_from)
        except budget.OverIncome as exc:
            conn.rollback()
            return JSONResponse(status_code=409, content={"detail": str(exc), "over": exc.over, "extra": exc.extra,
                                                          "sources": exc.sources})
        except budget.BudgetError as exc:
            conn.rollback()
            raise HTTPException(400, str(exc))


class ArchiveBody(BaseModel):
    move_to: str | None = None


@app.post("/budget/pockets/{name}/archive")
def budget_archive(name: str, body: ArchiveBody) -> dict:
    """Archive a pocket; its money goes to `move_to` (or Unsorted / Unassigned)."""
    from backend import budget

    with db.connect() as conn:
        try:
            return budget.archive(conn, name, body.move_to)
        except budget.BudgetError as exc:
            conn.rollback()
            raise HTTPException(400, str(exc))


@app.get("/budget/hint")
def budget_hint(name: str) -> dict:
    """What the owner spent on something like `name` per month lately (for the Add spending pocket form)."""
    from backend import budget

    with db.connect() as conn:
        return {"hint": budget.spending_hint(conn, name)}


@app.post("/budget/start-over")
def budget_start_over() -> dict:
    """Testing / demo: switch every pocket off so Budget setup opens on the first-time choice.
    Working copy only; Reset (Other tab) restores the sample."""
    from backend import budget

    if _run_lock.locked():
        raise HTTPException(409, "An agent run is in progress.")
    with db.connect() as conn:
        return budget.start_over(conn)


class NewPocket(BaseModel):
    name: str
    kind: Literal["spending", "saving", "investing"] = "spending"
    monthly_budget: float = 0
    goal_amount: float | None = None
    goal_date: str | None = None


@app.post("/pockets")
def create_pocket(body: NewPocket) -> dict:
    """+ New pocket from the More… sheet."""
    from backend import entries

    with db.connect() as conn:
        try:
            return entries.create_pocket(conn, name=body.name, kind=body.kind, monthly_budget=body.monthly_budget,
                                         goal_amount=body.goal_amount, goal_date=body.goal_date)
        except entries.EntryError as exc:
            raise HTTPException(400, str(exc))


@app.get("/wallet")
def wallet() -> dict:
    """Everything on the Wallet screen (see mockups/wallet-dark.html)."""
    with db.connect() as conn:
        month = analytics.current_budget_month(conn)
        calendar_now = analytics.today(conn).strftime("%Y-%m")
    agents.rules_through(calendar_now)
    with db.connect() as conn:
        moves = [dict(r) for r in conn.execute(
            """SELECT m.id, m.date, m.amount, m.note, m.created_by, m.undone, f.name AS from_pocket, t.name AS to_pocket
               FROM pocket_moves m LEFT JOIN pockets f ON f.id = m.from_pocket_id LEFT JOIN pockets t ON t.id = m.to_pocket_id
               ORDER BY m.id DESC LIMIT 10""")]
        return {
            "month": month,
            "balance": analytics.balance_change_this_month(conn),
            "institutions": analytics.institutions(conn),
            "debts": analytics.debts(conn),
            "spending": analytics.budget_status(conn, month),
            "savings": analytics.savings_pockets(conn, month),
            "cash_check": analytics.cash_check(conn, month),
            "moves": moves,
            "unsorted": dict(conn.execute(
                "SELECT COUNT(*) AS count, COALESCE(ROUND(SUM(amount), 2), 0) AS amount FROM ledger_entries"
                " WHERE direction = 'expense' AND pocket_id IS NULL AND currency = 'USD'").fetchone()),
            "open_review_items": conn.execute("SELECT COUNT(*) FROM review_items WHERE status = 'open'").fetchone()[0],
        }


@app.post("/moves/{move_id}/undo")
def undo_move(move_id: int) -> dict:
    with db.connect() as conn:
        cur = conn.execute("UPDATE pocket_moves SET undone = 1 WHERE id = ? AND undone = 0", (move_id,))
        conn.commit()
    if cur.rowcount == 0:
        raise HTTPException(404, "No move to undo with that id.")
    return {"ok": True}


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
        p = conn.execute("SELECT id FROM pockets WHERE name = ? AND active = 1 AND kind IN ('spending', 'saving')",
                         (body.pocket,)).fetchone()
        if not p:
            raise HTTPException(400, "Pick an active spending or savings pocket.")
        cur = conn.execute(
            "INSERT INTO ledger_entries (date, description, amount, currency, direction, pocket_id, status, recorded_by,"
            " note, created_at) VALUES (?,?,?,?,?,?,?,?,?,datetime('now'))",
            (body.date, body.description.strip()[:120], round(body.amount, 2), "USD", "expense", p["id"], "recorded",
             "user", "Manual entry: no receipt or bank charge yet"))
        conn.commit()
    return {"ok": True, "id": cur.lastrowid}


# --- The + button: add expense, add income, scan receipt, quick type ----------------------
class ExpenseIn(BaseModel):
    amount: float
    currency: Literal["USD", "IDR"] = "USD"
    pocket: str | None = None  # None = "Not sure" (Unsorted, the Accountant suggests one)
    paid_with: str  # 'cash_usd', 'cash_idr' or an account id
    note: str | None = None
    date: str
    receipt_id: int | None = None


@app.post("/entries/expense")
def add_expense(body: ExpenseIn) -> dict:
    from backend import entries

    with db.connect() as conn:
        try:
            return entries.add_expense(conn, amount=body.amount, currency=body.currency, pocket=body.pocket,
                                       paid_with=body.paid_with, note=body.note, on=body.date, receipt_id=body.receipt_id)
        except entries.EntryError as exc:
            raise HTTPException(400, str(exc))


class Assign(BaseModel):
    pocket: str
    amount: float


class IncomeIn(BaseModel):
    amount: float
    currency: Literal["USD", "IDR"] = "USD"
    source: str
    received_in: str
    date: str
    note: str | None = None
    assign: list[Assign] = []


@app.post("/entries/income")
def add_income(body: IncomeIn) -> dict:
    from backend import entries

    with db.connect() as conn:
        try:
            return entries.add_income(conn, amount=body.amount, currency=body.currency, source=body.source,
                                      received_in=body.received_in, on=body.date, note=body.note,
                                      assign=[a.model_dump() for a in body.assign])
        except entries.EntryError as exc:
            raise HTTPException(400, str(exc))


@app.get("/paid-with")
def paid_with_options() -> dict:
    """Cash plus every bank account and card, for the Paid with / Received in pickers."""
    with db.connect() as conn:
        accounts = [dict(r) for r in conn.execute(
            "SELECT id, institution, name, type, mask, currency FROM accounts WHERE type IN ('depository', 'credit')")]
    order = analytics.INSTITUTION_ORDER
    accounts.sort(key=lambda a: (order.index(a["institution"]) if a["institution"] in order else 99, a["type"]))
    return {"options": [{"id": "cash_usd", "label": "Cash (USD)", "currency": "USD"},
                        {"id": "cash_idr", "label": "Cash (IDR)", "currency": "IDR"}]
            + [{"id": a["id"], "label": f"{a['name']} ••{a['mask']}", "currency": a["currency"]} for a in accounts]}


@app.get("/pockets/chips")
def pocket_chips(note: str = "", amount: float = 0, currency: str = "USD") -> dict:
    """Pocket chips for the + forms: the suggestion first, then the most used, each with what's
    left this month and whether this amount would push it over. Plus every pocket for More…"""
    from backend import rules

    with db.connect() as conn:
        month = analytics.current_budget_month(conn)
        usd = amount * analytics.fx(conn).get(currency, 1.0)
        spending = {p["name"]: p for p in analytics.spending_pockets(conn, month)}
        saving = {p["name"]: p for p in analytics.savings_pockets(conn, month)}
        suggested = None
        if note.strip():
            rule = rules.classify(note, note)
            if rule and rule[0] in spending:
                suggested = rule[0]
            else:
                row = conn.execute(
                    """SELECT p.name, COUNT(*) n FROM ledger_entries e JOIN pockets p ON p.id = e.pocket_id
                       WHERE e.direction = 'expense' AND p.active = 1 AND e.description LIKE ?
                       GROUP BY p.name ORDER BY n DESC LIMIT 1""", (f"%{note.strip()[:40]}%",)).fetchone()
                suggested = row["name"] if row else None
        used = [r["name"] for r in conn.execute(
            """SELECT p.name, COUNT(*) n FROM ledger_entries e JOIN pockets p ON p.id = e.pocket_id
               WHERE e.direction = 'expense' AND p.active = 1 AND p.kind = 'spending' AND e.date >= date(?, '-90 day')
               GROUP BY p.name ORDER BY n DESC""", (analytics.today(conn).isoformat(),))]

    def chip(name: str) -> dict:
        if name in spending:
            left = spending[name]["left"]
            return {"name": name, "kind": "spending", "left": left, "would_go_over": usd > 0 and usd > left}
        s = saving.get(name, {})
        return {"name": name, "kind": s.get("kind", "saving"), "left": s.get("total", 0),
                "would_go_over": usd > 0 and usd > s.get("total", 0)}

    order = ([suggested] if suggested else []) + [u for u in used if u != suggested]
    order += [n for n in spending if n not in order]
    return {
        "suggested": suggested,
        "chips": [chip(n) for n in order[:5]],
        "all": [chip(n) for n in spending] + [chip(n) for n in saving if saving[n]["kind"] == "saving"],
    }


class QuickText(BaseModel):
    text: str


@app.post("/entries/parse")
async def parse_entry(body: QuickText) -> dict:
    """'Or type it': the AI turns one line into Add expense form fields (nothing is saved)."""
    if not body.text.strip() or len(body.text) > 300:
        raise HTTPException(400, "Type a short line, like 'lunch 12.50 Chipotle cash'.")
    return await _run(agents.parse_quick_entry, body.text)


class ImageIn(BaseModel):
    image_base64: str
    media_type: str = "image/jpeg"


def _decode_image(body: ImageIn) -> bytes:
    import base64

    try:
        data = base64.b64decode(body.image_base64, validate=True)
    except Exception as exc:
        raise HTTPException(400, "That isn't a valid image.") from exc
    if len(data) > 8_000_000:
        raise HTTPException(400, "The photo is too large (8 MB max).")
    if not (data[:3] == b"\xff\xd8\xff" or data[:8] == b"\x89PNG\r\n\x1a\n" or data[4:12] in (b"ftypheic", b"ftypmif1")):
        raise HTTPException(400, "Use a JPEG, PNG or HEIC photo.")
    return data


@app.post("/receipts/scan")
async def scan_receipt(body: ImageIn) -> dict:
    """Scan receipt: the Accountant reads the photo; nothing is recorded until Confirm."""
    data = _decode_image(body)
    return await _run(agents.scan_receipt, data, body.media_type)


class ReceiptLine(BaseModel):
    name: str
    price: float
    pocket: str


class ReceiptConfirm(BaseModel):
    items: list[ReceiptLine]
    paid_with: str
    transaction_id: str | None = None  # the bank charge it matches, if any
    date: str | None = None  # the owner's pick (YYYY-MM-DD) when the photo's date was unreadable or wrong


@app.post("/receipts/{receipt_id}/confirm")
def confirm_receipt(receipt_id: int, body: ReceiptConfirm) -> dict:
    """Record a scanned receipt, split by pocket. If it matches a bank charge, it replaces that
    charge's single entry (never counted twice); paid by card without a match yet, it waits."""
    from backend import entries

    with db.connect() as conn:
        r = conn.execute("SELECT * FROM receipts WHERE id = ?", (receipt_id,)).fetchone()
        if not r or r["total"] is None:
            raise HTTPException(404, "Read the receipt first.")
        if r["status"] == "matched" or conn.execute("SELECT 1 FROM ledger_entries WHERE receipt_id = ?", (receipt_id,)).fetchone():
            raise HTTPException(409, "This receipt is already recorded.")
        day = body.date or r["date"] or ""
        try:
            pay_currency, account_id = entries.check_common(conn, r["total"], day, body.paid_with)
            for i in body.items:
                entries.pocket_id(conn, i.pocket)
        except entries.EntryError as exc:
            raise HTTPException(400, str(exc))
        split = entries.split_receipt(r["total"], r["tax"] or 0, [i.model_dump() for i in body.items])
        status, tx = ("recorded", None) if account_id is None else ("waiting_charge", None)
        if body.transaction_id:
            t = conn.execute("SELECT * FROM transactions WHERE id = ?", (body.transaction_id,)).fetchone()
            if not t or abs(t["amount"] - r["total"]) > 0.01:
                raise HTTPException(400, "That bank charge doesn't match the receipt total.")
            conn.execute("DELETE FROM ledger_entries WHERE transaction_id = ? AND receipt_id IS NULL", (t["id"],))
            status, tx, account_id = "recorded", t["id"], t["account_id"]
        for pocket, amount in split.items():
            conn.execute(
                "INSERT INTO ledger_entries (transaction_id, date, description, amount, currency, direction, pocket_id,"
                " account_id, receipt_id, status, recorded_by, note, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,datetime('now'))",
                (tx, day, r["store"], amount, pay_currency, "expense", entries.pocket_id(conn, pocket), account_id,
                 receipt_id, status, "user", "Scanned receipt" + (" (split)" if len(split) > 1 else "")))
        conn.execute("UPDATE receipt_items SET name = name WHERE receipt_id = ?", (receipt_id,))
        conn.execute("UPDATE receipts SET status = ?, date = ? WHERE id = ?", ("matched" if tx else "read", day, receipt_id))
        conn.commit()
    return {"ok": True, "split": split, "status": status}


@app.get("/portfolio")
def portfolio() -> dict:
    from backend.tools import portfolio_snapshot

    from backend.tools import portfolio_overview

    with db.connect() as conn:
        return {"snapshot": portfolio_snapshot(conn), "overview": portfolio_overview(conn),
                "latest_brief": _setting(conn, "latest_portfolio_brief"),
                "source": _setting(conn, "investments_source") or "sample"}


@app.get("/portfolio/history")
def portfolio_history(days: int = 365) -> dict:
    """Total brokerage value per day (all investment accounts) for the Invest chart."""
    with db.connect() as conn:
        end = analytics.today(conn)
        rows = conn.execute(
            """SELECT h.date, ROUND(SUM(h.balance * f.usd_per_unit), 2) AS total
               FROM balance_history h JOIN accounts a ON a.id = h.account_id JOIN fx_rates f ON f.currency = a.currency
               WHERE a.type = 'investment' AND h.date > date(?, ?) AND h.date <= ? GROUP BY h.date ORDER BY h.date""",
            (end.isoformat(), f"-{max(1, min(days, 800))} day", end.isoformat())).fetchall()
        synthetic_before = _setting(conn, "synthetic_history_before")
    return {"points": [dict(r) for r in rows], "synthetic_before": synthetic_before}


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
            """SELECT id, step, agent, chain, step_type, tool, text, data_json, input_tokens, cached_tokens, output_tokens,
                      created_at FROM run_log WHERE run_id = ? ORDER BY id""", (run_id,)).fetchall()
    if not rows:
        raise HTTPException(404, "No such run.")
    return {"run_id": run_id, "steps": [dict(r) for r in rows]}


@app.get("/balance-history")
def balance_history(days: int = 30) -> dict:
    """What I own per day (USD, cash + investments; debts are separate) for the area chart."""
    with db.connect() as conn:
        end = analytics.today(conn)
        rows = conn.execute(
            """SELECT h.date, ROUND(SUM(h.balance * f.usd_per_unit), 2) AS total
               FROM balance_history h JOIN accounts a ON a.id = h.account_id JOIN fx_rates f ON f.currency = a.currency
               WHERE a.type IN ('depository', 'investment') AND h.date > date(?, ?) AND h.date <= ? GROUP BY h.date ORDER BY h.date""",
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
    pocket: str | None = None  # for an Unsorted expense: the pocket chosen (defaults to the suggestion)


@app.post("/review/{item_id}/resolve")
def resolve_review(item_id: int, body: Resolve) -> dict:
    with db.connect() as conn:
        item = conn.execute("SELECT * FROM review_items WHERE id = ? AND status = 'open'", (item_id,)).fetchone()
        if not item:
            raise HTTPException(404, "No open review item with that id.")
        if item["kind"] == "unsorted" and item["entry_id"] and body.status != "dismissed":
            pid = item["pocket_id"]
            if body.pocket:
                row = conn.execute("SELECT id FROM pockets WHERE name = ? AND active = 1", (body.pocket,)).fetchone()
                if not row:
                    raise HTTPException(400, "Pick an active pocket.")
                pid = row["id"]
            if not pid:
                raise HTTPException(400, "No pocket suggested yet; pick one.")
            conn.execute("UPDATE ledger_entries SET pocket_id = ? WHERE id = ?", (pid, item["entry_id"]))
        conn.execute("UPDATE review_items SET status = ?, resolved_at = datetime('now') WHERE id = ?", (body.status, item_id))
        conn.commit()
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
async def reset() -> dict:
    if _run_lock.locked():
        raise HTTPException(409, "An agent run is in progress.")
    db.reset_working_db()
    investments = await _sync_investments() if config.snaptrade_enabled() else {"source": "sample"}
    return {"ok": True, "investments": investments.get("source")}


@app.post("/investments/sync")
async def sync_investments() -> dict:
    """Pull the SnapTrade sandbox again (accounts, balances, positions, activity, today's value)."""
    return await _sync_investments()


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
    from backend import prefs

    with db.connect() as conn:
        if not prefs.is_on(conn, "ai_investment_suggestions"):
            raise HTTPException(409, "Investment suggestions are off (More → AI preferences).")
    return await _run(agents.portfolio_brief)


@app.post("/agents/weekly-digest")
async def run_weekly_digest() -> dict:
    return await _run(agents.weekly_digest)


@app.post("/agents/suggest-budget")
async def run_suggest_budget() -> dict:
    return await _run(agents.suggest_budget)


@app.post("/agents/draft-budget")
async def run_draft_budget() -> dict:
    """First-time setup: the Advisor drafts a budget from the bank history (nothing is saved)."""
    return await _run(agents.draft_budget)


@app.post("/agents/chat")
async def run_chat(body: ChatBody) -> dict:
    if not body.question.strip() or len(body.question) > 2000:
        raise HTTPException(400, "Ask a question of up to 2,000 characters.")
    return await _run(agents.chat, body.question)
