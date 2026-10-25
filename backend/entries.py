"""Things the owner adds by hand with the + button: expenses, income, scanned receipts.

Nothing is counted twice:
- Paid with cash: the entry stands on its own.
- Paid by card or account: the entry is marked "waiting for bank charge" (or "waiting for
  deposit" for income). When the bank charge arrives, `link_waiting` connects it to this
  entry instead of recording it again.
"""

import re
import sqlite3
from datetime import date, datetime, timedelta, timezone

from backend import analytics

CASH = {"cash_usd": "USD", "cash_idr": "IDR"}
INCOME_SOURCES = ("salary", "freelance", "gift", "refund", "other")

# Text on a receipt that looks like it's talking to the AI (prompt injection defense).
SUSPICIOUS = re.compile(
    r"\b(ignore|disregard|override|instruction|system prompt|assistant|approve|you are|forget|"
    r"pretend|jailbreak|developer mode)\b", re.IGNORECASE)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class EntryError(ValueError):
    pass


def check_common(conn: sqlite3.Connection, amount: float, on: str, paid_with: str) -> tuple[str, str | None]:
    """Shared checks. Returns (currency_from_payment_or_empty, account_id or None)."""
    if not (0 < amount <= 1_000_000_000):
        raise EntryError("Amount must be more than 0.")
    try:
        day = date.fromisoformat(on)
    except ValueError as exc:
        raise EntryError("Date must be YYYY-MM-DD.") from exc
    if day > analytics.today(conn):
        raise EntryError("The date can't be in the future.")
    if paid_with in CASH:
        return CASH[paid_with], None
    acct = conn.execute("SELECT id, currency FROM accounts WHERE id = ? AND type != 'investment'", (paid_with,)).fetchone()
    if not acct:
        raise EntryError("Pick cash or one of your bank accounts or cards.")
    return acct["currency"], acct["id"]


def pocket_id(conn: sqlite3.Connection, name: str, allow_investing: bool = False) -> int:
    row = conn.execute("SELECT id, kind FROM pockets WHERE name = ? AND active = 1", (name,)).fetchone()
    if not row or (row["kind"] == "investing" and not allow_investing):
        raise EntryError("Pick an active spending or savings pocket.")
    return row["id"]


def add_expense(conn: sqlite3.Connection, *, amount: float, currency: str, pocket: str | None, paid_with: str,
                note: str | None, on: str, receipt_id: int | None = None) -> dict:
    """pocket=None means "Not sure": the expense goes to Unsorted, and the Accountant
    suggests a pocket later in the Review tray."""
    pay_currency, account_id = check_common(conn, amount, on, paid_with)
    if currency not in ("USD", "IDR"):
        raise EntryError("Currency must be USD or IDR.")
    if pay_currency != currency:
        raise EntryError(f"That account is in {pay_currency}; enter the amount in {pay_currency}.")
    pid = pocket_id(conn, pocket) if pocket else None
    waiting = account_id is not None
    label = (note or pocket or "Expense").strip()[:120]
    cur = conn.execute(
        "INSERT INTO ledger_entries (date, description, amount, currency, direction, pocket_id, account_id, receipt_id,"
        " status, recorded_by, note, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        (on, label, round(amount, 2), currency, "expense", pid, account_id, receipt_id,
         "waiting_charge" if waiting else "recorded", "user",
         "Waiting for the bank charge" if waiting else "Paid with cash", _now()))
    if pid is None:
        conn.execute(
            "INSERT INTO review_items (kind, month, entry_id, amount, detail, created_by, created_at)"
            " VALUES (?,?,?,?,?,?,?)",
            ("unsorted", on[:7], cur.lastrowid, round(amount, 2),
             f"Not sure which pocket: {label}, {currency} {amount:,.2f} on {on}. The Accountant will suggest one.",
             "user", _now()))
    conn.commit()
    return {"ok": True, "id": cur.lastrowid, "status": "waiting_charge" if waiting else "recorded",
            "unsorted": pid is None}


def create_pocket(conn: sqlite3.Connection, *, name: str, kind: str, monthly_budget: float,
                  goal_amount: float | None, goal_date: str | None) -> dict:
    """+ New pocket, made on the spot from the More… sheet."""
    name = name.strip()[:40]
    if not name:
        raise EntryError("Give the pocket a name.")
    if kind not in ("spending", "saving", "investing"):
        raise EntryError("Kind must be spending, saving or investing.")
    if not 0 <= monthly_budget <= 100_000:
        raise EntryError("Monthly amount must be between 0 and 100,000.")
    existing = conn.execute("SELECT id, active FROM pockets WHERE name = ? COLLATE NOCASE", (name,)).fetchone()
    if existing and existing["active"]:
        raise EntryError(f"There's already a pocket called {name}.")
    start = analytics.today(conn).strftime("%Y-%m")  # its budget starts this month, not back at the budget start
    if existing:  # it's in the catalog: switch it on with the new settings
        conn.execute("UPDATE pockets SET active = 1, kind = ?, monthly_budget = ?, goal_amount = ?, goal_date = ?,"
                     " start_month = ? WHERE id = ?",
                     (kind, monthly_budget, goal_amount, goal_date, start, existing["id"]))
    else:
        sort = conn.execute("SELECT COALESCE(MAX(sort), 0) + 1 FROM pockets").fetchone()[0]
        conn.execute(
            "INSERT INTO pockets (name, kind, monthly_budget, goal_amount, goal_date, active, custom, sort, description,"
            " start_month) VALUES (?,?,?,?,?,1,1,?,?,?)",
            (name, kind, monthly_budget, goal_amount, goal_date, sort, "Added from the + button", start))
    conn.commit()
    return {"ok": True, "name": name}


def add_income(conn: sqlite3.Connection, *, amount: float, currency: str, source: str, received_in: str, on: str,
               note: str | None, assign: list[dict]) -> dict:
    pay_currency, account_id = check_common(conn, amount, on, received_in)
    if source not in INCOME_SOURCES:
        raise EntryError(f"Source must be one of: {', '.join(INCOME_SOURCES)}.")
    if pay_currency != currency:
        raise EntryError(f"That account is in {pay_currency}; enter the amount in {pay_currency}.")
    rate = analytics.fx(conn).get(currency, 1.0)
    total_assigned = sum(a["amount"] for a in assign)
    if total_assigned > amount * rate + 0.01:
        raise EntryError("You can't assign more than the income.")
    waiting = account_id is not None
    cur = conn.execute(
        "INSERT INTO ledger_entries (date, description, amount, currency, direction, account_id, status, recorded_by,"
        " note, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
        (on, (note or source.capitalize()).strip()[:120], -round(amount, 2), currency, "income", account_id,
         "waiting_deposit" if waiting else "recorded", "user", f"income:{source}", _now()))
    for a in assign:
        if a["amount"] <= 0:
            continue
        conn.execute(
            "INSERT INTO pocket_moves (date, from_pocket_id, to_pocket_id, amount, note, created_by, created_at)"
            " VALUES (?,?,?,?,?,?,?)",
            (on, None, pocket_id(conn, a["pocket"], allow_investing=True), round(a["amount"], 2),
             f"From new income ({source})", "user", _now()))
    conn.commit()
    return {"ok": True, "id": cur.lastrowid, "status": "waiting_deposit" if waiting else "recorded"}


def link_waiting(conn: sqlite3.Connection, t: sqlite3.Row) -> bool:
    """If a bank transaction is the charge (or deposit) for something the owner already
    added by hand, connect them instead of recording it again. Returns True if linked."""
    day = date.fromisoformat(t["date"])
    lo, hi = (day - timedelta(days=5)).isoformat(), (day + timedelta(days=2)).isoformat()
    status = "waiting_charge" if t["amount"] > 0 else "waiting_deposit"
    rows = conn.execute(
        "SELECT id, amount, receipt_id FROM ledger_entries WHERE status = ? AND (account_id = ? OR account_id IS NULL)"
        " AND date BETWEEN ? AND ? AND currency = ?",
        (status, t["account_id"], lo, hi, t["currency"])).fetchall()
    groups: dict[str, list] = {}
    for r in rows:  # a scanned receipt split across pockets is one charge
        groups.setdefault(f"r{r['receipt_id']}" if r["receipt_id"] else f"e{r['id']}", []).append(r)
    for entries in groups.values():
        if abs(sum(e["amount"] for e in entries) - t["amount"]) <= 0.01:
            conn.executemany(
                "UPDATE ledger_entries SET transaction_id = ?, status = 'recorded', note = 'Matched to the bank charge'"
                " WHERE id = ?", [(t["id"], e["id"]) for e in entries])
            return True
    return False


def split_receipt(total: float, tax: float, items: list[dict]) -> dict[str, float]:
    """Pocket → amount for a receipt split by item, tax shared in proportion; sums to the total."""
    subtotal = sum(i["price"] for i in items) or 1.0
    by_pocket: dict[str, float] = {}
    for i in items:
        by_pocket[i["pocket"]] = by_pocket.get(i["pocket"], 0.0) + i["price"] * (1 + tax / subtotal)
    rounded = {k: round(v, 2) for k, v in by_pocket.items()}
    biggest = max(rounded, key=rounded.get)
    rounded[biggest] = round(rounded[biggest] + total - sum(rounded.values()), 2)
    return rounded


def receipt_checks(conn: sqlite3.Connection, receipt_id: int, r) -> list[dict]:
    """Code checks on a read receipt: math, duplicate, suspicious text."""
    checks = []
    items_sum = round(sum(i.price for i in r.items), 2)
    ok_math = abs(items_sum - r.subtotal) <= 0.02 and abs(r.subtotal + r.tax - r.total) <= 0.01
    checks.append({"name": "Items + tax = total", "ok": ok_math,
                   "detail": f"{items_sum:.2f} + {r.tax:.2f} tax = {r.subtotal + r.tax:.2f}; total {r.total:.2f}"})
    dup = conn.execute(
        "SELECT id FROM receipts WHERE id != ? AND date = ? AND ABS(total - ?) < 0.005 AND LOWER(store) LIKE ?",
        (receipt_id, r.date, r.total, f"%{r.store.split()[0].lower()}%")).fetchone()
    checks.append({"name": "Not a duplicate", "ok": dup is None,
                   "detail": f"Same store, date and total as receipt #{dup['id']}" if dup else "No other receipt like it"})
    text = " ".join([r.store, *[i.name for i in r.items], *r.problems])
    sus = SUSPICIOUS.search(text)
    checks.append({"name": "No suspicious text", "ok": sus is None,
                   "detail": f"The receipt contains '{sus.group(0)}', which looks like an instruction to the AI. "
                             "It was treated as data only." if sus else "Nothing that looks like an instruction"})
    return checks
