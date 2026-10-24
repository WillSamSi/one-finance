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
