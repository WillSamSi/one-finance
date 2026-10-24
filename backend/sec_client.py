"""SEC EDGAR client: key numbers from 10-K/10-Q filings and the recent filing list.

Free and keyless. The SEC asks every request to identify the caller in the User-Agent
(set SEC_USER_AGENT in .env to e.g. "Your Name your@email.com"). Max ~10 requests/second.
"""

import os
from datetime import date
from functools import lru_cache

import httpx

USER_AGENT = os.environ.get("SEC_USER_AGENT") or "OneFinance student-project (github.com/one-finance)"
HEADERS = {"User-Agent": USER_AGENT, "Accept-Encoding": "gzip, deflate"}

# The numbers the Investor looks at. Several tags, because companies use different ones.
CONCEPTS = {
    "revenue": ["RevenueFromContractWithCustomerExcludingAssessedTax", "Revenues", "SalesRevenueNet"],
    "net_income": ["NetIncomeLoss"],
    "operating_income": ["OperatingIncomeLoss"],
    "eps_diluted": ["EarningsPerShareDiluted"],
    "operating_cash_flow": ["NetCashProvidedByUsedInOperatingActivities"],
    "cash": ["CashAndCashEquivalentsAtCarryingValue"],
    "total_assets": ["Assets"],
    "total_liabilities": ["Liabilities"],
    "shareholders_equity": ["StockholdersEquity"],
}
FILING_FORMS = {"10-K", "10-Q", "8-K"}


def _get(url: str) -> dict:
    r = httpx.get(url, headers=HEADERS, timeout=60, follow_redirects=True)
    r.raise_for_status()
    return r.json()


@lru_cache
def ticker_to_cik() -> dict[str, tuple[str, str]]:
    data = _get("https://www.sec.gov/files/company_tickers.json")
    return {row["ticker"].upper(): (f"{row['cik_str']:010d}", row["title"]) for row in data.values()}


def _annual_values(units: dict, duration: bool) -> list[dict]:
    """10-K full-year values, one per fiscal year end, newest first."""
    best: dict[str, dict] = {}
    for unit, facts in units.items():
        for f in facts:
            if f.get("form") != "10-K" or f.get("fp") != "FY":
                continue
            if duration:
                if not f.get("start"):
                    continue
                if (date.fromisoformat(f["end"]) - date.fromisoformat(f["start"])).days < 340:
                    continue
            prev = best.get(f["end"])
            if prev is None or f["filed"] > prev["filed"]:
                best[f["end"]] = {"end": f["end"], "value": f["val"], "unit": unit, "filed": f["filed"]}
    return sorted(best.values(), key=lambda x: x["end"], reverse=True)


def company_facts(symbol: str, years: int = 4) -> dict:
    """Key annual numbers for the last few fiscal years."""
    cik, name = ticker_to_cik()[symbol.upper()]
    data = _get(f"https://data.sec.gov/api/xbrl/companyfacts/CIK{cik}.json")
    gaap = data.get("facts", {}).get("us-gaap", {})
    out: dict[str, list[dict]] = {}
    instant = {"cash", "total_assets", "total_liabilities", "shareholders_equity"}
    for key, tags in CONCEPTS.items():
        for tag in tags:
            if tag in gaap:
                values = _annual_values(gaap[tag]["units"], duration=key not in instant)
                if values:
                    out[key] = [{k: v[k] for k in ("end", "value", "unit")} for v in values[:years]]
                    break
    return {"symbol": symbol.upper(), "cik": cik, "name": name, "annual": out}


def recent_filings(symbol: str, limit: int = 8) -> list[dict]:
    cik, _ = ticker_to_cik()[symbol.upper()]
    recent = _get(f"https://data.sec.gov/submissions/CIK{cik}.json")["filings"]["recent"]
    rows = []
    for i, form in enumerate(recent["form"]):
        if form not in FILING_FORMS:
            continue
        accession = recent["accessionNumber"][i]
        doc = recent["primaryDocument"][i]
        rows.append({
            "form": form,
            "filed": recent["filingDate"][i],
            "period": recent["reportDate"][i],
            "description": recent.get("primaryDocDescription", [""] * len(recent["form"]))[i],
            "url": f"https://www.sec.gov/Archives/edgar/data/{int(cik)}/{accession.replace('-', '')}/{doc}",
        })
        if len(rows) >= limit:
            break
    return rows
