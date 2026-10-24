"""One Finance API (FastAPI). The iOS app talks only to this.

Start from the repo folder:
    .venv/bin/uvicorn backend.main:app --reload --port 8000
API docs: http://localhost:8000/docs
"""

from fastapi import FastAPI

from backend import config, db

app = FastAPI(title="One Finance API")


@app.get("/health")
def health() -> dict:
    with db.connect() as conn:
        mode = conn.execute("SELECT value FROM settings WHERE key = 'data_mode'").fetchone()
        return {
            "ok": True,
            "app_date": db.app_date(conn),
            "data_mode": mode["value"] if mode else "unknown",
            "plaid_keys": config.plaid_enabled(),
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
