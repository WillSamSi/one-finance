"""The More tab: profile, AI preferences, connected accounts, export and delete.

Everything is stored in the `settings` table of the working database (Reset brings the sample's
defaults back). Settings that only change the phone (Face ID lock, hide balances, notification
times) live in the app itself.
"""

import csv
import io
import shutil
import sqlite3
from datetime import date, datetime, timedelta, timezone

from backend import analytics, config, db

# key: (default, kind). Only these can be changed through PATCH /settings.
EDITABLE = {
    "profile_name": ("Demo User", str),
    "profile_email": ("demo@example.com", str),
    "lives_in": ("United States", str),
    "home_country": ("Indonesia", str),
    "display_currency": ("USD", str),
    "ai_investment_suggestions": ("1", bool),   # Investor brief + investment digest
    "max_sector_share": ("0.5", float),         # the Investor flags a sector above this share
    "auto_record": ("1", bool),                 # the free rules pre-pass records confident matches
    # Profile → Pay and budget month (defaults detected from the payroll deposits)
    "pay_schedule": ("", str),                  # monthly | twice a month | every 2 weeks | irregular
    "payday": ("", str),                        # "1" / "1,15" / next payday "2026-10-30" / ""
    "budget_month_start": ("1st", str),         # 1st | payday
    # Profile → Investing profile (optional; passed to the Investor and Advisor)
    "risk_comfort": ("", str),                  # cautious | balanced | growth
    "time_horizon": ("", str),                  # <3 | 3-10 | 10+
    "time_zone": ("America/New_York", str),     # from the phone; when digests arrive
}

PAY_SCHEDULES = ("monthly", "twice a month", "every 2 weeks", "irregular")
RISK = ("cautious", "balanced", "growth")
HORIZONS = ("<3", "3-10", "10+")
HORIZON_LABEL = {"<3": "under 3 years", "3-10": "3–10 years", "10+": "10+ years"}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def get(conn: sqlite3.Connection, key: str) -> str:
    row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else EDITABLE.get(key, ("", str))[0]


def is_on(conn: sqlite3.Connection, key: str) -> bool:
    return get(conn, key) in ("1", "true", "True")


def detect_pay(conn: sqlite3.Connection) -> tuple[str, str]:
    """How the owner is paid, from payroll deposits in the last ~3 months: (schedule, payday)."""
    rows = [date.fromisoformat(r[0]) for r in conn.execute(
        "SELECT date FROM transactions WHERE amount < 0 AND UPPER(description) LIKE '%PAYROLL%'"
        " ORDER BY date DESC LIMIT 8")]
    if len(rows) < 2:
        return ("monthly", "1") if rows else ("irregular", "")
    gaps = [(a - b).days for a, b in zip(rows, rows[1:])]
    if all(13 <= g <= 15 for g in gaps) and len({d.day for d in rows}) > 2:
        return "every 2 weeks", (rows[0] + timedelta(days=14)).isoformat()
    days = sorted({min(d.day, 28) for d in rows})
    if len(days) == 2:
        return "twice a month", f"{days[0]},{days[1]}"
    if len(days) == 1:
        return "monthly", str(days[0])
    return "irregular", ""


def pay(conn: sqlite3.Connection) -> tuple[str, str]:
    schedule, payday = get(conn, "pay_schedule"), get(conn, "payday")
    return (schedule, payday) if schedule else detect_pay(conn)


def payday_days(schedule: str, payday: str) -> list[int]:
    if schedule in ("monthly", "twice a month"):
        return sorted(int(x) for x in payday.split(",") if x.strip().isdigit())
    return []


def budget_start_day(conn: sqlite3.Connection) -> int:
    """1, or the first payday of the month when 'Budget month starts on' is payday (monthly or
    twice-a-month pay only; the other schedules keep calendar months)."""
    if get(conn, "budget_month_start") != "payday":
        return 1
    days = payday_days(*pay(conn))
    return days[0] if days else 1


def last_expected_payday(conn: sqlite3.Connection, on: date) -> date | None:
    schedule, payday = pay(conn)
    if schedule == "every 2 weeks" and payday:
        d = date.fromisoformat(payday)
        while d > on:
            d -= timedelta(days=14)
        while d + timedelta(days=14) <= on:
            d += timedelta(days=14)
        return d
    days = payday_days(schedule, payday)
    if not days:
        return None
    candidates = [on.replace(day=d) for d in days if d <= on.day]
    if candidates:
        return max(candidates)
    prev = on.replace(day=1) - timedelta(days=1)
    return prev.replace(day=min(max(days), prev.day))


def salary_status(conn: sqlite3.Connection) -> dict:
    """Is the last expected salary late? (2 days of grace; income in Salary or a payroll deposit counts.)"""
    on = analytics.today(conn)
    expected = last_expected_payday(conn, on)
    if not expected or (on - expected).days < 2:
        return {"missing": False, "expected": expected.isoformat() if expected else None}
    lo = (expected - timedelta(days=3)).isoformat()
    got = conn.execute(
        """SELECT 1 FROM ledger_entries e LEFT JOIN pockets p ON p.id = e.pocket_id
           WHERE e.direction = 'income' AND e.date BETWEEN ? AND ? AND (p.name = 'Salary' OR UPPER(e.description) LIKE '%PAYROLL%')
           UNION SELECT 1 FROM transactions WHERE amount < 0 AND UPPER(description) LIKE '%PAYROLL%' AND date BETWEEN ? AND ?""",
        (lo, on.isoformat(), lo, on.isoformat())).fetchone()
    return {"missing": got is None, "expected": expected.isoformat()}


def owner_context(conn: sqlite3.Connection) -> str:
    """What the agents may know about the owner (never name or email): pay schedule, budget month,
    and the optional investing profile."""
    schedule, payday = pay(conn)
    if schedule == "monthly":
        paid = f"monthly on day {payday}"
    elif schedule == "twice a month":
        paid = "twice a month, on days " + " and ".join(payday.split(","))
    elif schedule == "every 2 weeks":
        paid = f"every 2 weeks (next payday {payday})"
    else:
        paid = "irregularly"
    start = budget_start_day(conn)
    parts = [f"paid {paid}", f"budget months start on day {start} of the month"]
    risk, horizon = get(conn, "risk_comfort"), get(conn, "time_horizon")
    if risk:
        parts.append(f"risk comfort: {risk}")
    if horizon:
        parts.append(f"investing time horizon: {HORIZON_LABEL.get(horizon, horizon)}")
    note = "" if (risk or horizon) else " No investing profile given: keep investment remarks neutral."
    return ("Owner's profile: " + "; ".join(parts) + "." + note +
            " Fit suggestions to this profile, and say they are suggestions, not financial advice.")


def all_settings(conn: sqlite3.Connection) -> dict:
    out = {}
    for key, (default, kind) in EDITABLE.items():
        value = get(conn, key)
        out[key] = (value in ("1", "true", "True")) if kind is bool else float(value) if kind is float else value
    fx = conn.execute("SELECT usd_per_unit, as_of FROM fx_rates WHERE currency = 'IDR'").fetchone()
    out["idr_per_usd"] = round(1 / fx["usd_per_unit"]) if fx else None
    out["fx_as_of"] = fx["as_of"] if fx else None
    out["fx_source"] = get(conn, "fx_source") or "Fixed rate for the sample data"
    out["data_mode"] = get(conn, "data_mode") or "sample"
    out["investments_source"] = get(conn, "investments_source") or "sample"
    out["deleted"] = get(conn, "data_deleted") == "1"
    schedule, payday = pay(conn)
    out["pay_schedule"], out["payday"] = schedule, payday
    out["pay_detected"] = not get(conn, "pay_schedule")
    out["budget_start_day"] = budget_start_day(conn)
    out["salary"] = salary_status(conn)
    return out


def update(conn: sqlite3.Connection, changes: dict) -> dict:
    unknown = [k for k in changes if k not in EDITABLE]
    if unknown:
        raise ValueError(f"{', '.join(unknown)} can't be changed here.")
    for key, value in changes.items():
        _, kind = EDITABLE[key]
        if key == "pay_schedule" and value not in PAY_SCHEDULES:
            raise ValueError("How you're paid must be monthly, twice a month, every 2 weeks or irregular.")
        if key == "budget_month_start" and value not in ("1st", "payday"):
            raise ValueError("Budget month starts on the 1st or on payday.")
        if key == "risk_comfort" and value not in RISK + ("",):
            raise ValueError("Risk comfort is cautious, balanced or growth.")
        if key == "time_horizon" and value not in HORIZONS + ("",):
            raise ValueError("Time horizon is <3, 3-10 or 10+ years.")
        if key == "payday":
            value = _check_payday(changes.get("pay_schedule") or get(conn, "pay_schedule") or pay(conn)[0], str(value))
        if key in ("risk_comfort", "time_horizon", "payday"):
            conn.execute("INSERT OR REPLACE INTO settings VALUES (?, ?)", (key, value))
            continue
        if kind is bool:
            value = "1" if value in (True, 1, "1", "true") else "0"
        elif kind is float:
            value = float(value)
            if key == "max_sector_share" and not 0.1 <= value <= 1.0:
                raise ValueError("Max share per sector must be between 10% and 100%.")
            value = str(round(value, 2))
        else:
            value = str(value).strip()[:80]
            if not value:
                raise ValueError("That can't be empty.")
        conn.execute("INSERT OR REPLACE INTO settings VALUES (?, ?)", (key, value))
    conn.commit()
    return all_settings(conn)


def _check_payday(schedule: str, value: str) -> str:
    value = value.strip()
    if schedule == "monthly":
        if not (value.isdigit() and 1 <= int(value) <= 28):
            raise ValueError("Payday is a day from 1 to 28.")
        return str(int(value))
    if schedule == "twice a month":
        days = [x.strip() for x in value.split(",")]
        if len(days) != 2 or not all(d.isdigit() and 1 <= int(d) <= 28 for d in days) or int(days[0]) >= int(days[1]):
            raise ValueError("Give two paydays from 1 to 28, like 1,15.")
        return f"{int(days[0])},{int(days[1])}"
    if schedule == "every 2 weeks":
        try:
            return date.fromisoformat(value).isoformat()
        except ValueError:
            raise ValueError("Give the next payday as a date.") from None
    return ""


# --- Connected accounts --------------------------------------------------------------------
def connections(conn: sqlite3.Connection) -> list[dict]:
    """One row per connection: the US banks (Plaid), the brokerage (SnapTrade), the Indonesian
    banks (monthly statements)."""
    live_banks = config.plaid_enabled() and get(conn, "data_mode") == "live"
    out = []
    groups = [("plaid", "Plaid"), ("snaptrade", "SnapTrade"), ("statement", "Monthly statements")]
    for source, via in groups:
        rows = conn.execute("SELECT institution, name, as_of FROM accounts WHERE source = ? ORDER BY institution",
                            (source,)).fetchall()
        if not rows:
            continue
        order = analytics.INSTITUTION_ORDER
        names = sorted(dict.fromkeys(r["institution"] for r in rows), key=lambda n: order.index(n) if n in order else 99)
        if source == "plaid":
            status = "Connected" if live_banks else "Sample"
        elif source == "snaptrade":
            status = "Connected" if get(conn, "investments_source") == "snaptrade_sandbox" else "Sample"
        else:
            status = "Statements"
        out.append({"source": source, "title": " · ".join(names), "via": f"via {via}" if source != "statement" else "Monthly PDF uploads",
                    "accounts": len(rows), "status": status, "as_of": max(r["as_of"] or "" for r in rows) or None,
                    "can_refresh": source == "snaptrade" and config.snaptrade_enabled()})
    return out


# --- What the AI sees ------------------------------------------------------------------------
WHAT_THE_AI_SEES = {
    "sent": [
        "Transaction descriptions, merchants, dates and amounts (to sort them into pockets)",
        "Pocket names, budgets and what's left",
        "Receipt photos you scan, and the text of the statements you upload",
        "Your holdings (ticker, units, value) and public SEC filings about those companies",
        "What you type to the Advisor in chat",
        "How you're paid, your payday and when your budget month starts",
        "Your investing profile, if you set one (risk comfort and time horizon)",
    ],
    "never": [
        "Passwords and bank logins (Plaid and SnapTrade handle sign-in; the app never sees them)",
        "Full account numbers (only the last 4 digits are stored)",
        "API keys and access tokens (they stay on the backend, never in the app or a prompt)",
        "Your name and email (the app doesn't ask for your date of birth, address or ID)",
        "Your Face ID data (it never leaves the phone)",
    ],
    "rules": [
        "The AI can only change pocket labels inside the app. It can't move real money or trade.",
        "Every change the AI makes is shown and can be undone.",
        "Text inside receipts and statements is treated as data, never as instructions.",
    ],
}


# --- Export and delete --------------------------------------------------------------------------
def export_csv(conn: sqlite3.Connection) -> str:
    """Every recorded entry (expenses, income, transfers) as CSV, amounts also in USD."""
    rates = analytics.fx(conn)
    buf = io.StringIO()
    buf.write(f"# One Finance export for {get(conn, 'profile_email')}, {_now()[:10]}. Amounts: positive = money out.\n")
    w = csv.writer(buf)
    w.writerow(["date", "description", "direction", "pocket", "amount", "currency", "amount_usd", "account", "status", "recorded_by"])
    for r in conn.execute(
            """SELECT e.date, e.description, e.direction, p.name AS pocket, e.amount, e.currency, a.institution, a.mask,
                      e.status, e.recorded_by
               FROM ledger_entries e LEFT JOIN pockets p ON p.id = e.pocket_id LEFT JOIN accounts a ON a.id = e.account_id
               ORDER BY e.date, e.id"""):
        account = f"{r['institution']} ••{r['mask']}" if r["institution"] else "Cash"
        w.writerow([r["date"], r["description"], r["direction"], r["pocket"] or "", f"{r['amount']:.2f}", r["currency"],
                    f"{r['amount'] * rates.get(r['currency'], 1.0):.2f}", account, r["status"], r["recorded_by"]])
    return buf.getvalue()


def delete_all() -> dict:
    """Delete all my data: the working database is replaced by an empty one (no accounts,
    transactions, pockets, receipts or AI history) and live connections are switched off.
    Reset sample data brings the sample back."""
    with db.connect() as conn:
        app_date = db.app_date(conn)
    tmp = db.WORKING_DB.with_suffix(".empty")
    tmp.unlink(missing_ok=True)
    new = sqlite3.connect(tmp)
    new.row_factory = sqlite3.Row
    db.create_schema(new)
    new.executemany("INSERT INTO settings VALUES (?, ?)", [
        ("app_date", app_date or datetime.now().date().isoformat()), ("data_mode", "empty"), ("data_deleted", "1"),
        ("investments_source", "none"), ("deleted_at", _now())])
    new.executemany("INSERT INTO fx_rates VALUES (?,?,?)", [("USD", 1.0, app_date), ("IDR", round(1 / 16_250, 10), app_date)])
    new.commit()
    new.close()
    shutil.move(tmp, db.WORKING_DB)
    for upload in (db.DATA_DIR / "uploads").glob("*") if (db.DATA_DIR / "uploads").exists() else []:
        upload.unlink(missing_ok=True)
    return {"ok": True}


def save_problem(conn: sqlite3.Connection, text: str, app_version: str | None) -> dict:
    text = (text or "").strip()
    if not 3 <= len(text) <= 2000:
        raise ValueError("Describe the problem in 3 to 2,000 characters.")
    conn.execute("CREATE TABLE IF NOT EXISTS problem_reports (id INTEGER PRIMARY KEY, text TEXT NOT NULL,"
                 " app_version TEXT, last_run TEXT, created_at TEXT NOT NULL, reply_to TEXT)")
    cols = {r["name"] for r in conn.execute("PRAGMA table_info(problem_reports)")}
    if "reply_to" not in cols:
        conn.execute("ALTER TABLE problem_reports ADD COLUMN reply_to TEXT")
    last = conn.execute("SELECT run_id FROM run_log ORDER BY id DESC LIMIT 1").fetchone()
    conn.execute("INSERT INTO problem_reports (text, app_version, last_run, created_at, reply_to) VALUES (?,?,?,?,?)",
                 (text, app_version, last["run_id"] if last else None, _now(), get(conn, "profile_email")))
    conn.commit()
    return {"ok": True}
