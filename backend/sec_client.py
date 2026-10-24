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
        # Companies switch tags over the years, so merge every tag and keep the newest filing per year.
        merged: dict[str, dict] = {}
        for tag in tags:
            if tag in gaap:
                for v in _annual_values(gaap[tag]["units"], duration=key not in instant):
                    if v["end"] not in merged or v["filed"] > merged[v["end"]]["filed"]:
                        merged[v["end"]] = v
        if merged:
            newest = sorted(merged.values(), key=lambda x: x["end"], reverse=True)[:years]
            out[key] = [{k: v[k] for k in ("end", "value", "unit")} for v in newest]
    return {"symbol": symbol.upper(), "cik": cik, "name": name, "annual": out}


# Broad sectors from SEC industry (SIC) codes, for "how much of the portfolio is in one sector".
SECTOR_RANGES = [
    ((3570, 3579), "Technology"), ((3600, 3699), "Technology"), ((7370, 7379), "Technology"),
    ((3810, 3829), "Technology"), ((4800, 4899), "Communication"), ((2830, 2836), "Health Care"),
    ((3840, 3851), "Health Care"), ((8000, 8099), "Health Care"), ((6000, 6799), "Financials"),
    ((1300, 1399), "Energy"), ((2900, 2999), "Energy"), ((4900, 4949), "Utilities"),
    ((5200, 5999), "Consumer / Retail"), ((2000, 2111), "Consumer Staples"),
]


def broad_sector(sic: str | int | None) -> str:
    try:
        code = int(sic)
    except (TypeError, ValueError):
        return "Other"
    return next((name for (lo, hi), name in SECTOR_RANGES if lo <= code <= hi), "Other")


def company_profile(symbol: str) -> dict:
    """Industry (SEC's SIC description), fiscal year end and exchanges."""
    cik, name = ticker_to_cik()[symbol.upper()]
    sub = _get(f"https://data.sec.gov/submissions/CIK{cik}.json")
    return {"sector": broad_sector(sub.get("sic")), "industry": sub.get("sicDescription"), "sic": sub.get("sic"),
            "fiscal_year_end": sub.get("fiscalYearEnd"), "exchanges": sub.get("exchanges")}


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
