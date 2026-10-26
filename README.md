# One Finance

One Finance is a personal finance app for someone whose money lives in two countries: US bank accounts and cards, an investment account, and Indonesian bank accounts that only send monthly statements. It's a native iOS app (SwiftUI) on a Python backend, with three AI agents built with PydanticAI on `gpt-6-luna`:

- **Accountant**: records every bank and card charge in the right pocket, reads receipt photos and Indonesian bank statements, cross-checks receipts and Amazon orders against the charges, and flags what doesn't add up (a receipt that differs from its charge, a duplicate, an Amazon charge with no order).
- **Investor**: reads the brokerage positions and the companies' SEC filings, and points out concentration and changes.
- **Advisor**: writes the weekly spending and investment digests, answers questions in chat, and drafts a first budget from your bank history. It can hand work to the other two.

Pockets are labels on your money, not bank accounts: monthly budgets for spending (unspent money rolls over), and set-asides for savings and investing. The cash check makes sure pockets + Unassigned always equal all your money.

The agents can't move real money or trade. Anything they change is a pocket label, shown to you and undoable.

## For graders: how to run it

One Finance is an **iPhone app**, so seeing its screens needs a **Mac with Xcode** (free from the Mac App Store). Pick whichever fits your computer:

| You have | What to do | Time |
|---|---|---|
| **A Mac with Xcode installed** | Follow the [Quick start](#quick-start-about-10-minutes) below: start the backend, open `ios/OneFinance.xcodeproj`, choose an iPhone simulator, press Run. The full app opens on the sample data. | ~10 min |
| **A Mac with Claude Code** (desktop app or CLI) and Xcode | Open this folder in Claude Code and ask: *"Follow the README: start the backend, then build the iOS app and run it in the iPhone Simulator."* It can run the commands and open the Simulator for you. | ~10 min |
| **No Mac, or no Xcode** | Run the agents without the app: [See the agents work without Xcode](#see-the-agents-work-without-xcode) (one command each), and click through every endpoint at http://localhost:8000/docs. Then watch the **demo video** submitted on Canvas, which shows the iPhone app on a real example. | ~5 min |

Xcode is a large download (several GB). If it isn't installed already, the last row is the quickest way in.

## Quick start (about 10 minutes)

You need a Mac with **Xcode** (built and tested with Xcode 27.1; the app needs iOS 18 or newer) and **Python 3.11+**. Run the commands from this folder (`one-finance/`).

1. **Install the backend:**

   ```bash
   python3 -m venv .venv
   ```

   ```bash
   .venv/bin/pip install -r requirements.txt
   ```

2. **Add the key.** Copy `.env.example` to `.env`, either in this folder or in the folder above it, and set `PORTKEY_API_KEY` (the course's Portkey key). Everything else in `.env` is optional: leave it blank and the app uses the saved sample data. Check what was found (prints set/missing, never the values):

   ```bash
   .venv/bin/python -m backend.config
   ```

3. **Start the backend:**

   ```bash
   .venv/bin/uvicorn backend.main:app --port 8000
   ```

   Leave it running. API docs: http://localhost:8000/docs

4. **Run the app.** Open `ios/OneFinance.xcodeproj` in Xcode, choose an iPhone simulator (e.g. iPhone 17 Pro or newer) in the top bar, and press **Run** (⌘R). The app opens on Home with the sample data.

5. **Try the AI.** In the app: **More → Month-end check → Run** (the Accountant checks September; problems appear under **Wallet → Review**), **More → Weekly digest → Run**, the gradient ring button for the Advisor chat, **Invest → Asset → Ask the Investor for a brief**, and **+ → Or type it** (`lunch 12.50 Chipotle cash`). **More → Agent runs and tokens** shows every step and its tokens.

To start over at any time: **More → Reset sample data**.

## See the agents work without Xcode

With the backend's virtual environment installed (step 1) and the key set (step 2):

```bash
.venv/bin/python -m backend.run month-end 2026-09
```

The Accountant reads the receipt photos, records September (most charges are recorded first by free rules, so the AI only handles the rest), cross-checks receipts and Amazon orders, records the Indonesian statements, and flags the planted problems. Other runs:

```bash
.venv/bin/python -m backend.run digest
```

```bash
.venv/bin/python -m backend.run brief
```

```bash
.venv/bin/python -m backend.run chat "How is my food budget this month?"
```

`digest` is the Advisor's weekly digest (it can hand work to the Investor), `brief` is the Investor's portfolio brief. Each prints its result and token totals; every step is saved in the `run_log` table. `reset` starts over from the sample data:

```bash
.venv/bin/python -m backend.run reset
```

## Tests (evidence for the report)

- **Safety and cost** (`output/safety_results.md`): read-only access, arithmetic checked in code, token/step/hand-off caps, prompt injection in a receipt photo, a bank description and an SEC filing, investment-advice guardrails, and what the free rules pre-pass saves.

  ```bash
  .venv/bin/python -m scripts.safety_tests code
  ```

  `code` runs the free checks only; `injection`, `advice`, `cost` and `caplive` call the AI (a few cents each); `all` runs everything.

- **3-month scenarios** (`output/scenario_results.md`): 13 fake 3-month histories (overspending, messy reconciliation, transfers, savings goals, attacks in the data, two currencies, split bills, installments, a mortgage, …), each with an answer key written beforehand (`data/scenarios/<name>/expected.json`). Every month the real month-end check runs and the results are compared in code.

  ```bash
  .venv/bin/python -m scripts.run_scenarios s1_normal
  ```

  Without a name it runs all 13 (about 700,000 tokens).

## Sample data

**All data in this repo is made up.** No real accounts, people or purchases. It's one consistent story from July to October 2026 ([`data/sample/STORY.md`](data/sample/STORY.md)): a student in New Haven with Chase and Bank of America (in the shape the Plaid sandbox returns), a brokerage account (in the shape SnapTrade returns), and BCA, Mandiri and Jago accounts in Indonesia read from monthly statements, plus receipt photos and an Amazon order history. A few problems are planted in September for the Accountant to find: a Target receipt of $47.82 against a $52.82 charge, a gym charged twice, and an Amazon charge with no order.

- The app works on `data/one_finance_working.db`, a copy of `data/sample.db` made on first start. **Reset sample data** (or `backend.run reset`) copies it again.
- The app's "today" is fixed at Oct 24, 2026 so the story stays consistent.
- Amounts in rupiah are converted to US dollars at a stated fixed rate (Rp 16,250 = $1).

### Live sandboxes (optional)

- **Plaid** (`PLAID_CLIENT_ID`, `PLAID_SECRET`): `scripts/pull_plaid.py` pulls the sandbox banks and saves them to `data/plaid_sandbox/`, which `scripts/build_sample_db.py` turns into the sample database.
- **SnapTrade** (`SNAPTRADE_CLIENT_ID`, `SNAPTRADE_CONSUMER_KEY`, a free Personal key): connect the fake brokerage once (`.venv/bin/python -m backend.snaptrade_client connect`, open the link, pick Self-directed). The backend then reads it at start and on Reset; without the keys it uses the sample portfolio.
- **SEC EDGAR** (`SEC_USER_AGENT`, your name and email as the SEC requires): `scripts/fetch_sec.py` refreshes the saved company data in `data/sample/sec/`.

## On your own iPhone

1. Xcode → **Settings → Accounts** → add your Apple ID (free). In the project's **Signing & Capabilities**, pick your Personal Team (change the bundle identifier if Xcode says it's taken).
2. Connect the iPhone, turn on **Settings → Privacy & Security → Developer Mode**, choose the iPhone as the run destination, and press Run. The first time, trust the developer in **Settings → General → VPN & Device Management**.
3. Start the backend so the phone can reach it, on a Wi-Fi network you trust (the backend has no login):

   ```bash
   .venv/bin/uvicorn backend.main:app --host 0.0.0.0 --port 8000
   ```

4. In the app, enter the Mac's address (e.g. `http://Your-Mac.local:8000`) on the "Can't reach the backend" card, or later in **More → Help and about → Backend address**.
5. Back Tap: in the **Shortcuts** app, tap **+**, add One Finance's **Log expense** action and save it as "Log expense"; then **Settings → Accessibility → Touch → Back Tap → Double Tap → Log expense**. A double tap on the back of the phone opens the + menu ready to type.

## How it's built

```
iOS app (SwiftUI)  ──HTTP──▶  FastAPI backend  ──▶  SQLite (sample or working copy)
                                   │
                                   ├── rules.py      free pre-pass: records the obvious charges
                                   ├── agents.py     Accountant, Investor, Advisor (PydanticAI)
                                   │     └── tools.py  each agent's own tools; writes are checked in code
                                   ├── team.py       step log with tokens, caps, Advisor hand-offs
                                   ├── analytics.py  pockets, rollover, cash check, cash flow (no AI)
                                   └── Portkey → gpt-6-luna
```

| Folder | What's there |
|---|---|
| `backend/` | the API (`main.py`), agents and their prompts (`prompts/`), tools, money math, Plaid/SnapTrade/SEC clients |
| `ios/` | the Xcode project (`OneFinance/`: screens, the + flows, Back Tap shortcut, launch animation) |
| `data/` | the sample story and database, the saved sandbox output, the 13 test scenarios |
| `scripts/` | build the sample data, safety tests, scenario tests, brand assets |
| `output/` | test results used in the report |

**Keys stay on the backend.** The iOS app only talks to the backend; the Portkey, Plaid and SnapTrade keys are never in the app, a prompt or a log. `.env` is git-ignored.

## Limits

- The backend runs on your own Mac; there's no hosted server or login yet, so the iPhone app works on the same Wi-Fi only.
- Indonesian banks have no open API, so their data comes from monthly statements.
- Investment suggestions are information, not financial advice; the app can't trade.
