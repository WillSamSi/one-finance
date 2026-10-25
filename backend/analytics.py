"""Plain-Python money math (no AI): pockets, budgets, cash flow, the cash check, balances.

Used by the agents' tools and by the app, so both always show the same numbers.
All amounts are converted to USD with the fx_rates table.

Pockets are guidance only: labels on the money, not tied to any account.
  Spending pocket, per month: left = budget + rollover + moves in − moves out − spent.
      Unspent money rolls over to the next month (overspending doesn't carry).
  Saving/investing pocket: total = starting amount + the monthly amount set aside on the 1st
      of every month so far + moves in − moves out − spending from it − transfers out
      (for Investment: money sent to the brokerage).
  Unassigned = all my money − what the pockets hold. All my money = cash in every bank
      account − what's owed on credit cards (the brokerage is tracked on its own).
"""

import calendar
import sqlite3
from datetime import date, timedelta

from backend import db

FIXED_BILLS = {"Home Rent"}              # shown as "Paid" once fully spent
LUMPY_POCKETS = {"Home Rent", "Utilities"}  # monthly bills: left out of "per day" spending


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


def data_months(conn: sqlite3.Connection) -> list[str]:
    """Every month with bank data, oldest first."""
    return [r[0] for r in conn.execute("SELECT DISTINCT substr(date, 1, 7) FROM transactions ORDER BY 1")]


def budget_start(conn: sqlite3.Connection) -> str:
    """The month budgeting started (rollover and monthly set-asides count from here)."""
    row = conn.execute("SELECT value FROM settings WHERE key = 'budget_start'").fetchone()
    return row["value"] if row else (data_months(conn) or [today(conn).strftime("%Y-%m")])[0]


def months_through(conn: sqlite3.Connection, month: str) -> list[str]:
    """Budget months from the budget start up to `month`."""
    start = budget_start(conn)
    months, m = [], start
    while m <= month:
        months.append(m)
        first, _ = month_range(m)
        m = (first + timedelta(days=32)).replace(day=1).strftime("%Y-%m")
    return months or [month]


# --- Pockets ---------------------------------------------------------------------------
def _pocket_spent(conn: sqlite3.Connection, month: str) -> dict[int, float]:
    """USD recorded as expenses per pocket in a month."""
    first, last = month_range(month)
    rates = fx(conn)
    out: dict[int, float] = {}
    for r in conn.execute(
        "SELECT pocket_id, amount, currency FROM ledger_entries WHERE direction = 'expense' AND pocket_id IS NOT NULL"
        " AND date BETWEEN ? AND ?", (first.isoformat(), last.isoformat())):
        out[r["pocket_id"]] = out.get(r["pocket_id"], 0.0) + r["amount"] * rates.get(r["currency"], 1.0)
    return out


def _pocket_moves(conn: sqlite3.Connection, first: str, last: str) -> dict[int, float]:
    """Net in-app moves per pocket in a date range (in − out), ignoring undone moves."""
    out: dict[int, float] = {}
    for r in conn.execute(
        "SELECT from_pocket_id, to_pocket_id, amount FROM pocket_moves WHERE undone = 0 AND date BETWEEN ? AND ?",
        (first, last)):
        if r["to_pocket_id"]:
            out[r["to_pocket_id"]] = out.get(r["to_pocket_id"], 0.0) + r["amount"]
        if r["from_pocket_id"]:
            out[r["from_pocket_id"]] = out.get(r["from_pocket_id"], 0.0) - r["amount"]
    return out


def pocket_spending(conn: sqlite3.Connection, month: str) -> dict[str, float]:
    """USD spent per spending pocket in a month."""
    names = {r["id"]: r["name"] for r in conn.execute("SELECT id, name FROM pockets WHERE kind = 'spending'")}
    return {names[pid]: round(v, 2) for pid, v in _pocket_spent(conn, month).items() if pid in names}


def spending_pockets(conn: sqlite3.Connection, month: str) -> list[dict]:
    """Each active spending pocket for a month: budget, rollover, moves, spent, left."""
    pockets = conn.execute(
        "SELECT id, name, monthly_budget, start_month FROM pockets WHERE kind = 'spending' AND active = 1 ORDER BY sort"
    ).fetchall()
    carry = {p["id"]: 0.0 for p in pockets}
    result: dict[int, dict] = {p["id"]: {"budget": 0.0, "rollover": 0.0, "moved": 0.0,
                                         "spent": 0.0, "left": 0.0} for p in pockets}
    for m in months_through(conn, month):
        first, last = (d.isoformat() for d in month_range(m))
        spent = _pocket_spent(conn, m)
        moves = _pocket_moves(conn, first, last)
        for p in pockets:
            if p["start_month"] and m < p["start_month"]:
                continue  # added later: no budget (or rollover) for the months before it existed
            budget = p["monthly_budget"] or 0.0
            s = spent.get(p["id"], 0.0)
            moved = moves.get(p["id"], 0.0)
            left = budget + carry[p["id"]] + moved - s
            result[p["id"]] = {"budget": budget, "rollover": round(carry[p["id"]], 2), "moved": round(moved, 2),
                               "spent": round(s, 2), "left": round(left, 2)}
            carry[p["id"]] = max(0.0, left)  # unspent money rolls over; overspending doesn't
    usual: dict[int, list[float]] = {}
    for prev in previous_months(month, 3):
        if prev in data_months(conn):
            for pid, v in _pocket_spent(conn, prev).items():
                usual.setdefault(pid, []).append(v)
    out = []
    for p in pockets:
        r = result[p["id"]]
        available = r["budget"] + r["rollover"] + r["moved"]
        u = usual.get(p["id"])
        out.append({
            "name": p["name"], **r,
            "available": round(available, 2),
            "pct_used": round(100 * r["spent"] / available, 1) if available > 0 else None,
            "over": r["left"] < 0,
            "paid": p["name"] in FIXED_BILLS and r["spent"] >= r["budget"] * 0.98,
            "usual": round(sum(u) / len(u), 2) if u else None,
        })
    return out


def budget_status(conn: sqlite3.Connection, month: str) -> dict:
    first, last = month_range(month)
    now = today(conn)
    days_in_month = last.day
    days_elapsed = days_in_month if now > last else max(0, (now - first).days + 1) if now >= first else 0
    pockets = spending_pockets(conn, month)
    total_available = round(sum(p["available"] for p in pockets), 2)
    total_spent = round(sum(p["spent"] for p in pockets), 2)
    return {
        "month": month,
        "days_in_month": days_in_month,
        "days_elapsed": days_elapsed,
        "days_to_go": days_in_month - days_elapsed,
        "total_budget": total_available,
        "total_spent": total_spent,
        "total_left": round(total_available - total_spent, 2),
        "pct_used": round(100 * total_spent / total_available, 1) if total_available else 0,
        "pct_expected": round(100 * days_elapsed / days_in_month, 1),
        "pockets": pockets,
    }


def savings_pockets(conn: sqlite3.Connection, month: str | None = None) -> list[dict]:
    """Each active saving/investing pocket: total now, this month's amount set aside, goal."""
    month = month or today(conn).strftime("%Y-%m")
    months = months_through(conn, month)
    first_day, last_day = month_range(months[0])[0].isoformat(), month_range(month)[1].isoformat()
    moves = _pocket_moves(conn, first_day, last_day)
    m_first, m_last = (d.isoformat() for d in month_range(month))
    month_moves = _pocket_moves(conn, m_first, m_last)
    rates = fx(conn)
    out = []
    for p in conn.execute(
            "SELECT * FROM pockets WHERE kind IN ('saving', 'investing') AND active = 1 ORDER BY sort"):
        counted = [m for m in months if not p["start_month"] or m >= p["start_month"]]
        set_aside = (p["monthly_budget"] or 0.0) * len(counted)
        used = 0.0
        for r in conn.execute(
                "SELECT amount, currency, direction FROM ledger_entries WHERE pocket_id = ? AND date BETWEEN ? AND ?",
                (p["id"], first_day, last_day)):
            if r["direction"] == "expense" or (r["direction"] == "transfer" and r["amount"] > 0):
                used += abs(r["amount"]) * rates.get(r["currency"], 1.0)
        total = (p["starting_amount"] or 0.0) + set_aside + moves.get(p["id"], 0.0) - used
        this_month = (p["monthly_budget"] or 0.0) + month_moves.get(p["id"], 0.0)
        out.append({
            "name": p["name"], "kind": p["kind"], "custom": bool(p["custom"]),
            "total": round(total, 2), "monthly_amount": p["monthly_budget"],
            "this_month": round(this_month, 2),
            "goal": p["goal_amount"], "goal_date": p["goal_date"],
            "pct_of_goal": round(100 * total / p["goal_amount"], 1) if p["goal_amount"] else None,
        })
    return out


# --- Accounts, cash check, debts -------------------------------------------------------
def all_money(conn: sqlite3.Connection) -> dict:
    """Cash in every bank account minus what's owed on cards (the brokerage is separate)."""
    rates = fx(conn)
    cash_us = cash_id = owed = 0.0
    for a in conn.execute("SELECT type, currency, current_balance FROM accounts WHERE type IN ('depository', 'credit')"):
        usd = (a["current_balance"] or 0.0) * rates.get(a["currency"], 1.0)
        if a["type"] == "credit":
            owed += usd
        elif a["currency"] == "USD":
            cash_us += usd
        else:
            cash_id += usd
    return {"cash_us": round(cash_us, 2), "cash_indonesia": round(cash_id, 2), "owed_on_cards": round(owed, 2),
            "all_money": round(cash_us + cash_id - owed, 2)}


def cash_check(conn: sqlite3.Connection, month: str | None = None) -> dict:
    """Pockets + Unassigned = all my money. Unassigned below zero means the pockets promise
    more money than exists, which is flagged."""
    month = month or today(conn).strftime("%Y-%m")
    money = all_money(conn)
    spending_left = round(sum(max(0.0, p["left"]) for p in spending_pockets(conn, month)), 2)
    saved = round(sum(p["total"] for p in savings_pockets(conn, month)), 2)
    unassigned = round(money["all_money"] - spending_left - saved, 2)
    return {**money, "spending_left": spending_left, "savings_and_investing": saved, "unassigned": unassigned,
            "pockets_plus_unassigned": round(spending_left + saved + unassigned, 2),
            "balanced": unassigned >= -0.01}


def debts(conn: sqlite3.Connection) -> list[dict]:
    """Each credit card: owed, limit used, and the next autopay (same day as the last one)."""
    out = []
    for a in conn.execute("SELECT * FROM accounts WHERE type = 'credit' ORDER BY institution"):
        last_pay = conn.execute(
            "SELECT date, amount FROM transactions WHERE account_id = ? AND amount < 0 ORDER BY date DESC LIMIT 1",
            (a["id"],)).fetchone()
        limit = (a["current_balance"] or 0) + (a["available_balance"] or 0) if a["available_balance"] is not None else None
        next_date = None
        if last_pay:
            d = date.fromisoformat(last_pay["date"])
            y, m = (d.year + (d.month == 12), d.month % 12 + 1)
            next_date = date(y, m, min(d.day, calendar.monthrange(y, m)[1])).isoformat()
            if next_date and date.fromisoformat(next_date) < today(conn):
                next_date = None
        out.append({
            "id": a["id"], "institution": a["institution"], "name": a["name"], "official_name": a["official_name"],
            "mask": a["mask"], "owed": a["current_balance"], "limit": round(limit, 2) if limit else None,
            "pct_of_limit": round(100 * a["current_balance"] / limit, 1) if limit else None,
            "last_payment": {"date": last_pay["date"], "amount": -last_pay["amount"]} if last_pay else None,
            "next_autopay": next_date,
        })
    return sorted(out, key=lambda d: INSTITUTION_ORDER.index(d["institution"]) if d["institution"] in INSTITUTION_ORDER else 99)


INSTITUTION_ORDER = ["Chase", "Bank of America", "BCA", "Mandiri", "Jago"]  # US banks, then Indonesian


def institutions(conn: sqlite3.Connection) -> list[dict]:
    """What I own, by institution: US banks, then Indonesian banks, then investments."""
    rates = fx(conn)
    groups: dict[str, dict] = {}
    for a in conn.execute("SELECT * FROM accounts WHERE type IN ('depository', 'investment')"):
        g = groups.setdefault(a["institution"], {"institution": a["institution"], "kind": a["type"],
                                                 "country": "ID" if a["currency"] == "IDR" else "US",
                                                 "accounts": [], "total_usd": 0.0, "total_local": 0.0,
                                                 "currency": a["currency"]})
        g["accounts"].append({"name": a["name"], "subtype": a["subtype"], "mask": a["mask"]})
        g["total_usd"] = round(g["total_usd"] + (a["current_balance"] or 0) * rates.get(a["currency"], 1.0), 2)
        g["total_local"] = round(g["total_local"] + (a["current_balance"] or 0), 2)

    def order(g: dict) -> tuple:
        if g["kind"] == "investment":
            return (2, g["institution"])
        return (0 if g["country"] == "US" else 1,
                INSTITUTION_ORDER.index(g["institution"]) if g["institution"] in INSTITUTION_ORDER else 99)
    return sorted(groups.values(), key=order)


# --- Cash flow and pace ----------------------------------------------------------------
def income_source(description: str) -> str:
    d = description.upper()
    if "PAYROLL" in d:
        return "Income"
    if "INTEREST" in d or "BUNGA" in d:
        return "Interest"
    return "Other"


def cashflow(conn: sqlite3.Connection, month: str) -> dict:
    """Money in by source, and where it went: spending pockets, the savings account, the brokerage."""
    first, last = month_range(month)
    rates = fx(conn)
    inflow: dict[str, float] = {}
    for r in conn.execute(
        "SELECT description, amount, currency FROM ledger_entries WHERE direction = 'income' AND date BETWEEN ? AND ?",
        (first.isoformat(), last.isoformat()),
    ):
        src = income_source(r["description"])
        inflow[src] = inflow.get(src, 0.0) + abs(r["amount"]) * rates.get(r["currency"], 1.0)
    outflow = {k: v for k, v in pocket_spending(conn, month).items() if v > 0}
    for r in conn.execute(
        "SELECT note, amount, currency, pocket_id FROM ledger_entries WHERE direction = 'transfer' AND amount > 0"
        " AND date BETWEEN ? AND ?", (first.isoformat(), last.isoformat())):
        label = {"to_savings": "Savings", "to_brokerage": "Investing"}.get(r["note"] or "")
        if label:
            outflow[label] = outflow.get(label, 0.0) + r["amount"] * rates.get(r["currency"], 1.0)
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
        """SELECT p.name, e.amount, e.currency FROM ledger_entries e JOIN pockets p ON p.id = e.pocket_id
           WHERE e.direction = 'expense' AND p.kind = 'spending' AND e.date BETWEEN ? AND ?""",
        (start.isoformat(), end.isoformat()),
    ):
        if r["name"] not in LUMPY_POCKETS:
            total += r["amount"] * rates.get(r["currency"], 1.0)
    return round(total / days, 2)


# --- What I own over time ---------------------------------------------------------------
ASSETS_SQL = """SELECT SUM(h.balance * f.usd_per_unit) FROM balance_history h
                JOIN accounts a ON a.id = h.account_id JOIN fx_rates f ON f.currency = a.currency
                WHERE a.type != 'credit' AND h.date = ?"""


def total_balance(conn: sqlite3.Connection, on: date | None = None) -> float:
    """Everything I own in USD on a day: cash and investments (debts are shown separately)."""
    on = on or today(conn)
    row = conn.execute(ASSETS_SQL, (on.isoformat(),)).fetchone()
    return round(row[0] or 0.0, 2)


def balance_change_this_month(conn: sqlite3.Connection) -> dict:
    now = today(conn)
    start = now.replace(day=1) - timedelta(days=1)  # end of last month
    then, current = total_balance(conn, start), total_balance(conn, now)
    return {
        "total": current,
        "change": round(current - then, 2),
        "change_pct": round(100 * (current - then) / then, 1) if then else 0,
        "accounts": conn.execute("SELECT COUNT(*) FROM accounts WHERE type != 'credit'").fetchone()[0],
        "institutions": conn.execute("SELECT COUNT(DISTINCT institution) FROM accounts WHERE type != 'credit'").fetchone()[0],
    }
