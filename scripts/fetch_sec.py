"""Save SEC EDGAR data for the stocks in the sample portfolio (for offline runs).

Writes data/sample/sec/<SYMBOL>.json with key annual numbers and recent filings.
Funds like VOO have no 10-K, so they're skipped. Run from the repo folder:
    .venv/bin/python -m scripts.fetch_sec
"""

import json
import time
from datetime import datetime, timezone
from pathlib import Path

from backend import config  # noqa: F401  (loads .env, e.g. SEC_USER_AGENT)
from backend import sec_client

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "data" / "sample" / "sec"
FUNDS = {"VOO"}


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    investments = json.loads((ROOT / "data" / "sample" / "investments.json").read_text())
    symbols = [p["symbol"]["symbol"]["symbol"] for p in investments["positions"]]
    for symbol in symbols:
        if symbol in FUNDS:
            print(f"{symbol}: fund, no 10-K (skipped)")
            continue
        facts = sec_client.company_facts(symbol)
        time.sleep(0.2)
        filings = sec_client.recent_filings(symbol)
        time.sleep(0.2)
        profile = sec_client.company_profile(symbol)
        time.sleep(0.2)
        record = {**facts, **profile, "filings": filings,
                  "fetched_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}
        (OUT_DIR / f"{symbol}.json").write_text(json.dumps(record, indent=1) + "\n")
        rev = facts["annual"].get("revenue", [{}])[0]
        print(f"{symbol}: {facts['name']} | {profile['sector']} ({profile['industry']}) | {len(facts['annual'])} metrics, "
              f"latest revenue {rev.get('value'):,} (FY ending {rev.get('end')}) | {len(filings)} filings")


if __name__ == "__main__":
    main()
