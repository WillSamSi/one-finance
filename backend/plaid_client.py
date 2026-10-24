"""Small Plaid API client (sandbox by default). Keys come from backend.config.

Never logs or returns the client secret. Access tokens stay on the backend.
"""

import time
from typing import Any

import httpx

from backend import config

# Plaid's test bank that isn't an OAuth bank, so custom sandbox users load reliably.
# We label the accounts "Chase" / "Bank of America" in our own database.
SANDBOX_INSTITUTION = "ins_109508"  # First Platypus Bank


class PlaidError(RuntimeError):
    pass


def call(path: str, body: dict[str, Any]) -> dict[str, Any]:
    if not config.plaid_enabled():
        raise PlaidError("Plaid keys are not set; the app is in sample-data mode.")
    payload = {"client_id": config.PLAID_CLIENT_ID, "secret": config.PLAID_SECRET, **body}
    r = httpx.post(config.PLAID_BASE_URL + path, json=payload, timeout=60)
    data = r.json()
    if r.status_code != 200:
        raise PlaidError(f"{path}: {data.get('error_code')}: {data.get('error_message')}")
    return data


def sandbox_item_for_custom_user(user_config: dict, days_requested: int = 365) -> str:
    """Create a sandbox Item from a custom-user config and return its access token."""
    import json

    public = call("/sandbox/public_token/create", {
        "institution_id": SANDBOX_INSTITUTION,
        "initial_products": ["transactions"],
        "options": {
            "override_username": "user_custom",
            "override_password": json.dumps(user_config),
            "transactions": {"days_requested": days_requested},
        },
    })
    return call("/item/public_token/exchange", {"public_token": public["public_token"]})["access_token"]


def get_accounts(access_token: str) -> list[dict]:
    return call("/accounts/get", {"access_token": access_token})["accounts"]


def sync_transactions(access_token: str, wait_seconds: int = 180, expected: int | None = None) -> list[dict]:
    """All transactions for an Item via /transactions/sync, waiting until Plaid says the
    historical pull is complete (and, if given, until the expected number has arrived)."""
    deadline = time.monotonic() + wait_seconds
    while True:
        added: list[dict] = []
        cursor = None
        status = None
        while True:
            body: dict[str, Any] = {"access_token": access_token, "count": 500,
                                    "options": {"include_personal_finance_category": True}}
            if cursor:
                body["cursor"] = cursor
            page = call("/transactions/sync", body)
            added += page["added"]
            cursor = page["next_cursor"]
            status = page.get("transactions_update_status")
            if not page["has_more"]:
                break
        complete = status == "HISTORICAL_UPDATE_COMPLETE" and (expected is None or len(added) >= expected)
        if complete or time.monotonic() > deadline:
            return added
        time.sleep(5)


def remove_item(access_token: str) -> None:
    call("/item/remove", {"access_token": access_token})
