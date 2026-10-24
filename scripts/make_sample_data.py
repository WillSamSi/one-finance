"""Write One Finance's fake sample data from one story, so every source agrees.

Everything here is made up. It writes:
  data/plaid_sandbox/chase_user.json, bofa_user.json   Plaid custom sandbox users (the "recipe")
  data/sample/amazon/Retail.OrderHistory.1.csv          Amazon order history, same columns as Amazon's export
  data/sample/receipts/*.png                            receipt photos (September)
  data/sample/statements/*_2026-09.txt                  BCA, Mandiri and Jago statements (text, as if from PDF)
  data/sample/investments.json                          brokerage positions, shaped like SnapTrade's answer
  data/sample/pockets.json                              budget pockets
  data/sample/STORY.md                                  what's in the data, including the planted problems

Run from the repo folder:
    .venv/bin/python -m scripts.make_sample_data
"""

import csv
import json
import random
from datetime import date, timedelta
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SAMPLE = ROOT / "data" / "sample"
PLAID_DIR = ROOT / "data" / "plaid_sandbox"

APP_DATE = date(2026, 10, 24)       # the sample's "today"
START = date(2026, 7, 1)            # first day of transactions
LAST = APP_DATE - timedelta(days=1)  # last day with activity

# Account masks (last 4 digits). Receipts and Amazon show the card's last 4.
CHASE_CHECKING, CHASE_CARD = "0918", "7313"
BOFA_SAVINGS, BOFA_CARD = "5560", "2290"

rng = random.Random(409)


def d(s: str) -> date:
    return date.fromisoformat(s)


def money(x: float) -> float:
    return round(x + 1e-9, 2)


def txn(day: date, amount: float, description: str, post_days: int = 1) -> dict:
    """A Plaid custom-user transaction. Positive amount = money out."""
    posted = day + timedelta(days=post_days)
    return {
        "date_transacted": day.isoformat(),
        "date_posted": posted.isoformat(),  # a posted date after "today" makes it pending
        "amount": money(amount),
        "description": description,
        "currency": "USD",
    }


def months():
    m = START
    while m <= LAST:
        yield m
        m = date(m.year + (m.month == 12), m.month % 12 + 1, 1)


def days_in(month_start: date):
    day = month_start
    while day.month == month_start.month and day <= LAST:
        yield day
        day += timedelta(days=1)


def pick_days(month_start: date, n: int) -> list[date]:
    days = list(days_in(month_start))
    return sorted(rng.sample(days, min(n, len(days))))


# --------------------------------------------------------------------------------------
# Amazon orders (built first: the card charges come from these)
# --------------------------------------------------------------------------------------
# Each item: (product, asin, qty, item_total incl. tax). Amazon charges when a shipment
# ships, so each shipment becomes one card charge.
AMAZON_ORDERS = [
    {"id": "113-4402871-5519420", "date": "2026-07-08", "shipments": [
        {"ship": "2026-07-09", "ref": "AMAZON MKTPL*2Q4WT7", "items": [("Anker Portable Charger 10000mAh", "B0DQ8V3K1M", 1, 25.49)]}]},
    {"id": "113-9917345-2208163", "date": "2026-07-21", "shipments": [
        {"ship": "2026-07-22", "ref": "AMAZON MKTPL*5H0QX2", "items": [
            ("Atomic Habits (Paperback)", "0735211299", 1, 14.39),
            ("The Psychology of Money (Paperback)", "0857197681", 1, 12.88)]}]},
    {"id": "114-0283316-7741902", "date": "2026-08-04", "shipments": [
        {"ship": "2026-08-05", "ref": "AMAZON MKTPL*8C3NB1", "items": [("Replacement Ear Tips for Wireless Earbuds, 3 Sizes", "B0CW2N7Z4R", 1, 19.99)]}]},
    {"id": "114-6651209-3380127", "date": "2026-08-19", "shipments": [
        {"ship": "2026-08-20", "ref": "AMAZON MKTPL*1V7KE9", "items": [
            ("Amazon Basics AA Batteries, 20 Pack", "B00MNV8E0C", 1, 14.29),
            ("Command Small Picture Hanging Strips, 12 Pairs", "B073XR4X72", 1, 9.47)]}]},
    # Planted: one order, two shipments -> two charges on different days.
    {"id": "113-7720518-9014466", "date": "2026-09-10", "shipments": [
        {"ship": "2026-09-11", "ref": "AMAZON MKTPL*4K8RT2", "items": [("Logitech MX Anywhere 3S Wireless Mouse", "B0C447BYQR", 1, 41.98)]},
        {"ship": "2026-09-13", "ref": "AMAZON MKTPL*9B1ZA0", "items": [("Moleskine Classic Notebook, Large, Ruled", "8883701127", 1, 22.99)]}]},
    {"id": "112-3369040-6257731", "date": "2026-09-22", "shipments": [
        {"ship": "2026-09-23", "ref": "AMAZON.COM*2M5HX1", "items": [("Ziploc Storage Bags Variety Pack, 347 Count", "B07KX4FG8P", 1, 18.49)]}]},
    {"id": "113-5502167-8820354", "date": "2026-10-06", "shipments": [
        {"ship": "2026-10-07", "ref": "AMAZON MKTPL*6T2PD5", "items": [("Fabric Case for E-Reader, 6.8 inch, Charcoal", "B0BL8QXN2D", 1, 16.99)]}]},
    {"id": "114-8104473-1196628", "date": "2026-10-20", "shipments": [
        {"ship": "2026-10-21", "ref": "AMAZON MKTPL*3W9LJ4", "items": [("Non-Slip Yoga Mat, 6mm, Purple", "B01LP0U5X0", 1, 27.95)]}]},
    # Not shipped yet, so no charge yet (Amazon charges at shipping).
    {"id": "112-2290618-4473005", "date": "2026-10-22", "shipments": [
        {"ship": None, "ref": None, "items": [("LED Desk Lamp with USB Charging Port", "B08LYJ7Q1M", 1, 34.99)]}]},
]

# A card charge that looks like Amazon but has no order in the CSV (planted).
AMAZON_ORPHAN = ("2026-09-27", "AMAZON MKTPL*7Q2LM8", 29.99)


# --------------------------------------------------------------------------------------
# Receipts (September). Each receipt adds up on its own; one doesn't match its charge.
# --------------------------------------------------------------------------------------
RECEIPTS = [
    {
        "file": "2026-09-06_target.png", "store": "TARGET", "header": ["TARGET", "New Haven - Store T-1931", "(203) 555-0148"],
        "date": "2026-09-06", "time": "13:12", "card": CHASE_CARD,
        "items": [("UP&UP PAPER TOWELS 6PK", 12.99, True), ("TIDE PODS 42CT", 13.49, True),
                  ("RE HANGERS 10PK", 6.00, True), ("COLGATE TOOTHPASTE 2PK", 6.89, True),
                  ("GOOD&GATHER PASTA SAUCE", 2.79, False), ("GOOD&GATHER SPAGHETTI", 1.29, False),
                  ("GOOD&GATHER MINCED GARLIC", 1.87, False)],
        "tax_rate": 0.0635,
        "charge": 52.82,  # planted: the card was charged $5.00 more than the receipt total
    },
    {
        "file": "2026-09-09_trader_joes.png", "store": "TRADER JOE'S", "header": ["TRADER JOE'S #523", "560 Boston Post Rd", "Orange, CT"],
        "date": "2026-09-09", "time": "18:41", "card": CHASE_CARD,
        "items": [("BANANAS 4 @ 0.29", 1.16, False), ("MANDARIN ORANGE CHICKEN", 5.49, False),
                  ("UNEXPECTED CHEDDAR", 4.99, False), ("EVERYTHING BUT THE BAGEL", 2.99, False),
                  ("GREEK YOGURT PLAIN", 5.49, False), ("MANGO CHUNKS FROZEN", 2.99, False),
                  ("SOURDOUGH BREAD", 4.49, False), ("EGGS LARGE DOZEN", 3.99, False),
                  ("BABY SPINACH", 2.49, False), ("HUMMUS ROASTED GARLIC", 4.09, False)],
        "tax_rate": 0.0635,
        "charge": 38.17,
    },
    {
        "file": "2026-09-14_walmart.png", "store": "WALMART", "header": ["Walmart", "Supercenter #2397", "West Haven, CT"],
        "date": "2026-09-14", "time": "11:05", "card": CHASE_CARD,
        "items": [("GV 2% MILK 1GAL", 3.68, False), ("GV LARGE EGGS 18CT", 4.97, False), ("BANANAS", 1.42, False),
                  ("CHICKEN BREAST 3LB", 11.47, False), ("JASMINE RICE 5LB", 6.98, False),
                  ("GV FROZEN BROCCOLI", 2.48, False), ("EQUATE IBUPROFEN 100CT", 7.88, False),
                  ("GV PEANUT BUTTER", 2.74, False), ("QUAKER OATS 42OZ", 5.86, False),
                  ("MAINSTAYS STORAGE BINS 3PK", 14.97, True)],
        "tax_rate": 0.0635,
        "charge": 63.40, "post_days": 1,
    },
    {
        "file": "2026-09-19_aldi.png", "store": "ALDI", "header": ["ALDI", "Store #72046", "Hamden, CT"],
        "date": "2026-09-19", "time": "17:26", "card": BOFA_CARD,
        "items": [("WHOLE MILK", 2.95, False), ("WHITE BREAD", 1.79, False), ("AVOCADOS 4CT", 3.49, False),
                  ("GROUND BEEF 1LB", 4.99, False), ("SHREDDED MOZZARELLA", 2.49, False),
                  ("FLOUR TORTILLAS", 1.95, False), ("GALA APPLES 3LB", 3.99, False),
                  ("PENNE PASTA", 0.95, False), ("CHUNKY SALSA", 2.29, False), ("TORTILLA CHIPS", 2.75, False)],
        "tax_rate": 0.0635,
        "charge": 27.64,
    },
]


def receipt_totals(r: dict) -> tuple[float, float, float]:
    subtotal = money(sum(p for _, p, _ in r["items"]))
    taxable = sum(p for _, p, t in r["items"] if t)
    tax = money(taxable * r["tax_rate"])
    return subtotal, tax, money(subtotal + tax)


# --------------------------------------------------------------------------------------
# Chase (checking + Freedom card) and BofA (savings + card)
# --------------------------------------------------------------------------------------
def chase_and_bofa() -> tuple[list, list, list, list]:
    checking, card, savings, bcard = [], [], [], []
    card_totals: dict[str, float] = {}
    bcard_totals: dict[str, float] = {}

    for m in months():
        key = m.strftime("%Y-%m")
        sep = key == "2026-09"

        # --- Chase checking: pay, rent, transfers, bills
        for day_no in (1, 15):
            day = m.replace(day=day_no)
            if day <= LAST:
                checking.append(txn(day, -2150.00, "YALE UNIV PAYROLL PPD ID: 1066313421", 0))
        for day_no, amount, desc in [
            (1, 1450.00, "ELM CITY APTS ACH RENT WEB ID: 7781045"),
            (3, 800.00, "ONLINE TRANSFER TO BOFA ADV SAVINGS ...5560"),
            (5, 500.00, "FIDELITY INVESTMENTS MONEYLINE PPD"),
            (18, money(rng.uniform(58, 96)), "EVERSOURCE ENERGY BILL PAY"),
            (20, 45.00, "T-MOBILE AUTOPAY WEB"),
        ]:
            day = m.replace(day=day_no)
            if day <= LAST:
                checking.append(txn(day, amount, desc, 1))
        if rng.random() < 0.7:
            day = pick_days(m, 1)[0]
            checking.append(txn(day, -money(rng.choice([24.0, 35.0, 48.5])), "ZELLE PAYMENT FROM ALEX KIM", 0))

        # --- BofA savings: the transfer in, then interest
        day = m.replace(day=3)
        if day <= LAST:
            savings.append(txn(day, -800.00, "TRANSFER FROM CHASE CHK ...0918", 1))
        month_end = (date(m.year + (m.month == 12), m.month % 12 + 1, 1) - timedelta(days=1))
        if month_end <= LAST:
            savings.append(txn(month_end, -money(rng.uniform(0.36, 0.44)), "INTEREST EARNED", 0))

        # --- Chase Freedom card: everyday spending
        spend = []
        tj_days = [x for x in days_in(m) if x.weekday() == 0]  # Trader Joe's on Mondays
        for x in tj_days:
            if sep and x == d("2026-09-07"):
                continue  # September's Trader Joe's trip with a receipt is on the 9th
            spend.append((x, money(rng.uniform(26, 58)), "TRADER JOE S #523 ORANGE CT"))
        for x in pick_days(m, 9 if sep else 6):
            spend.append((x, money(rng.uniform(5.25, 8.95)), "STARBUCKS STORE 08812 NEW HAVEN CT"))
        for x in pick_days(m, 5 if sep else 3):
            spend.append((x, money(rng.uniform(13.45, 17.95)), "SWEETGREEN NEW HAVEN"))
        for x in pick_days(m, 2 if sep else 1):
            spend.append((x, money(rng.uniform(18, 27)), "SHAKE SHACK NEW HAVEN"))
        for x in pick_days(m, 3):
            spend.append((x, money(rng.uniform(4.5, 7.25)), "SQ *BLUE STATE COFFEE"))
        if sep:  # dinners out push Food over budget in September
            spend.append((d("2026-09-26"), 86.40, "UNION LEAGUE CAFE NEW HAVEN"))
            spend.append((d("2026-09-12"), 42.75, "MECHA NOODLE BAR NEW HAVEN"))
            spend.append((d("2026-09-19"), 64.20, "ZINC RESTAURANT NEW HAVEN"))
        for x in pick_days(m, 3):
            spend.append((x, money(rng.uniform(11, 28)), "UBER   *TRIP HELP.UBER.COM"))
        # Sports and Education: gym membership and an online course every month.
        for day_no, amount, desc in [(8, 24.99, "PLANET FITNESS CLUB FEES"), (15, 49.00, "COURSERA PLUS SUBSCRIPTION")]:
            x = m.replace(day=day_no)
            if x <= LAST:
                spend.append((x, amount, desc))
        if key == "2026-08":
            spend.append((d("2026-08-27"), 112.35, "YALE BOOKSTORE NEW HAVEN"))      # textbooks for the term
            spend.append((d("2026-08-16"), 39.99, "DICK'S SPORTING GOODS #1182"))   # running shoes on sale
        if sep:
            spend.append((d("2026-09-08"), 24.99, "PLANET FITNESS CLUB FEES"))  # planted: charged twice
            for r in RECEIPTS:
                if r["card"] == CHASE_CARD:
                    spend.append((d(r["date"]), r["charge"], {
                        "TARGET": "TARGET        T-1931 NEW HAVEN CT",
                        "TRADER JOE'S": "TRADER JOE S #523 ORANGE CT",
                        "WALMART": "WAL-MART #2397 WEST HAVEN CT",
                    }[r["store"]]))
            spend.append((d(AMAZON_ORPHAN[0]), AMAZON_ORPHAN[2], AMAZON_ORPHAN[1]))
        else:
            spend.append((pick_days(m, 1)[0], money(rng.uniform(25, 70)), "TARGET        T-1931 NEW HAVEN CT"))
            spend.append((pick_days(m, 1)[0], money(rng.uniform(30, 80)), "WAL-MART #2397 WEST HAVEN CT"))
        for order in AMAZON_ORDERS:
            for shipment in order["shipments"]:
                if shipment["ship"] and shipment["ship"].startswith(key):
                    total = money(sum(t for *_, t in shipment["items"]))
                    spend.append((d(shipment["ship"]), total, shipment["ref"]))
        for x, amount, desc in spend:
            if x <= LAST:
                card.append(txn(x, amount, desc, 1))
        card_totals[key] = money(sum(a for x, a, _ in spend if x <= LAST))

        # --- BofA card: Aldi, CVS, gas
        bspend = []
        for x in pick_days(m, 2):
            if sep and x.day in (18, 19, 20):
                continue
            bspend.append((x, money(rng.uniform(18, 45)), "ALDI 72046 HAMDEN CT"))
        for x in pick_days(m, 1):
            bspend.append((x, money(rng.uniform(9, 30)), "CVS/PHARMACY #00851 NEW HAVEN CT"))
        for x in pick_days(m, 2):
            bspend.append((x, money(rng.uniform(32, 48)), "SHELL OIL 57444219 HAMDEN CT"))
        if sep:
            aldi = next(r for r in RECEIPTS if r["store"] == "ALDI")
            bspend.append((d(aldi["date"]), aldi["charge"], "ALDI 72046 HAMDEN CT"))
        for x, amount, desc in bspend:
            if x <= LAST:
                bcard.append(txn(x, amount, desc, 1))
        bcard_totals[key] = money(sum(a for x, a, _ in bspend if x <= LAST))

    # Card payments: each card is paid off from Chase checking the next month.
    previous = {"2026-07": ("2026-06", JUNE_CHASE_DUE, JUNE_BOFA_DUE)}
    for m in months():
        key = m.strftime("%Y-%m")
        prev_key = (m - timedelta(days=1)).strftime("%Y-%m")
        chase_due = card_totals.get(prev_key, previous.get(key, (None, 812.40, 0))[1])
        bofa_due = bcard_totals.get(prev_key, previous.get(key, (None, 0, 236.15))[2])
        for day_no, amount, chk_desc, card_list, card_desc in [
            (22, bofa_due, "BANK OF AMERICA CREDIT CARD PMT", bcard, "PAYMENT - THANK YOU"),
            (25, chase_due, "CHASE CREDIT CRD AUTOPAY PPD", card, "AUTOMATIC PAYMENT - THANK YOU"),
        ]:
            x = m.replace(day=day_no)
            if x <= LAST:
                checking.append(txn(x, amount, chk_desc, 0))
                card_list.append(txn(x, -amount, card_desc, 0))

    for lst in (checking, card, savings, bcard):
        lst.sort(key=lambda t: (t["date_transacted"], t["description"]))
    return checking, card, savings, bcard


# June's card statements, paid in July (the only balances from before the data starts).
JUNE_CHASE_DUE, JUNE_BOFA_DUE = 812.40, 236.15


def card_owed(card_txns: list[dict], owed_on_july_1: float) -> float:
    """What's owed today: the July 1 balance plus every purchase minus every payment since."""
    return money(owed_on_july_1 + sum(t["amount"] for t in card_txns))


def plaid_user(name: str, accounts: list[dict]) -> dict:
    return {"seed": f"one-finance-{name}", "roll_dates_forward": False, "override_accounts": accounts}


# --------------------------------------------------------------------------------------
# Indonesian statements (no API): monthly text, as a PDF-to-text tool would give it.
# --------------------------------------------------------------------------------------
def idr(x: float) -> str:
    return f"{x:,.2f}"


def statement_text(bank: str, header: list[str], opening: float, lines: list[tuple[str, str, float]]) -> tuple[str, float]:
    """lines: (dd/mm, description, signed amount: + money in, - money out)."""
    out = [*header, "", f"{'TANGGAL':<8} {'KETERANGAN':<44} {'MUTASI':>18} {'SALDO':>18}"]
    out.append(f"{'01/09':<8} {'SALDO AWAL':<44} {'':>18} {idr(opening):>18}")
    balance = opening
    for day, desc, amount in lines:
        balance += amount
        flag = "CR" if amount > 0 else "DB"
        out.append(f"{day:<8} {desc:<44} {idr(abs(amount)) + ' ' + flag:>18} {idr(balance):>18}")
    total_in = sum(a for *_, a in lines if a > 0)
    total_out = -sum(a for *_, a in lines if a < 0)
    out += ["", f"SALDO AWAL   : {idr(opening)}", f"MUTASI CR    : {idr(total_in)}",
            f"MUTASI DB    : {idr(total_out)}", f"SALDO AKHIR  : {idr(balance)}", "", f"-- {bank} --"]
    return "\n".join(out) + "\n", balance


STATEMENTS = {
    "bca": {
        "header": ["PT BANK CENTRAL ASIA Tbk", "REKENING TAHAPAN", "NO. REKENING : 0281-xx-4471",
                   "NAMA         : DEMO USER", "PERIODE      : SEPTEMBER 2026", "MATA UANG    : IDR"],
        "opening": 17_250_000.00,
        "lines": [("02/09", "TRSF E-BANKING CR 0209/FTSCY/WS95051 DEMO FAMILY", 5_000_000.00),
                  ("05/09", "TRSF E-BANKING DB TOP UP GOPAY 0812xxxx", -500_000.00),
                  ("10/09", "BI-FAST DB KE MANDIRI DEMO USER", -1_000_000.00),
                  ("15/09", "KARTU DEBIT INDOMARET MEDAN", -156_800.00),
                  ("20/09", "TRSF E-BANKING DB BPJS KESEHATAN", -150_000.00),
                  ("28/09", "BIAYA ADM", -15_000.00),
                  ("30/09", "BUNGA", 4_312.00)],
        "account": {"institution": "BCA", "name": "BCA Tahapan", "mask": "4471"},
    },
    "mandiri": {
        "header": ["PT BANK MANDIRI (PERSERO) Tbk", "TABUNGAN MANDIRI", "NO. REKENING : 137-00-xxxx-2290-8",
                   "NAMA         : DEMO USER", "PERIODE      : 01/09/2026 - 30/09/2026", "MATA UANG    : IDR"],
        "opening": 5_300_000.00,
        "lines": [("10/09", "BI-FAST CR DARI BCA DEMO USER", 1_000_000.00),
                  ("12/09", "PEMBAYARAN TOKOPEDIA INV/20260912/MPL", -289_000.00),
                  ("25/09", "PEMBELIAN TOKEN PLN 5412xxxx", -202_500.00),
                  ("30/09", "BIAYA ADMINISTRASI", -12_500.00),
                  ("30/09", "BUNGA", 2_100.00)],
        "account": {"institution": "Mandiri", "name": "Mandiri Tabungan", "mask": "2908"},
    },
    "jago": {
        "header": ["PT BANK JAGO Tbk", "KANTONG UTAMA", "NO. REKENING : 1050xxxx7763",
                   "NAMA         : DEMO USER", "PERIODE      : SEPTEMBER 2026", "MATA UANG    : IDR"],
        "opening": 2_500_000.00,
        "lines": [("08/09", "PEMBAYARAN GOPAY", -150_000.00),
                  ("18/09", "TRANSFER MASUK DARI DEMO FAMILY", 400_000.00),
                  ("30/09", "BUNGA", 3_125.00)],
        "account": {"institution": "Jago", "name": "Jago Kantong Utama", "mask": "7763"},
    },
}


# --------------------------------------------------------------------------------------
# Investments, shaped like SnapTrade's accounts / positions / balances answers.
# --------------------------------------------------------------------------------------
INVESTMENTS = {
    "note": "Sample data, made up. Shaped like SnapTrade's /accounts, /positions and /balances responses.",
    "as_of": LAST.isoformat(),
    "accounts": [{
        "id": "snaptrade-fidelity-individual",
        "institution_name": "Fidelity",
        "name": "Fidelity Individual",
        "number": "X94721",
        "balance": {"total": {"amount": None, "currency": "USD"}},
    }],
    "positions": [
        {"symbol": {"symbol": {"symbol": "AAPL", "description": "Apple Inc."}}, "units": 12, "price": 248.30, "average_purchase_price": 189.40},
        {"symbol": {"symbol": {"symbol": "MSFT", "description": "Microsoft Corporation"}}, "units": 6.95, "price": 512.75, "average_purchase_price": 408.60},
        {"symbol": {"symbol": {"symbol": "NVDA", "description": "NVIDIA Corporation"}}, "units": 22.6, "price": 186.40, "average_purchase_price": 121.35},
        {"symbol": {"symbol": {"symbol": "COST", "description": "Costco Wholesale Corporation"}}, "units": 3, "price": 968.20, "average_purchase_price": 841.10},
        {"symbol": {"symbol": {"symbol": "VOO", "description": "Vanguard S&P 500 ETF"}}, "units": 8.8, "price": 612.45, "average_purchase_price": 528.90},
    ],
    "balances": [{"currency": {"code": "USD"}, "cash": 412.55}],
    "activities": [
        {"trade_date": "2026-07-08", "type": "BUY", "symbol": "VOO", "units": 0.8, "price": 596.10},
        {"trade_date": "2026-08-07", "type": "BUY", "symbol": "NVDA", "units": 2.6, "price": 181.20},
        {"trade_date": "2026-09-08", "type": "BUY", "symbol": "AAPL", "units": 2, "price": 241.85},
        {"trade_date": "2026-10-07", "type": "BUY", "symbol": "MSFT", "units": 0.95, "price": 508.40},
    ],
}
INVESTMENTS["accounts"][0]["balance"]["total"]["amount"] = money(
    sum(p["units"] * p["price"] for p in INVESTMENTS["positions"]) + INVESTMENTS["balances"][0]["cash"]
)

# The owner's pocket list (2026-10-24). Pockets are guidance only: labels on the money,
# not tied to any account. First iteration: the top 8 expense pockets are active; the rest
# are in the catalog (active: false) and can be added or renamed in Budget setup.
# monthly_budget: spending budget, or the monthly amount set aside for savings/investing.
# starting_amount: what a savings/investing pocket held when budgeting started (Sep 1, 2026).
POCKETS = [
    {"name": "Home Rent", "kind": "spending", "monthly_budget": 1450, "description": "Monthly rent"},
    {"name": "Utilities", "kind": "spending", "monthly_budget": 250, "description": "Electricity, phone, internet"},
    {"name": "Food", "kind": "spending", "monthly_budget": 700, "description": "Groceries, restaurants, coffee"},
    {"name": "Supplies", "kind": "spending", "monthly_budget": 200, "description": "Household goods and everyday items"},
    {"name": "Transportation", "kind": "spending", "monthly_budget": 150, "description": "Rides, gas, transit"},
    {"name": "Healthcare", "kind": "spending", "monthly_budget": 60, "description": "Pharmacy, doctor, insurance"},
    {"name": "Sports", "kind": "spending", "monthly_budget": 60, "description": "Gym, sports gear, events"},
    {"name": "Education", "kind": "spending", "monthly_budget": 120, "description": "Courses, books, school fees"},
    {"name": "Shopping", "kind": "spending", "monthly_budget": 150, "active": False, "description": "Clothes and general shopping"},
    {"name": "Electronics", "kind": "spending", "monthly_budget": 100, "active": False, "description": "Gadgets and accessories"},
    {"name": "Misc", "kind": "spending", "monthly_budget": 50, "active": False, "description": "Small one-off things"},
    {"name": "Entertainment", "kind": "spending", "monthly_budget": 60, "active": False, "description": "Streaming, music, events"},
    {"name": "Travel", "kind": "spending", "monthly_budget": 200, "active": False, "description": "Flights, hotels, trips"},
    {"name": "Gifts", "kind": "spending", "monthly_budget": 50, "active": False, "description": "Presents and donations"},
    {"name": "Other expenses", "kind": "spending", "monthly_budget": 100, "active": False, "custom": True, "description": "Rename to anything"},
    {"name": "Emergency Fund", "kind": "saving", "monthly_budget": 300, "goal_amount": 15000, "starting_amount": 8600, "description": "Six months of essentials"},
    {"name": "General Savings", "kind": "saving", "monthly_budget": 200, "starting_amount": 2900, "description": "Savings with no set goal"},
    {"name": "Investment", "kind": "investing", "monthly_budget": 500, "starting_amount": 1000, "description": "Ready to invest: set aside to move to the brokerage"},
    {"name": "Other Savings", "kind": "saving", "monthly_budget": 100, "goal_amount": 1500, "starting_amount": 600, "custom": True, "description": "Rename to anything (e.g. Holiday)"},
]

# Quick entries typed in by hand (e.g. from Back Tap), with no receipt or bank charge yet.
MANUAL_ENTRIES = [
    {"date": "2026-10-12", "description": "Cash at farmers market", "amount": 18.00, "pocket": "Food"},
    {"date": "2026-10-19", "description": "Intramural soccer fee (cash)", "amount": 42.00, "pocket": "Sports"},
]


# --------------------------------------------------------------------------------------
# Writers
# --------------------------------------------------------------------------------------
def font(size: int):
    for path in ("/System/Library/Fonts/Menlo.ttc", "/System/Library/Fonts/Monaco.ttf"):
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default(size=size)


def render_receipt(r: dict, out: Path) -> None:
    subtotal, tax, total = receipt_totals(r)
    width = 34
    rows = [h.center(width) for h in r["header"]] + [""]
    rows.append(f"{d(r['date']).strftime('%m/%d/%Y')}  {r['time']}".center(width))
    rows.append("")
    for name, price, taxable in r["items"]:
        label = (name + (" T" if taxable else ""))[: width - 9]
        rows.append(f"{label:<{width - 9}}{price:>9.2f}")
    rows += ["", f"{'SUBTOTAL':<{width - 9}}{subtotal:>9.2f}", f"{'TAX':<{width - 9}}{tax:>9.2f}",
             f"{'TOTAL':<{width - 9}}{total:>9.2f}", "", f"{'VISA ****' + r['card']:<{width - 9}}{total:>9.2f}",
             "", "THANK YOU FOR SHOPPING".center(width)]
    f = font(22)
    line_h = 30
    img = Image.new("RGB", (560, 70 + line_h * len(rows)), (250, 249, 244))
    draw = ImageDraw.Draw(img)
    for i, row in enumerate(rows):
        draw.text((32, 34 + line_h * i), row, fill=(30, 30, 30), font=f)
    img = img.rotate(rng.uniform(-1.2, 1.2), expand=True, fillcolor=(214, 210, 200))  # a little like a photo
    img.save(out)


def write_amazon_csv(out: Path) -> None:
    cols = ["Website", "Order ID", "Order Date", "Currency", "Unit Price", "Unit Price Tax", "Shipping Charge",
            "Total Discounts", "Total Owed", "Shipment Item Subtotal", "Shipment Item Subtotal Tax", "ASIN",
            "Product Condition", "Quantity", "Payment Instrument Type", "Order Status", "Shipment Status",
            "Ship Date", "Product Name"]
    with out.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        for order in AMAZON_ORDERS:
            ordered_at = f"{order['date']}T{rng.randint(8, 22):02d}:{rng.randint(0, 59):02d}:{rng.randint(0, 59):02d}Z"
            for shipment in order["shipments"]:
                for product, asin, qty, total in shipment["items"]:
                    unit = money(total / 1.0635 / qty)
                    unit_tax = money(total / qty - unit)
                    shipped = shipment["ship"] is not None
                    w.writerow([
                        "Amazon.com", order["id"], ordered_at,
                        "USD", f"{unit:.2f}", f"{unit_tax:.2f}", "0", "0", f"{total:.2f}",
                        f"{unit * qty:.2f}" if shipped else "Not Available", f"{unit_tax * qty:.2f}" if shipped else "Not Available",
                        asin, "New", qty, f"Visa - {CHASE_CARD}", "Closed" if shipped else "New",
                        "Shipped" if shipped else "Not Yet Shipped",
                        f"{shipment['ship']}T09:00:00Z" if shipped else "Not Available", product,
                    ])


def write_story(out: Path, checking, card, savings, bcard, closings) -> None:
    def count(lst):
        return len(lst)

    target = next(r for r in RECEIPTS if r["store"] == "TARGET")
    _, _, target_total = receipt_totals(target)
    out.write_text(f"""# One Finance sample data

**Everything here is made up.** No real accounts, people or purchases. It's one consistent story,
generated by `scripts/make_sample_data.py`, so the bank charges, receipts, Amazon orders and statements agree
with each other except where a problem was planted on purpose.

- The sample's "today" is **{APP_DATE}**. Transactions run from {START} to {LAST}.
- **The month to check is September 2026.**

## Accounts

| Where | Account | Last 4 | Transactions |
|---|---|---|---|
| Chase (Plaid sandbox) | Chase Total Checking | {CHASE_CHECKING} | {count(checking)} |
| Chase (Plaid sandbox) | Chase Freedom Unlimited (credit card) | {CHASE_CARD} | {count(card)} |
| Bank of America (Plaid sandbox) | BofA Advantage Savings | {BOFA_SAVINGS} | {count(savings)} |
| Bank of America (Plaid sandbox) | BofA Customized Cash Rewards (credit card) | {BOFA_CARD} | {count(bcard)} |
| BCA (statement) | BCA Tahapan (IDR) | 4471 | September statement, closing {idr(closings['bca'])} |
| Mandiri (statement) | Mandiri Tabungan (IDR) | 2908 | September statement, closing {idr(closings['mandiri'])} |
| Jago (statement) | Jago Kantong Utama (IDR) | 7763 | September statement, closing {idr(closings['jago'])} |
| Fidelity (SnapTrade-shaped) | Fidelity Individual | 4721 | 5 positions + cash |

## Planted problems in September (what the Accountant should find)

| # | What | Where |
|---|---|---|
| 1 | **Amount mismatch:** the Target receipt totals ${target_total:.2f}, but the card was charged ${target['charge']:.2f} | Sep 6, Chase card {CHASE_CARD}, `receipts/2026-09-06_target.png` |
| 2 | **Duplicate charge:** the gym (Planet Fitness) charged twice ($24.99 each) | Sep 8, Chase card |
| 3 | **Charge with no order:** an Amazon charge of ${AMAZON_ORPHAN[2]:.2f} that matches no order in the Amazon CSV | {AMAZON_ORPHAN[0]}, Chase card |
| 4 | **Split shipment (not a problem):** one Amazon order, two charges on different days ($41.98 + $22.99) | Order 113-7720518-9014466, Sep 11 and Sep 13 |
| 5 | **Over budget:** Food (groceries + restaurants) goes over its $700 budget | September, Chase and BofA cards |

## Clean matches (should be recorded without asking)

- Trader Joe's, Sep 9, $38.17: receipt = charge (Chase card)
- Walmart, Sep 14, $63.40: receipt = charge, posted a day later (Chase card)
- Aldi, Sep 19, $27.64: receipt = charge, on the **BofA** card {BOFA_CARD}
- Amazon order 112-3369040-6257731, $18.49: order = charge

## Files

- `../plaid_sandbox/*.json`: Plaid custom sandbox users (the recipe for the bank data)
- `plaid_snapshot.json`: what Plaid sandbox returned for those users (used when there are no Plaid keys)
- `amazon/Retail.OrderHistory.1.csv`: Amazon order history (same columns as Amazon's "Request your data" export)
- `receipts/`: receipt photos
- `statements/`: BCA, Mandiri and Jago statements for September (text)
- `investments.json`: brokerage positions, shaped like SnapTrade's answer
- `sec/`: SEC EDGAR company data for the stocks held
- `pockets.json`: budget pockets
""")


def main() -> None:
    for sub in ("amazon", "receipts", "statements"):
        (SAMPLE / sub).mkdir(parents=True, exist_ok=True)
    PLAID_DIR.mkdir(parents=True, exist_ok=True)

    checking, card, savings, bcard = chase_and_bofa()
    chase = plaid_user("chase", [
        {"type": "depository", "subtype": "checking", "starting_balance": 4382.17, "currency": "USD",
         "meta": {"name": "Chase Total Checking", "official_name": "Chase Total Checking", "mask": CHASE_CHECKING},
         "transactions": checking},
        {"type": "credit", "subtype": "credit card", "starting_balance": card_owed(card, JUNE_CHASE_DUE), "currency": "USD",
         "meta": {"name": "Chase Freedom Unlimited", "official_name": "Chase Freedom Unlimited Visa", "mask": CHASE_CARD, "limit": 8000},
         "transactions": card},
    ])
    bofa = plaid_user("bofa", [
        {"type": "depository", "subtype": "savings", "starting_balance": 11840.62, "currency": "USD",
         "meta": {"name": "BofA Advantage Savings", "official_name": "Bank of America Advantage Savings", "mask": BOFA_SAVINGS},
         "transactions": savings},
        {"type": "credit", "subtype": "credit card", "starting_balance": card_owed(bcard, JUNE_BOFA_DUE), "currency": "USD",
         "meta": {"name": "BofA Customized Cash Rewards", "official_name": "Bank of America Customized Cash Rewards Visa", "mask": BOFA_CARD, "limit": 5000},
         "transactions": bcard},
    ])
    for name, user in (("chase", chase), ("bofa", bofa)):
        text = json.dumps(user, indent=1)
        n = sum(len(a["transactions"]) for a in user["override_accounts"])
        if n > 250 or len(json.dumps(user)) > 55_000:
            raise SystemExit(f"{name}: {n} transactions / {len(json.dumps(user))} bytes is over Plaid's custom-user limit")
        (PLAID_DIR / f"{name}_user.json").write_text(text + "\n")
        print(f"plaid_sandbox/{name}_user.json: {n} transactions, {len(json.dumps(user)):,} bytes")

    write_amazon_csv(SAMPLE / "amazon" / "Retail.OrderHistory.1.csv")
    print("sample/amazon/Retail.OrderHistory.1.csv")

    for r in RECEIPTS:
        render_receipt(r, SAMPLE / "receipts" / r["file"])
        print(f"sample/receipts/{r['file']}: total {receipt_totals(r)[2]:.2f}, charged {r['charge']:.2f}")

    closings = {}
    for bank, s in STATEMENTS.items():
        text, closing = statement_text(bank.upper(), s["header"], s["opening"], s["lines"])
        (SAMPLE / "statements" / f"{bank}_2026-09.txt").write_text(text)
        closings[bank] = closing
        print(f"sample/statements/{bank}_2026-09.txt: closing IDR {idr(closing)}")

    meta = {bank: {**s["account"], "currency": "IDR", "closing_balance": closings[bank], "period": "2026-09"}
            for bank, s in STATEMENTS.items()}
    (SAMPLE / "statements" / "accounts.json").write_text(json.dumps(meta, indent=2) + "\n")
    (SAMPLE / "investments.json").write_text(json.dumps(INVESTMENTS, indent=2) + "\n")
    (SAMPLE / "pockets.json").write_text(json.dumps(POCKETS, indent=2) + "\n")
    (SAMPLE / "manual_entries.json").write_text(json.dumps(MANUAL_ENTRIES, indent=2) + "\n")
    (SAMPLE / "receipts" / "receipts.json").write_text(json.dumps(
        [{"file": r["file"], "store": r["store"], "date": r["date"], "card_last4": r["card"],
          "total": receipt_totals(r)[2]} for r in RECEIPTS], indent=2) + "\n")
    write_story(SAMPLE / "STORY.md", checking, card, savings, bcard, closings)
    print("sample/investments.json, sample/pockets.json, sample/STORY.md")


if __name__ == "__main__":
    main()
