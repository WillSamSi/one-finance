"""Load the custom sandbox users into Plaid and save what Plaid returns.

Reads data/plaid_sandbox/{chase,bofa}_user.json, creates a sandbox Item for each,
pulls accounts and transactions, and writes data/sample/plaid_snapshot.json.
The app uses that snapshot when there are no Plaid keys (e.g. on the grader's machine).
Access tokens are never saved; the sandbox Items are removed at the end.

Needs PLAID_CLIENT_ID / PLAID_SECRET (sandbox). Run from the repo folder:
    .venv/bin/python -m scripts.pull_plaid
"""

import json
from datetime import datetime, timezone
from pathlib import Path

from backend import config, plaid_client

ROOT = Path(__file__).resolve().parent.parent
USERS = {
    "chase": {"institution": "Chase", "file": ROOT / "data" / "plaid_sandbox" / "chase_user.json"},
    "bofa": {"institution": "Bank of America", "file": ROOT / "data" / "plaid_sandbox" / "bofa_user.json"},
}
OUT = ROOT / "data" / "sample" / "plaid_snapshot.json"

ACCOUNT_KEYS = ("account_id", "name", "official_name", "mask", "type", "subtype", "balances")
TXN_KEYS = ("transaction_id", "account_id", "date", "authorized_date", "name", "merchant_name", "amount",
            "iso_currency_code", "pending", "personal_finance_category", "payment_channel")


def main() -> None:
    if config.PLAID_ENV != "sandbox":
        raise SystemExit("This script only runs against the Plaid sandbox (PLAID_ENV=sandbox).")
    if not config.plaid_enabled():
        raise SystemExit("No Plaid keys found. Add PLAID_CLIENT_ID and PLAID_SECRET to .env.")

    snapshot = {
        "note": "Made-up data. Plaid sandbox output for the custom users in data/plaid_sandbox/.",
        "pulled_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "users": {},
    }
    for key, user in USERS.items():
        user_config = json.loads(user["file"].read_text())
        token = plaid_client.sandbox_item_for_custom_user(user_config)
        try:
            accounts = plaid_client.get_accounts(token)
            transactions = plaid_client.sync_transactions(token)
        finally:
            plaid_client.remove_item(token)
        snapshot["users"][key] = {
            "institution": user["institution"],
            "accounts": [{k: a.get(k) for k in ACCOUNT_KEYS} for a in accounts],
            "transactions": sorted(
                ({k: t.get(k) for k in TXN_KEYS} for t in transactions),
                key=lambda t: (t["date"], t["name"] or ""),
            ),
        }
        expected = sum(len(a["transactions"]) for a in user_config["override_accounts"])
        print(f"{key}: {len(accounts)} accounts, {len(transactions)} transactions (config has {expected})")

    OUT.write_text(json.dumps(snapshot, indent=1) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
