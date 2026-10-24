# One Finance

One Finance is a personal finance app (native iOS + Python backend) with three AI agents: an **Accountant** that records and cross-checks receipts and bank charges, an **Investor** that reads positions and company filings, and an **Advisor** that gives insights and weekly digests.

> Work in progress. Full run steps will be added as the app is built.

## Setup (once)

Requires Python 3.11+. Run these from this folder.

```bash
python3 -m venv .venv
```

```bash
.venv/bin/pip install -r requirements.txt
```

## Keys

The app reads a `.env` file from **this folder first, then the folder above it**. Copy `.env.example` to either place and fill it in:

- `PORTKEY_API_KEY` (required): the course key for `gpt-6-luna`.
- `PLAID_CLIENT_ID`, `PLAID_SECRET` (optional): leave blank to use the sample bank data.

Check that the keys are found (shows set/missing, never the values):

```bash
.venv/bin/python -m backend.config
```

## Run

1. Start the backend (from this folder):

```bash
.venv/bin/uvicorn backend.main:app --port 8000
```

2. Open `ios/OneFinance.xcodeproj` in Xcode, pick an iPhone simulator, and press **Run** (⌘R). The app talks to the backend at `http://localhost:8000`.

## See the agents work (no Xcode needed)

```bash
.venv/bin/python -m backend.run month-end 2026-09
```

The Accountant reads the receipt photos, records September, cross-checks receipts and Amazon orders against the bank charges, records the Indonesian statements, flags problems and links accounts to pockets. Other runs:

```bash
.venv/bin/python -m backend.run digest
```

```bash
.venv/bin/python -m backend.run chat "How is my dining budget this month?"
```

`digest` is the Advisor's weekly digest (it hands work to the Investor). Every step and its tokens are saved in the `run_log` table; `reset` starts over from the sample data.

## Sample data

**All data in this repo is made up.** No real accounts, people or purchases. It's one consistent story (see [`data/sample/STORY.md`](data/sample/STORY.md)), with a few problems planted in September 2026 for the AI to find.

- Without Plaid keys (as on a grader's machine), the app uses `data/sample.db`, built from the saved Plaid sandbox output. The AI agents still run for real on it.
- The app works on `data/one_finance_working.db`, a copy of the sample. Start over by deleting it, or with `.venv/bin/python -c "from backend import db; db.reset_working_db()"`.

To rebuild the sample data from scratch:

```bash
.venv/bin/python -m scripts.make_sample_data
```

```bash
.venv/bin/python -m scripts.pull_plaid
```

```bash
.venv/bin/python -m scripts.fetch_sec
```

```bash
.venv/bin/python -m scripts.build_sample_db
```

`pull_plaid` needs Plaid sandbox keys and `fetch_sec` needs `SEC_USER_AGENT`; both are optional, since their output is already saved in `data/sample/`.
