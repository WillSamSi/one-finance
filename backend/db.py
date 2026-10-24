"""The One Finance database (SQLite).

Two files, like Homework 5's original + working copy:
  data/sample.db              built from the sample data, committed, never modified by the app
  data/one_finance_working.db what the app and agents read and write (gitignored)
`reset_working_db()` copies the sample over the working copy.

Money convention (same as Plaid): a positive `amount` is money leaving the account
(a purchase, a bill); a negative `amount` is money coming in (pay, a refund).
"""

import os
import shutil
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
SAMPLE_DB = DATA_DIR / "sample.db"
WORKING_DB = Path(os.environ.get("ONE_FINANCE_DB") or DATA_DIR / "one_finance_working.db").resolve()
if WORKING_DB == SAMPLE_DB.resolve():
    raise RuntimeError("The working DB must not be data/sample.db.")

SCHEMA = """
-- Settings, e.g. app_date: the app's "today" (fixed for the sample data so it stays consistent).
CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Every account: Plaid banks and cards, Indonesian banks (from statements), brokerages.
CREATE TABLE IF NOT EXISTS accounts (
    id                TEXT PRIMARY KEY,
    source            TEXT NOT NULL,      -- 'plaid', 'statement' or 'snaptrade'
    institution       TEXT NOT NULL,      -- e.g. 'Chase', 'BCA'
    name              TEXT NOT NULL,
    official_name     TEXT,
    type              TEXT NOT NULL,      -- 'depository', 'credit' or 'investment'
    subtype           TEXT,
    mask              TEXT,               -- last digits
    currency          TEXT NOT NULL,
    current_balance   REAL,
    available_balance REAL,
    as_of             TEXT
);

-- Bank and card transactions (Plaid), plus statement lines once the Accountant reads them.
CREATE TABLE IF NOT EXISTS transactions (
    id              TEXT PRIMARY KEY,
    account_id      TEXT NOT NULL REFERENCES accounts(id),
    date            TEXT NOT NULL,        -- posted date (or transaction date if pending)
    authorized_date TEXT,                 -- when the purchase happened
    description     TEXT NOT NULL,        -- as it appears on the statement
    merchant_name   TEXT,
    amount          REAL NOT NULL,        -- positive = money out, negative = money in
    currency        TEXT NOT NULL,
    pending         INTEGER NOT NULL DEFAULT 0,
    category        TEXT,                 -- the provider's category, if any
    source          TEXT NOT NULL         -- 'plaid' or 'statement'
);
CREATE INDEX IF NOT EXISTS idx_txn_account_date ON transactions(account_id, date);

-- Daily balance per account, for the total-assets area chart.
CREATE TABLE IF NOT EXISTS balance_history (
    account_id TEXT NOT NULL REFERENCES accounts(id),
    date       TEXT NOT NULL,
    balance    REAL NOT NULL,
    PRIMARY KEY (account_id, date)
);

-- Raw monthly statements for banks with no API (BCA, Mandiri, Jago).
CREATE TABLE IF NOT EXISTS statements (
    id         INTEGER PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id),
    period     TEXT NOT NULL,             -- 'YYYY-MM'
    file_name  TEXT NOT NULL,
    raw_text   TEXT NOT NULL,
    status     TEXT NOT NULL DEFAULT 'unread'   -- 'unread' or 'recorded'
);

-- Receipt photos and what the Accountant read from them.
CREATE TABLE IF NOT EXISTS receipts (
    id         INTEGER PRIMARY KEY,
    image_path TEXT NOT NULL,             -- relative to the repo
    store      TEXT,
    date       TEXT,
    subtotal   REAL,
    tax        REAL,
    total      REAL,
    card_last4 TEXT,
    status     TEXT NOT NULL DEFAULT 'unread',  -- 'unread', 'read', 'matched' or 'flagged'
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS receipt_items (
    id         INTEGER PRIMARY KEY,
    receipt_id INTEGER NOT NULL REFERENCES receipts(id),
    name       TEXT NOT NULL,
    quantity   REAL NOT NULL DEFAULT 1,
    price      REAL NOT NULL
);

-- Amazon order history (one row per item, as in Amazon's CSV export).
CREATE TABLE IF NOT EXISTS amazon_order_items (
    id            INTEGER PRIMARY KEY,
    order_id      TEXT NOT NULL,
    order_date    TEXT NOT NULL,
    ship_date     TEXT,
    product_name  TEXT NOT NULL,
    asin          TEXT,
    quantity      INTEGER NOT NULL,
    unit_price    REAL NOT NULL,
    item_total    REAL NOT NULL,          -- what was charged for this item, incl. tax
    payment       TEXT,                   -- e.g. 'Visa - 7313'
    order_status  TEXT
);
CREATE INDEX IF NOT EXISTS idx_amazon_order ON amazon_order_items(order_id);

-- Budget pockets. The Accountant decides which accounts back each pocket.
CREATE TABLE IF NOT EXISTS pockets (
    id             INTEGER PRIMARY KEY,
    name           TEXT NOT NULL UNIQUE,
    kind           TEXT NOT NULL,         -- 'spending', 'saving' or 'investing'
    monthly_budget REAL,                  -- spending and investing pockets
    goal_amount    REAL,                  -- saving pockets
    currency       TEXT NOT NULL DEFAULT 'USD',
    description    TEXT
);
CREATE TABLE IF NOT EXISTS pocket_accounts (
    pocket_id  INTEGER NOT NULL REFERENCES pockets(id),
    account_id TEXT NOT NULL REFERENCES accounts(id),
    confidence REAL,                      -- 0..1 when linked by the AI
    reason     TEXT,
    linked_by  TEXT NOT NULL,             -- 'ai' or 'user'
    status     TEXT NOT NULL,             -- 'active' or 'review'
    created_at TEXT NOT NULL,
    PRIMARY KEY (pocket_id, account_id)
);

-- The Accountant's records: each expense, income or transfer, in a pocket.
CREATE TABLE IF NOT EXISTS ledger_entries (
    id              INTEGER PRIMARY KEY,
    transaction_id  TEXT REFERENCES transactions(id),
    date            TEXT NOT NULL,
    description     TEXT NOT NULL,
    amount          REAL NOT NULL,        -- positive = money out
    currency        TEXT NOT NULL,
    direction       TEXT NOT NULL,        -- 'expense', 'income' or 'transfer'
    pocket_id       INTEGER REFERENCES pockets(id),
    account_id      TEXT REFERENCES accounts(id),
    receipt_id      INTEGER REFERENCES receipts(id),
    amazon_order_id TEXT,
    status          TEXT NOT NULL,        -- 'recorded' or 'review'
    recorded_by     TEXT NOT NULL,        -- 'rules', 'accountant' or 'user'
    note            TEXT,
    created_at      TEXT NOT NULL
);

-- Things for me to confirm or fix (the Review tray).
CREATE TABLE IF NOT EXISTS review_items (
    id              INTEGER PRIMARY KEY,
    kind            TEXT NOT NULL,        -- e.g. 'amount_mismatch', 'duplicate_charge', 'no_matching_order'
    transaction_id  TEXT REFERENCES transactions(id),
    receipt_id      INTEGER REFERENCES receipts(id),
    amazon_order_id TEXT,
    pocket_id       INTEGER REFERENCES pockets(id),
    amount          REAL,
    detail          TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'open',   -- 'open', 'confirmed', 'fixed' or 'dismissed'
    created_by      TEXT NOT NULL,
    created_at      TEXT NOT NULL,
    resolved_at     TEXT
);

-- Investment positions (SnapTrade, or the saved sample).
CREATE TABLE IF NOT EXISTS holdings (
    account_id    TEXT NOT NULL REFERENCES accounts(id),
    symbol        TEXT NOT NULL,
    name          TEXT,
    quantity      REAL NOT NULL,
    price         REAL NOT NULL,
    average_cost  REAL,
    currency      TEXT NOT NULL,
    as_of         TEXT NOT NULL,
    PRIMARY KEY (account_id, symbol)
);

-- Company data from SEC EDGAR (key numbers + recent filings), saved for offline runs.
CREATE TABLE IF NOT EXISTS company_data (
    symbol       TEXT PRIMARY KEY,
    cik          TEXT,
    name         TEXT,
    facts_json   TEXT NOT NULL,
    filings_json TEXT NOT NULL,
    fetched_at   TEXT NOT NULL
);

-- Currency conversion for totals (sample mode uses fixed rates).
CREATE TABLE IF NOT EXISTS fx_rates (
    currency TEXT PRIMARY KEY,
    usd_per_unit REAL NOT NULL,
    as_of    TEXT NOT NULL
);

-- In-app notifications (weekly digests).
CREATE TABLE IF NOT EXISTS notifications (
    id         INTEGER PRIMARY KEY,
    kind       TEXT NOT NULL,             -- 'spending_digest' or 'investment_digest'
    title      TEXT NOT NULL,
    body       TEXT NOT NULL,
    created_at TEXT NOT NULL,
    read       INTEGER NOT NULL DEFAULT 0
);

-- Every agent step, with tokens: the traced run and the tokenomics evidence.
CREATE TABLE IF NOT EXISTS run_log (
    id            INTEGER PRIMARY KEY,
    run_id        TEXT NOT NULL,
    agent         TEXT NOT NULL,
    chain         TEXT,                   -- who handed work to whom, e.g. 'advisor>investor'
    step          INTEGER NOT NULL,
    step_type     TEXT NOT NULL,          -- 'prompt', 'model_response', 'tool_call', 'tool_result', 'final_output', 'limit', 'error'
    tool          TEXT,
    text          TEXT,
    data_json     TEXT,
    input_tokens  INTEGER,
    cached_tokens INTEGER,
    output_tokens INTEGER,
    created_at    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_run_log_run ON run_log(run_id, step);
"""


def connect(path: Path | None = None) -> sqlite3.Connection:
    """Open the working database (or another file), with rows as dicts-by-name."""
    db_path = Path(path or WORKING_DB)
    if not db_path.exists() and db_path == WORKING_DB and SAMPLE_DB.exists():
        reset_working_db()
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def create_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA)


def reset_working_db() -> Path:
    """Copy data/sample.db over the working copy (the sample is only read)."""
    if not SAMPLE_DB.exists():
        raise FileNotFoundError(f"{SAMPLE_DB} is missing. Build it with: .venv/bin/python -m scripts.build_sample_db")
    WORKING_DB.parent.mkdir(parents=True, exist_ok=True)
    tmp = WORKING_DB.with_suffix(".tmp")
    shutil.copyfile(SAMPLE_DB, tmp)
    os.replace(tmp, WORKING_DB)
    return WORKING_DB


def app_date(conn: sqlite3.Connection) -> str:
    row = conn.execute("SELECT value FROM settings WHERE key = 'app_date'").fetchone()
    return row["value"] if row else ""
