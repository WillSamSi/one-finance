"""Build data/sample.db from the sample files, then reset the working copy.

Inputs (all made up, see data/sample/STORY.md):
  data/sample/plaid_snapshot.json     Chase and BofA accounts + transactions (Plaid sandbox output)
  data/sample/statements/             BCA, Mandiri, Jago statements (text) + accounts.json
  data/sample/investments.json        brokerage positions (SnapTrade-shaped)
  data/sample/amazon/*.csv            Amazon order history
  data/sample/receipts/receipts.json  receipt photos to be read
  data/sample/pockets.json            budget pockets
  data/sample/sec/*.json              SEC company data (optional)

Daily balances: from July 2026 on they're worked out from the real transactions;
before that they're generated (marked in settings as synthetic_history_before).

Run from the repo folder:
    .venv/bin/python -m scripts.build_sample_db
"""

import csv
import json
import random
import sqlite3
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from backend import db

ROOT = db.ROOT
SAMPLE = ROOT / "data" / "sample"
APP_DATE = date(2026, 10, 24)
HISTORY_START = APP_DATE - timedelta(days=730)
IDR_PER_USD = 16_250.0

rng = random.Random(2026)


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def daterange(a: date, b: date):
    x = a
    while x <= b:
        yield x
        x += timedelta(days=1)


def load_plaid(conn: sqlite3.Connection) -> dict[str, list[tuple[date, float]]]:
    """Accounts + transactions. Returns per-account (date, balance effect) for history."""
    snap = json.loads((SAMPLE / "plaid_snapshot.json").read_text())
    effects: dict[str, list[tuple[date, float]]] = {}
    for user in snap["users"].values():
        for a in user["accounts"]:
            b = a["balances"]
            conn.execute(
                "INSERT INTO accounts VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                (a["account_id"], "plaid", user["institution"], a["name"], a["official_name"], a["type"],
                 a["subtype"], a["mask"], b.get("iso_currency_code") or "USD", b.get("current"), b.get("available"),
                 APP_DATE.isoformat()),
            )
            effects[a["account_id"]] = []
        types = {a["account_id"]: a["type"] for a in user["accounts"]}
        for t in user["transactions"]:
            pfc = t.get("personal_finance_category") or {}
            conn.execute(
                "INSERT INTO transactions VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (t["transaction_id"], t["account_id"], t["date"], t["authorized_date"], t["name"], t["merchant_name"],
                 t["amount"], t["iso_currency_code"] or "USD", int(bool(t["pending"])), pfc.get("primary"), "plaid"),
            )
            # Depository: money out lowers the balance. Credit card: a purchase raises what's owed.
            sign = 1 if types[t["account_id"]] == "credit" else -1
            effects[t["account_id"]].append((date.fromisoformat(t["date"]), sign * t["amount"]))
    return effects


def load_statements(conn: sqlite3.Connection) -> None:
    meta = json.loads((SAMPLE / "statements" / "accounts.json").read_text())
    for bank, m in meta.items():
        account_id = f"stmt-{bank}-{m['mask']}"
        conn.execute(
            "INSERT INTO accounts VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (account_id, "statement", m["institution"], m["name"], None, "depository", "savings", m["mask"],
             m["currency"], m["closing_balance"], m["closing_balance"], "2026-09-30"),
        )
        file_name = f"{bank}_{m['period']}.txt"
        conn.execute(
            "INSERT INTO statements (account_id, period, file_name, raw_text) VALUES (?,?,?,?)",
            (account_id, m["period"], file_name, (SAMPLE / "statements" / file_name).read_text()),
        )


def load_investments(conn: sqlite3.Connection) -> str:
    inv = json.loads((SAMPLE / "investments.json").read_text())
    acct = inv["accounts"][0]
    cash = inv["balances"][0]["cash"]
    conn.execute(
        "INSERT INTO accounts VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        (acct["id"], "snaptrade", acct["institution_name"], acct["name"], None, "investment", "brokerage",
         acct["number"][-4:], "USD", acct["balance"]["total"]["amount"], cash, inv["as_of"]),
    )
    for p in inv["positions"]:
        s = p["symbol"]["symbol"]
        conn.execute(
            "INSERT INTO holdings VALUES (?,?,?,?,?,?,?,?)",
            (acct["id"], s["symbol"], s["description"], p["units"], p["price"], p["average_purchase_price"], "USD", inv["as_of"]),
        )
    return acct["id"]


def load_amazon(conn: sqlite3.Connection) -> int:
    n = 0
    for path in sorted((SAMPLE / "amazon").glob("Retail.OrderHistory*.csv")):
        with path.open(newline="") as fh:
            for row in csv.DictReader(fh):
                ship = row["Ship Date"]
                conn.execute(
                    "INSERT INTO amazon_order_items (order_id, order_date, ship_date, product_name, asin, quantity,"
                    " unit_price, item_total, payment, order_status) VALUES (?,?,?,?,?,?,?,?,?,?)",
                    (row["Order ID"], row["Order Date"][:10], None if ship == "Not Available" else ship[:10],
                     row["Product Name"], row["ASIN"], int(row["Quantity"]), float(row["Unit Price"]),
                     float(row["Total Owed"]), row["Payment Instrument Type"], row["Shipment Status"]),
                )
                n += 1
    return n


def load_receipts(conn: sqlite3.Connection) -> int:
    rows = json.loads((SAMPLE / "receipts" / "receipts.json").read_text())
    for r in rows:
        conn.execute(
            "INSERT INTO receipts (image_path, status, created_at) VALUES (?, 'unread', ?)",
            (f"data/sample/receipts/{r['file']}", now()),
        )
    return len(rows)


def load_pockets(conn: sqlite3.Connection) -> int:
    pockets = json.loads((SAMPLE / "pockets.json").read_text())
    for p in pockets:
        conn.execute(
            "INSERT INTO pockets (name, kind, monthly_budget, goal_amount, currency, description) VALUES (?,?,?,?,?,?)",
            (p["name"], p["kind"], p.get("monthly_budget"), p.get("goal_amount"), p.get("currency", "USD"), p.get("description")),
        )
    return len(pockets)


def load_sec(conn: sqlite3.Connection) -> int:
    n = 0
    for path in sorted((SAMPLE / "sec").glob("*.json")) if (SAMPLE / "sec").exists() else []:
        rec = json.loads(path.read_text())
        conn.execute(
            "INSERT INTO company_data VALUES (?,?,?,?,?,?)",
            (rec["symbol"], rec["cik"], rec["name"], json.dumps(rec["annual"]), json.dumps(rec["filings"]), rec["fetched_at"]),
        )
        n += 1
    return n


def history_from_transactions(current: float, effects: list[tuple[date, float]], first_real: date) -> dict[date, float]:
    """End-of-day balances from first_real to APP_DATE, walking back from today's balance."""
    by_day: dict[date, float] = {}
    for day, eff in effects:
        by_day[day] = by_day.get(day, 0.0) + eff
    out: dict[date, float] = {}
    bal = current
    for day in sorted(daterange(first_real, APP_DATE), reverse=True):
        out[day] = round(bal, 2)
        bal -= by_day.get(day, 0.0)
    out[first_real - timedelta(days=1)] = round(bal, 2)
    return out


def synthetic_before(anchor_day: date, anchor_value: float, kind: str) -> dict[date, float]:
    """Generated daily values from HISTORY_START up to (not incl.) anchor_day, ending near anchor_value."""
    out: dict[date, float] = {}
    value = anchor_value
    for day in sorted(daterange(HISTORY_START, anchor_day - timedelta(days=1)), reverse=True):
        if kind == "checking":
            value = max(900.0, value + rng.gauss(0, 140))
            if day.day == 1:
                value -= 300  # a little lower further back
        elif kind == "savings":
            if day.day == 3:
                value = max(1500.0, value - 800 + rng.uniform(-40, 40))
        elif kind == "credit":
            value = min(1800.0, max(120.0, value + rng.gauss(0, 35)))
        elif kind == "investment":
            if day.day == 5:
                value -= 500  # monthly contribution, going back in time
            value = value / (1 + 0.0004 + rng.gauss(0, 0.009))
            value = max(1000.0, value)
        elif kind == "idr":
            if day.day == 1:
                value = max(1_000_000.0, value - rng.uniform(150_000, 400_000))
        out[day] = round(value, 2)
    return out


def build_history(conn: sqlite3.Connection, effects: dict, investment_id: str) -> None:
    accounts = conn.execute("SELECT id, type, subtype, source, current_balance FROM accounts").fetchall()
    first_real = date(2026, 7, 1)
    for a in accounts:
        if a["source"] == "plaid":
            real = history_from_transactions(a["current_balance"], effects[a["id"]], first_real)
            anchor = first_real - timedelta(days=1)
            kind = "credit" if a["type"] == "credit" else a["subtype"]
            series = {**synthetic_before(anchor, real[anchor], kind), **real}
        elif a["source"] == "statement":
            # Only September's statement exists: flat from Oct 1 (no newer statement yet).
            closing = a["current_balance"]
            stmt = conn.execute("SELECT raw_text FROM statements WHERE account_id = ?", (a["id"],)).fetchone()
            opening = float(next(line.split(":")[1] for line in stmt["raw_text"].splitlines() if line.startswith("SALDO AWAL")).replace(",", ""))
            series = synthetic_before(date(2026, 9, 1), opening, "idr")
            for day in daterange(date(2026, 9, 1), APP_DATE):
                series[day] = opening + (closing - opening) * min(1, (day - date(2026, 9, 1)).days / 29)
        else:  # investment
            series = synthetic_before(APP_DATE, a["current_balance"], "investment")
            series[APP_DATE] = a["current_balance"]
        conn.executemany(
            "INSERT INTO balance_history VALUES (?,?,?)",
            [(a["id"], day.isoformat(), round(v, 2)) for day, v in sorted(series.items()) if day >= HISTORY_START],
        )


def main() -> None:
    db.DATA_DIR.mkdir(parents=True, exist_ok=True)
    tmp = db.SAMPLE_DB.with_suffix(".building")
    tmp.unlink(missing_ok=True)
    conn = sqlite3.connect(tmp)
    conn.row_factory = sqlite3.Row
    db.create_schema(conn)
    conn.executemany("INSERT INTO settings VALUES (?, ?)", [
        ("app_date", APP_DATE.isoformat()),
        ("data_mode", "sample"),
        ("synthetic_history_before", "2026-07-01"),
        ("built_at", now()),
    ])
    conn.executemany("INSERT INTO fx_rates VALUES (?,?,?)", [
        ("USD", 1.0, APP_DATE.isoformat()),
        ("IDR", round(1 / IDR_PER_USD, 10), APP_DATE.isoformat()),
    ])
    effects = load_plaid(conn)
    load_statements(conn)
    investment_id = load_investments(conn)
    counts = {
        "amazon items": load_amazon(conn),
        "receipts": load_receipts(conn),
        "pockets": load_pockets(conn),
        "companies (SEC)": load_sec(conn),
    }
    build_history(conn, effects, investment_id)
    conn.commit()
    for table in ("accounts", "transactions", "statements", "holdings", "balance_history"):
        counts[table] = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
    conn.execute("VACUUM")
    conn.close()
    tmp.replace(db.SAMPLE_DB)
    db.reset_working_db()
    print(f"built {db.SAMPLE_DB.relative_to(ROOT)} and reset the working copy")
    for k, v in counts.items():
        print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
