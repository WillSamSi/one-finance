"""Live investment data from SnapTrade (Personal API key, sandbox brokerage).

With SNAPTRADE_CLIENT_ID and SNAPTRADE_CONSUMER_KEY in .env, `sync` reads every account
connected to the key (SnapTrade's fake "SANDBOX" brokerage, connected read-only) and puts
it in the same tables the sample portfolio uses: accounts, holdings, balance_history,
plus investment_activities. Without the keys nothing here runs and the sample stays.

A Personal key is the user itself: no userId / userSecret (docs.snaptrade.com →
Authentication methods). The official SDK signs every request.

The sandbox never changes, so the area chart's history before the first sync is made up
(a random walk ending at the live value), then a snapshot of the total is saved per day.

Run from the repo folder:
    .venv/bin/python -m backend.snaptrade_client status    # keys work? what's connected?
    .venv/bin/python -m backend.snaptrade_client connect   # link to connect the SANDBOX brokerage
    .venv/bin/python -m backend.snaptrade_client sync      # pull it into the working database
"""

import json
import random
import sqlite3
import sys
from datetime import date, datetime, timedelta, timezone

from backend import analytics, config, db

# Cash-equivalent positions are left out (they're already in the cash balance), and
# options/futures aren't part of this app.
SKIPPED_KINDS = {"option", "future", "future_option", "futureoption", "cfd"}
FUND_KINDS = {"etf", "mutualfund", "mutual_fund", "cef"}


class SnapTradeError(RuntimeError):
    pass


def _client():
    if not config.snaptrade_enabled():
        raise SnapTradeError("No SnapTrade keys in .env (the app uses the sample portfolio).")
    from snaptrade_client import SnapTrade, SnapTradeAuth

    return SnapTrade(auth=SnapTradeAuth.personal_api_key(
        consumer_key=config.SNAPTRADE_CONSUMER_KEY, client_id=config.SNAPTRADE_CLIENT_ID))


def _call(fn, **kwargs):
    """Call the SDK and return the JSON body. Errors are reduced to the status and SnapTrade's
    message, so no request detail (URL with the client ID, signature) ends up in a log."""
    try:
        resp = fn(**kwargs)
    except Exception as exc:  # the SDK raises ApiException (and urllib3 errors)
        status = getattr(exc, "status", None)
        detail = ""
        body = getattr(exc, "body", None)
        try:
            b = body if isinstance(body, dict) else json.loads(body) if body else {}
            detail = str(b.get("detail") or b.get("message") or "")
        except (ValueError, TypeError, AttributeError):
            pass
        for secret in (config.SNAPTRADE_CLIENT_ID, config.SNAPTRADE_CONSUMER_KEY):
            if secret:  # SnapTrade's message can repeat the client ID
                detail = detail.replace(secret, "[hidden]")
        raise SnapTradeError(f"SnapTrade {fn.__name__} failed" + (f" ({status})" if status else "")
                             + (f": {detail}" if detail else f": {type(exc).__name__}")) from None
    return json.loads(resp.response.data or b"null")


def _items(body) -> list:
    """List endpoints answer either a bare list or {"results": [...]} / {"data": [...]}."""
    if isinstance(body, dict):
        return body.get("results") or body.get("data") or []
    return body or []


def _num(v) -> float | None:
    return None if v in (None, "") else float(v)


# --- Reading SnapTrade ------------------------------------------------------------------
def status() -> dict:
    st = _client()
    api = _call(st.api_status.check)
    connections = _items(_call(st.connections.list_brokerage_authorizations))
    accounts = _items(_call(st.account_information.list_all_user_accounts))
    return {
        "api_online": bool(api.get("online")) if isinstance(api, dict) else None,
        "connections": [{"brokerage": (c.get("brokerage") or {}).get("name"), "type": c.get("type"),
                         "disabled": c.get("disabled")} for c in connections],
        "accounts": [{"institution": a.get("institution_name"), "name": a.get("name"), "is_paper": a.get("is_paper"),
                      "total": ((a.get("balance") or {}).get("total") or {}).get("amount")} for a in accounts],
    }


def connect_link() -> str:
    """A Connection Portal link (valid 5 minutes) that goes straight to the SANDBOX brokerage,
    read-only. Open it, pick the "Self-directed" scenario, and press Connect."""
    body = _call(_client().authentication.login_snap_trade_user,
                 broker="SANDBOX", connection_type="read", connection_portal_version="v4")
    return body["redirectURI"]


def fetch(today: date) -> list[dict]:
    """Every connected account with its balances, positions and the last two years of activity."""
    st = _client()
    brokerages = {c["id"]: (c.get("brokerage") or {}).get("display_name") or (c.get("brokerage") or {}).get("name", "").title()
                  for c in _items(_call(st.connections.list_brokerage_authorizations))}
    out = []
    for a in _items(_call(st.account_information.list_all_user_accounts)):
        a["brokerage_name"] = brokerages.get(a.get("connection_id") or a.get("brokerage_authorization"))
        aid = a["id"]
        balances = _items(_call(st.account_information.get_user_account_balance, account_id=aid))
        positions = _items(_call(st.account_information.get_all_account_positions, account_id=aid))
        activities, offset = [], 0
        while True:
            page = _call(st.account_information.get_account_activities, account_id=aid,
                         start_date=today - timedelta(days=730), end_date=today, offset=offset, limit=1000) or {}
            rows = _items(page)
            activities += rows
            if len(rows) < 1000:
                break
            offset += 1000
        try:  # SnapTrade's estimated value history: experimental, off unless enabled in the dashboard
            history = (_call(st.account_information.get_account_balance_history, account_id=aid) or {}).get("history", [])
        except SnapTradeError:
            history = []
        out.append({"account": a, "balances": balances, "positions": positions, "activities": activities,
                    "history": history})
    return out


# --- Saving into the app's tables -------------------------------------------------------
def _made_up_history(account_id: str, first: date, before: date, end_value: float) -> dict[date, float]:
    """Daily values from `first` up to (not including) `before`, walking back from end_value
    (same idea as the sample portfolio: monthly contributions plus small daily moves)."""
    rng = random.Random(f"snaptrade-{account_id}")
    out, value, day = {}, end_value, before - timedelta(days=1)
    while day >= first:
        if day.day == 5:
            value -= end_value * 0.02
        value = max(end_value * 0.2, value / (1 + 0.0004 + rng.gauss(0, 0.009)))
        out[day] = round(value, 2)
        day -= timedelta(days=1)
    return out


def save(conn: sqlite3.Connection, data: list[dict]) -> dict:
    """Replace the investment accounts (sample or an earlier sync) with the live ones."""
    today = analytics.today(conn)
    first_history = conn.execute(
        "SELECT MIN(h.date) FROM balance_history h JOIN accounts a ON a.id = h.account_id WHERE a.type != 'investment'"
    ).fetchone()[0]
    first = date.fromisoformat(first_history) if first_history else today - timedelta(days=90)
    old = {r["id"]: r for r in conn.execute("SELECT * FROM accounts WHERE type = 'investment'")}
    kept_history = {}  # a later sync keeps the days already saved for the same account
    for aid in old:
        kept_history[aid] = {date.fromisoformat(r["date"]): r["balance"] for r in conn.execute(
            "SELECT date, balance FROM balance_history WHERE account_id = ? AND balance > 0", (aid,))}
    for table in ("holdings", "investment_activities", "balance_history"):
        conn.execute(f"DELETE FROM {table} WHERE account_id IN (SELECT id FROM accounts WHERE type = 'investment')")
    conn.execute("DELETE FROM accounts WHERE type = 'investment'")

    summary = {"accounts": 0, "holdings": 0, "activities": 0, "skipped_positions": 0}
    for item in data:
        a = item["account"]
        aid = f"snaptrade-{a['id']}"
        usd_cash = [b for b in item["balances"] if ((b.get("currency") or {}).get("code") or "USD") == "USD"]
        cash = sum(_num(b.get("cash")) or 0.0 for b in usd_cash)
        holdings: dict[str, list] = {}
        for p in item["positions"]:
            inst = p.get("instrument") or {}
            if p.get("cash_equivalent") or inst.get("kind") in SKIPPED_KINDS or (p.get("currency") or "USD") != "USD":
                summary["skipped_positions"] += 1
                continue
            sym = inst.get("symbol") or inst.get("raw_symbol")
            units, price = _num(p.get("units")) or 0.0, _num(p.get("price")) or 0.0
            if not sym or units == 0:
                continue
            h = holdings.setdefault(sym, [sym, inst.get("description"), 0.0, price, 0.0, inst.get("kind")])
            h[2] += units
            h[4] += units * (_num(p.get("cost_basis")) or price)  # cost_basis is per share
        total = round(sum(h[2] * h[3] for h in holdings.values()) + cash, 2)
        # /accounts/all answers with display_name / net_value / masked_account_number;
        # the older account shape has name / balance.total / number.
        reported = _num(((a.get("balance") or {}).get("total") or {}).get("amount")
                        or (a.get("net_value") or {}).get("amount"))
        institution = a.get("institution_name") or a.get("brokerage_name") or "SnapTrade"
        number = "".join(ch for ch in (a.get("number") or a.get("masked_account_number") or "") if ch.isalnum())
        conn.execute(
            "INSERT INTO accounts VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (aid, "snaptrade", institution, a.get("name") or a.get("display_name") or "Brokerage account",
             a.get("raw_type"), "investment", "brokerage", number[-4:], "USD",
             round(reported if reported is not None else total, 2), round(cash, 2), today.isoformat()))
        for sym, name, units, price, cost, kind in holdings.values():
            conn.execute("INSERT INTO holdings (account_id, symbol, name, quantity, price, average_cost, currency, as_of, kind)"
                         " VALUES (?,?,?,?,?,?,?,?,?)",
                         (aid, sym, name, units, price, round(cost / units, 4) if units else None, "USD", today.isoformat(),
                          "fund" if kind in FUND_KINDS else kind))
        for act in item["activities"]:
            when = (act.get("trade_date") or act.get("settlement_date") or "")[:10]
            if not when:
                continue
            conn.execute(
                "INSERT OR REPLACE INTO investment_activities VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (act.get("id") or f"{aid}-{when}-{summary['activities']}", aid, when, act.get("type") or "OTHER",
                 (act.get("symbol") or {}).get("symbol"), act.get("description"), _num(act.get("units")),
                 _num(act.get("price")), _num(act.get("amount")), _num(act.get("fee")),
                 ((act.get("currency") or {}).get("code")) or "USD"))
            summary["activities"] += 1

        # History: the days saved by earlier syncs, overwritten by SnapTrade's own estimate where it
        # has one (it returns $0 before the account existed and skips days, so zeros are dropped and
        # gaps carry the last value forward). Days before any real value are made up. Today's value
        # is always the live total (the daily snapshot).
        value_now = reported if reported is not None else total
        series = dict(kept_history.get(aid, {}))
        estimates = {date.fromisoformat(str(h["date"])[:10]): _num(h.get("total_value"))
                     for h in item["history"] if h.get("date") and (_num(h.get("total_value")) or 0) > 0}
        series.update(estimates)
        series[today] = value_now
        series = {d: v for d, v in series.items() if first <= d <= today}
        real_since = min(estimates, default=today)
        made_up_until = max(real_since, min(series))
        if made_up_until > first and not any(d < made_up_until for d in kept_history.get(aid, {})):
            series.update(_made_up_history(aid, first, made_up_until, series[made_up_until]))
        summary.setdefault("real_history_from", real_since.isoformat())
        summary["real_history_from"] = max(summary["real_history_from"], real_since.isoformat())
        filled, day, last = {}, min(series), None
        while day <= today:  # fill skipped days with the last known value
            last = series.get(day, last)
            filled[day] = last
            day += timedelta(days=1)
        series = filled
        conn.executemany("INSERT OR REPLACE INTO balance_history VALUES (?,?,?)",
                         [(aid, d.isoformat(), round(v, 2)) for d, v in sorted(series.items()) if first <= d <= today])
        summary["accounts"] += 1
        summary["holdings"] += len(holdings)

    made_up = conn.execute("SELECT value FROM settings WHERE key = 'synthetic_history_before'").fetchone()
    marker = max(filter(None, [made_up["value"] if made_up else None, summary.get("real_history_from")]), default=None)
    for key, value in (("investments_source", "snaptrade_sandbox"),
                       ("investments_synced_at", datetime.now(timezone.utc).isoformat(timespec="seconds")),
                       ("synthetic_history_before", marker)):
        if value is None:
            continue
        conn.execute("INSERT OR REPLACE INTO settings VALUES (?, ?)", (key, value))
    conn.commit()
    return summary


def _add_sec_data(conn: sqlite3.Connection) -> list[str]:
    """Best effort: SEC company data for live tickers that don't have it yet (needs SEC_USER_AGENT)."""
    import os

    if not os.environ.get("SEC_USER_AGENT", "").strip():
        return []
    from backend import sec_client

    added = []
    missing = [r[0] for r in conn.execute(
        "SELECT DISTINCT symbol FROM holdings WHERE symbol NOT IN (SELECT symbol FROM company_data)"
        " AND COALESCE(kind, 'stock') IN ('stock', 'adr')")]  # crypto and funds have no 10-K
    for symbol in missing:
        try:
            rec = {**sec_client.company_facts(symbol), **sec_client.company_profile(symbol)}
            filings = sec_client.recent_filings(symbol)
        except Exception:  # funds and unknown tickers have no 10-K
            continue
        conn.execute(  # same layout as scripts/build_sample_db.load_sec
            "INSERT OR REPLACE INTO company_data VALUES (?,?,?,?,?,?)",
            (symbol, rec.get("cik"), rec.get("name"),
             json.dumps({"sector": rec.get("sector"), "industry": rec.get("industry"),
                         "fiscal_year_end": rec.get("fiscal_year_end"), "annual": rec.get("annual", {})}),
             json.dumps(filings), datetime.now(timezone.utc).isoformat(timespec="seconds")))
        added.append(symbol)
    conn.commit()
    return added


def sync(conn: sqlite3.Connection | None = None) -> dict:
    """Pull live data into the working database. On any problem the database is left as it
    was (the sample portfolio, or the last good sync) and the reason is returned."""
    if not config.snaptrade_enabled():
        return {"ok": False, "source": "sample", "message": "No SnapTrade keys; using the sample portfolio."}
    own = conn is None
    conn = conn or db.connect()
    try:
        data = fetch(analytics.today(conn))
        if not data:
            return {"ok": False, "source": _source(conn),
                    "message": "No brokerage connected to the SnapTrade key yet. Run: "
                               ".venv/bin/python -m backend.snaptrade_client connect"}
        summary = save(conn, data)
        summary["sec_added"] = _add_sec_data(conn)
        return {"ok": True, "source": "snaptrade_sandbox", **summary}
    except SnapTradeError as exc:
        conn.rollback()
        return {"ok": False, "source": _source(conn), "message": str(exc)}
    except Exception as exc:  # an answer we didn't expect: keep what was there
        conn.rollback()
        return {"ok": False, "source": _source(conn), "message": f"SnapTrade sync failed: {type(exc).__name__}"}
    finally:
        if own:
            conn.close()


def _source(conn: sqlite3.Connection) -> str:
    row = conn.execute("SELECT value FROM settings WHERE key = 'investments_source'").fetchone()
    return row["value"] if row else "sample"


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    try:
        if cmd == "status":
            print(json.dumps(status(), indent=2))
        elif cmd == "connect":
            print("Open this link within 5 minutes, pick the Self-directed scenario, then press Connect:\n")
            print(connect_link())
        elif cmd == "sync":
            print(json.dumps(sync(), indent=2))
        else:
            print(__doc__)
    except SnapTradeError as exc:
        sys.exit(str(exc))
