"""Plain-Python money math (no AI): budgets, cash flow, pace, balances.

Used by the agents' tools and by the Home screen, so both always show the same numbers.
All amounts are converted to USD with the fx_rates table.
"""

import calendar
import sqlite3
from datetime import date, timedelta

from backend import db

FIXED_BILLS = {"Rent / mortgage"}  # shown as "Paid" once fully spent


def month_range(month: str) -> tuple[date, date]:
    y, m = (int(x) for x in month.split("-"))
    return date(y, m, 1), date(y, m, calendar.monthrange(y, m)[1])


def today(conn: sqlite3.Connection) -> date:
    return date.fromisoformat(db.app_date(conn) or date.today().isoformat())


def fx(conn: sqlite3.Connection) -> dict[str, float]:
    return {r["currency"]: r["usd_per_unit"] for r in conn.execute("SELECT currency, usd_per_unit FROM fx_rates")}


def previous_months(month: str, n: int) -> list[str]:
    first, _ = month_range(month)
    out = []
    for _ in range(n):
        first = (first - timedelta(days=1)).replace(day=1)
        out.append(first.strftime("%Y-%m"))
    return out


def pocket_spending(conn: sqlite3.Connection, month: str) -> dict[str, float]:
    """USD spent per spending pocket in a month (from the Accountant's ledger)."""
    first, last = month_range(month)
    rates = fx(conn)
    out: dict[str, float] = {}
    for r in conn.execute(
        """SELECT p.name, e.amount, e.currency FROM ledger_entries e JOIN pockets p ON p.id = e.pocket_id
           WHERE e.direction = 'expense' AND p.kind = 'spending' AND e.date BETWEEN ? AND ?""",
        (first.isoformat(), last.isoformat()),
    ):
        out[r["name"]] = out.get(r["name"], 0.0) + r["amount"] * rates.get(r["currency"], 1.0)
    return {k: round(v, 2) for k, v in out.items()}


def budget_status(conn: sqlite3.Connection, month: str) -> dict:
    first, last = month_range(month)
    now = today(conn)
    days_in_month = last.day
    days_elapsed = days_in_month if now > last else max(0, (now - first).days + 1) if now >= first else 0
    spent = pocket_spending(conn, month)
    usual = {}
    for prev in previous_months(month, 3):
        for name, amount in pocket_spending(conn, prev).items():
            usual.setdefault(name, []).append(amount)
    pockets = []
    for p in conn.execute("SELECT name, monthly_budget FROM pockets WHERE kind = 'spending' ORDER BY id"):
        budget = p["monthly_budget"] or 0.0
        s = spent.get(p["name"], 0.0)
        typical = sum(usual.get(p["name"], [])) / len(usual[p["name"]]) if usual.get(p["name"]) else None
        pockets.append({
            "name": p["name"],
            "budget": budget,
            "spent": s,
            "left": round(budget - s, 2),
            "pct_used": round(100 * s / budget, 1) if budget else None,
            "over": s > budget,
            "paid": p["name"] in FIXED_BILLS and s >= budget * 0.98,
            "usual": round(typical, 2) if typical is not None else None,
        })
    total_budget = sum(p["budget"] for p in pockets)
    total_spent = round(sum(p["spent"] for p in pockets), 2)
    return {
        "month": month,
        "days_in_month": days_in_month,
        "days_elapsed": days_elapsed,
        "days_to_go": days_in_month - days_elapsed,
        "total_budget": total_budget,
        "total_spent": total_spent,
        "total_left": round(total_budget - total_spent, 2),
        "pct_used": round(100 * total_spent / total_budget, 1) if total_budget else 0,
        "pct_expected": round(100 * days_elapsed / days_in_month, 1),
        "pockets": pockets,
    }


def income_source(description: str) -> str:
    d = description.upper()
    if "PAYROLL" in d:
        return "Income"
    if "INTEREST" in d or "BUNGA" in d:
        return "Interest"
    return "Other"


def cashflow(conn: sqlite3.Connection, month: str) -> dict:
    """Money in by source, and where it went (spending pockets + savings), in USD."""
    first, last = month_range(month)
    rates = fx(conn)
    inflow: dict[str, float] = {}
    for r in conn.execute(
        "SELECT description, amount, currency FROM ledger_entries WHERE direction = 'income' AND date BETWEEN ? AND ?",
        (first.isoformat(), last.isoformat()),
    ):
        src = income_source(r["description"])
        inflow[src] = inflow.get(src, 0.0) + abs(r["amount"]) * rates.get(r["currency"], 1.0)
    outflow = dict(pocket_spending(conn, month))
    for r in conn.execute(
        """SELECT p.kind, e.amount, e.currency FROM ledger_entries e JOIN pockets p ON p.id = e.pocket_id
           WHERE e.direction = 'transfer' AND p.kind IN ('saving', 'investing')
           AND e.date BETWEEN ? AND ?""",
        (first.isoformat(), last.isoformat()),
    ):
        # Each transfer is recorded once with its pocket (the other side has none), so abs() is safe.
        label = "Savings" if r["kind"] == "saving" else "Investing"
        outflow[label] = outflow.get(label, 0.0) + abs(r["amount"]) * rates.get(r["currency"], 1.0)
    total_in = round(sum(inflow.values()), 2)
    total_out = round(sum(outflow.values()), 2)
    return {
        "month": month,
        "income": [{"source": k, "amount": round(v, 2)} for k, v in sorted(inflow.items(), key=lambda x: -x[1])],
        "outflows": [{"to": k, "amount": round(v, 2), "pct": round(100 * v / total_out, 1) if total_out else 0}
                     for k, v in sorted(outflow.items(), key=lambda x: -x[1])],
        "total_in": total_in,
        "total_out": total_out,
        "spent": round(sum(pocket_spending(conn, month).values()), 2),
    }


def spend_per_day(conn: sqlite3.Connection, days: int = 7) -> float:
    end = today(conn)
    start = end - timedelta(days=days - 1)
    rates = fx(conn)
    total = 0.0
    for r in conn.execute(
        """SELECT e.amount, e.currency FROM ledger_entries e JOIN pockets p ON p.id = e.pocket_id
           WHERE e.direction = 'expense' AND p.kind = 'spending' AND p.name NOT IN ('Rent / mortgage')
           AND e.date BETWEEN ? AND ?""",
        (start.isoformat(), end.isoformat()),
    ):
        total += r["amount"] * rates.get(r["currency"], 1.0)
    return round(total / days, 2)


def total_balance(conn: sqlite3.Connection, on: date | None = None) -> float:
    """Total assets in USD on a day (cards count as money owed)."""
    on = on or today(conn)
    row = conn.execute(
        """SELECT SUM(CASE WHEN a.type = 'credit' THEN -h.balance ELSE h.balance END * f.usd_per_unit)
           FROM balance_history h JOIN accounts a ON a.id = h.account_id JOIN fx_rates f ON f.currency = a.currency
           WHERE h.date = ?""",
        (on.isoformat(),),
    ).fetchone()
    return round(row[0] or 0.0, 2)


def balance_change_this_month(conn: sqlite3.Connection) -> dict:
    now = today(conn)
    start = now.replace(day=1) - timedelta(days=1)  # end of last month
    then, current = total_balance(conn, start), total_balance(conn, now)
    return {
        "total": current,
        "change": round(current - then, 2),
        "change_pct": round(100 * (current - then) / then, 1) if then else 0,
        "accounts": conn.execute("SELECT COUNT(*) FROM accounts").fetchone()[0],
    }
