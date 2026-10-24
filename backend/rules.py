"""Plain-Python pre-pass before the Accountant (a cost cut: no tokens spent on obvious ones).

Records transactions whose merchant clearly belongs to one pocket. Leaves for the AI:
stores where a receipt or order decides the pocket (Walmart, Target, Amazon), unknown
merchants, possible duplicates, pending charges, and all Indonesian statements.
"""

import sqlite3
from datetime import date, datetime, timezone

from backend import analytics

# (words to look for, pocket or None, direction)
RULES: list[tuple[tuple[str, ...], str | None, str]] = [
    (("PAYROLL",), None, "income"),
    (("INTEREST EARNED",), None, "income"),
    (("ZELLE PAYMENT FROM",), None, "income"),
    # A savings transfer appears twice: count it once, on the side where the money lands.
    (("ONLINE TRANSFER TO BOFA",), None, "transfer"),
    (("TRANSFER FROM CHASE",), "Emergency Fund", "transfer"),
    (("FIDELITY INVESTMENTS",), "Investing", "transfer"),
    (("CREDIT CARD PMT", "CREDIT CRD AUTOPAY", "PAYMENT - THANK YOU", "AUTOMATIC PAYMENT"), None, "transfer"),
    (("ELM CITY APTS",), "Rent / mortgage", "expense"),
    (("EVERSOURCE", "T-MOBILE"), "Utilities", "expense"),
    (("TRADER JOE", "ALDI"), "Groceries", "expense"),
    (("STARBUCKS", "SWEETGREEN", "SHAKE SHACK", "BLUE STATE COFFEE"), "Dining", "expense"),
    (("UBER", "SHELL"), "Transportation", "expense"),
    (("NETFLIX", "SPOTIFY", "APPLE.COM/BILL"), "Entertainment", "expense"),
    (("CVS",), "Healthcare", "expense"),
]


def classify(description: str, merchant: str | None) -> tuple[str | None, str] | None:
    text = f"{description} {merchant or ''}".upper()
    for words, pocket, direction in RULES:
        if any(w in text for w in words):
            return pocket, direction
    return None


def possible_duplicates(conn: sqlite3.Connection, first: str, last: str) -> set[str]:
    """Same account, same amount, same description, within 3 days: left for the AI to judge."""
    rows = conn.execute(
        "SELECT id, account_id, date, description, amount FROM transactions WHERE date BETWEEN date(?, '-3 day') AND date(?, '+3 day')",
        (first, last),
    ).fetchall()
    dupes: set[str] = set()
    for i, a in enumerate(rows):
        for b in rows[i + 1:]:
            if (a["account_id"], a["description"], a["amount"]) == (b["account_id"], b["description"], b["amount"]) and \
                    abs((date.fromisoformat(a["date"]) - date.fromisoformat(b["date"])).days) <= 3:
                dupes |= {a["id"], b["id"]}
    return dupes


def auto_record(conn: sqlite3.Connection, month: str) -> dict:
    first, last = (d.isoformat() for d in analytics.month_range(month))
    pockets = {r["name"]: r["id"] for r in conn.execute("SELECT id, name FROM pockets")}
    dupes = possible_duplicates(conn, first, last)
    rows = conn.execute(
        """SELECT t.* FROM transactions t
           WHERE t.date BETWEEN ? AND ? AND t.pending = 0
           AND NOT EXISTS (SELECT 1 FROM ledger_entries e WHERE e.transaction_id = t.id)""",
        (first, last),
    ).fetchall()
    recorded, left = 0, 0
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    for t in rows:
        rule = None if t["id"] in dupes else classify(t["description"], t["merchant_name"])
        if rule is None:
            left += 1
            continue
        pocket, direction = rule
        conn.execute(
            "INSERT INTO ledger_entries (transaction_id, date, description, amount, currency, direction, pocket_id,"
            " account_id, status, recorded_by, note, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (t["id"], t["date"], t["merchant_name"] or t["description"], t["amount"], t["currency"], direction,
             pockets.get(pocket) if pocket else None, t["account_id"], "recorded", "rules", None, now),
        )
        recorded += 1
    conn.commit()
    return {"month": month, "recorded_by_rules": recorded, "left_for_accountant": left, "possible_duplicates": len(dupes)}
