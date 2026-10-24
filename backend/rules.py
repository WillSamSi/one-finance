"""Plain-Python pre-pass before the Accountant (a cost cut: no tokens spent on obvious ones).

Records transactions whose merchant clearly belongs to one pocket. Leaves for the AI:
stores where a receipt or order decides the pocket (Walmart, Target, Amazon), unknown
merchants, possible duplicates, pending charges, and all Indonesian statements.
"""

import sqlite3
from datetime import date, datetime, timezone

from backend import analytics, entries

# (words to look for, pocket or None, direction, note)
# Pockets aren't tied to accounts, so moving money between my own accounts is a transfer
# with no pocket. Money sent to the brokerage leaves the Investment pocket ("ready to invest").
RULES: list[tuple[tuple[str, ...], str | None, str, str | None]] = [
    (("PAYROLL",), None, "income", None),
    (("INTEREST EARNED",), None, "income", None),
    (("ZELLE PAYMENT FROM",), None, "income", None),
    (("ONLINE TRANSFER TO BOFA",), None, "transfer", "to_savings"),
    (("TRANSFER FROM CHASE",), None, "transfer", "from_own_account"),
    (("FIDELITY INVESTMENTS",), "Investment", "transfer", "to_brokerage"),
    (("CREDIT CARD PMT", "CREDIT CRD AUTOPAY", "PAYMENT - THANK YOU", "AUTOMATIC PAYMENT"), None, "transfer", "card_payment"),
    (("ELM CITY APTS",), "Home Rent", "expense", None),
    (("EVERSOURCE", "T-MOBILE"), "Utilities", "expense", None),
    (("TRADER JOE", "ALDI", "STARBUCKS", "SWEETGREEN", "SHAKE SHACK", "BLUE STATE COFFEE"), "Food", "expense", None),
    (("UBER", "SHELL"), "Transportation", "expense", None),
    (("CVS",), "Healthcare", "expense", None),
    (("PLANET FITNESS", "DICK'S SPORTING"), "Sports", "expense", None),
    (("COURSERA", "YALE BOOKSTORE"), "Education", "expense", None),
]


def classify(description: str, merchant: str | None) -> tuple[str | None, str, str | None] | None:
    text = f"{description} {merchant or ''}".upper()
    for words, pocket, direction, note in RULES:
        if any(w in text for w in words):
            return pocket, direction, note
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
    recorded, left, linked = 0, 0, 0
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    for t in rows:
        # Something the owner already added by hand (card-paid expense, scanned receipt, income)?
        # Link it instead of counting the money twice.
        if entries.link_waiting(conn, t):
            linked += 1
            continue
        rule = None if t["id"] in dupes else classify(t["description"], t["merchant_name"])
        if rule is None:
            left += 1
            continue
        pocket, direction, note = rule
        conn.execute(
            "INSERT INTO ledger_entries (transaction_id, date, description, amount, currency, direction, pocket_id,"
            " account_id, status, recorded_by, note, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (t["id"], t["date"], t["merchant_name"] or t["description"], t["amount"], t["currency"], direction,
             pockets.get(pocket) if pocket else None, t["account_id"], "recorded", "rules", note, now),
        )
        recorded += 1
    conn.commit()
    return {"month": month, "recorded_by_rules": recorded, "linked_to_hand_entries": linked,
            "left_for_accountant": left, "possible_duplicates": len(dupes)}
