"""Data types shared by the agents: what each agent must return, and run state."""

from dataclasses import dataclass, field
from typing import Literal

from pydantic import BaseModel, Field

AgentName = Literal["accountant", "investor", "advisor"]


# --- Accountant ----------------------------------------------------------------------
class ReceiptItem(BaseModel):
    name: str
    quantity: float = 1
    price: float = Field(description="Line total for this item, as printed.")
    suggested_pocket: str | None = Field(None, description="Best pocket for this item, from the list given (by what it is).")


class ReceiptRead(BaseModel):
    """What the Accountant reads from a receipt photo."""

    store: str
    date: str = Field(description="YYYY-MM-DD")
    items: list[ReceiptItem]
    subtotal: float
    tax: float
    total: float
    card_last4: str | None = Field(None, description="Last 4 digits of the card, if printed.")
    problems: list[str] = Field(default_factory=list, description="Anything unreadable or that doesn't add up.")


DiscrepancyKind = Literal[
    "amount_mismatch",       # receipt or order total differs from the bank charge
    "duplicate_charge",      # the same charge appears twice
    "no_matching_order",     # an Amazon-looking charge with no order
    "no_matching_charge",    # a receipt, order or manual entry with no bank charge
    "over_budget",           # a pocket went over its monthly budget
    "statement_mismatch",    # statement lines don't add up to its totals
    "cash_check",            # pockets promise more money than exists (Unassigned below zero)
    "unclear",               # needs a human look for another reason
]


class Discrepancy(BaseModel):
    kind: DiscrepancyKind
    detail: str = Field(description="One or two plain sentences: what's wrong and the numbers.")
    transaction_id: str | None = None
    receipt_id: int | None = None
    amazon_order_id: str | None = None
    pocket: str | None = None
    amount: float | None = None


class MonthLedger(BaseModel):
    """The Accountant's month-end result."""

    month: str
    entries_recorded: int
    receipts_matched: int
    amazon_orders_matched: int
    statements_recorded: int
    discrepancies: list[Discrepancy]
    cash_check: str = Field(description="One sentence: do pockets + Unassigned equal all the money? With the numbers.")
    summary: str = Field(description="Three or four plain sentences for the owner.")


class QuickEntry(BaseModel):
    """An expense typed in one line ("lunch 12.50 Chipotle cash"), turned into form fields."""

    amount: float | None = None
    currency: str = "USD"
    pocket: str | None = Field(None, description="One of the given pocket names, or null if unsure.")
    paid_with: str | None = Field(None, description="'cash_usd', 'cash_idr', one of the given account ids, or null.")
    note: str | None = Field(None, description="Where or what, e.g. 'Chipotle'.")
    date: str | None = Field(None, description="YYYY-MM-DD if a day is mentioned (relative to today), else null.")


# --- Investor --------------------------------------------------------------------------
class HoldingNote(BaseModel):
    symbol: str
    weight_pct: float
    gain_pct: float
    sector: str
    key_numbers: str = Field(description="Latest annual revenue, profit and their trend, from SEC data, with years.")
    note: str


class PortfolioBrief(BaseModel):
    as_of: str
    total_value: float
    cash: float
    invested_this_month: float
    investment_budget: float
    holdings: list[HoldingNote]
    concentration: list[str] = Field(description="Sector or single-stock shares above the owner's limit, with numbers.")
    risks: list[str]
    sources: list[str] = Field(description="Where each number came from (e.g. 'AAPL 10-K FY2025, SEC companyfacts').")


# --- Advisor ---------------------------------------------------------------------------
class NextStep(BaseModel):
    title: str
    detail: str
    action: Literal["review", "fix", "view"]


class WeeklyDigest(BaseModel):
    spending_title: str
    spending_body: str = Field(description="Spending vs budget this month, with numbers.")
    investment_title: str
    investment_body: str = Field(description="Suggestions about the investment account, labeled as suggestions.")
    next_steps: list[NextStep]


class PocketAmount(BaseModel):
    pocket: str
    monthly_amount: float = Field(ge=0)
    reason: str = Field(description="One short sentence with the numbers it's based on.")


class BudgetSuggestion(BaseModel):
    """The Advisor's suggested monthly amounts (the owner decides whether to use them)."""

    suggestions: list[PocketAmount]
    note: str


# --- Run state -------------------------------------------------------------------------
@dataclass
class RunBudget:
    """Counters shared by every agent working one run."""

    delegations: int = 0
    steps: int = 0  # run_log step counter, shared so steps are numbered across agents


@dataclass
class AgentDeps:
    """Passed to every agent. A delegation gets a child copy one level deeper."""

    run_id: str
    chain: list[str]
    month: str | None = None
    budget: RunBudget = field(default_factory=RunBudget)

    def next_step(self) -> int:
        self.budget.steps += 1
        return self.budget.steps

    @property
    def agent(self) -> str:
        return self.chain[-1]

    @property
    def depth(self) -> int:
        return len(self.chain) - 1

    def child(self, to_agent: str) -> "AgentDeps":
        return AgentDeps(self.run_id, [*self.chain, to_agent], self.month, self.budget)
