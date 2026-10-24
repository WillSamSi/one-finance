"""Settings for One Finance: where keys come from, the model, and Plaid.

Keys are read from a `.env` file in two places, in this order (the course's rule):
  1. this repo's own folder
  2. the folder just above it (where the teaching staff keep their .env)
A value found in the repo's .env wins over the one above. Real environment
variables win over both.

Check your setup (shows which keys are set, never their values):
    .venv/bin/python -m backend.config
"""

import os
from functools import lru_cache
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
ENV_FILES = (ROOT / ".env", ROOT.parent / ".env")

# override=False: the first file to set a key keeps it, so the repo's .env wins.
LOADED_ENV_FILES: list[Path] = []
for _env_file in ENV_FILES:
    if _env_file.is_file():
        load_dotenv(_env_file, override=False)
        LOADED_ENV_FILES.append(_env_file)
os.environ.setdefault("PYDANTIC_AI_NO_BANNER", "1")

# --- Model --------------------------------------------------------------------
# The one model every agent uses, reached through Portkey with the course key.
MODEL_NAME = "gpt-6-luna"
PORTKEY_BASE_URL = os.environ.get("PORTKEY_BASE_URL", "https://api.portkey.ai/v1")

# --- Cost limits (enforced in backend/team.py) ---------------------------------
# Loop steps: model turns one agent may take in a single run before it is stopped.
MAX_AGENT_STEPS = 12
# Hand-offs: only the Advisor may delegate, one level deep, at most 2 times per run.
MAX_DELEGATION_DEPTH = 1
MAX_DELEGATIONS_PER_RUN = 2
# Whole-run budget, shared by every agent working that run (including hand-offs).
RUN_REQUEST_LIMIT = 30
RUN_TOOL_CALLS_LIMIT = 60
RUN_TOTAL_TOKENS_LIMIT = 250_000
# Per-response cap so no single answer runs long (no temperature: reasoning model).
MAX_OUTPUT_TOKENS = 4_000
# Daily budget across all runs; a new run is refused once today's total passes it.
DAILY_TOKEN_LIMIT = int(os.environ.get("DAILY_TOKEN_LIMIT", "1500000"))


def run_usage_limits():
    from pydantic_ai.usage import UsageLimits

    return UsageLimits(
        request_limit=RUN_REQUEST_LIMIT,
        tool_calls_limit=RUN_TOOL_CALLS_LIMIT,
        total_tokens_limit=RUN_TOTAL_TOKENS_LIMIT,
    )


def model_settings():
    from pydantic_ai.settings import ModelSettings

    return ModelSettings(max_tokens=MAX_OUTPUT_TOKENS)


# --- Plaid (optional) ---------------------------------------------------------
# Without Plaid keys (as on the teaching staff's machine) the app uses the saved
# sample data instead; the AI agents still run for real on it.
PLAID_CLIENT_ID = os.environ.get("PLAID_CLIENT_ID", "").strip()
PLAID_SECRET = os.environ.get("PLAID_SECRET", "").strip()
PLAID_ENV = os.environ.get("PLAID_ENV", "sandbox").strip() or "sandbox"
PLAID_BASE_URL = {
    "sandbox": "https://sandbox.plaid.com",
    "production": "https://production.plaid.com",
}.get(PLAID_ENV, "https://sandbox.plaid.com")


def plaid_enabled() -> bool:
    """True when Plaid keys are set; False means sample-data mode."""
    return bool(PLAID_CLIENT_ID and PLAID_SECRET)


@lru_cache
def get_model():
    """Build the Portkey-backed model. Fails clearly if PORTKEY_API_KEY is missing.

    Uses the Responses API: Portkey serves this model from Azure OpenAI, which only
    allows tool calls together with reasoning on /v1/responses (same as Homework 5).
    """
    from openai import AsyncOpenAI
    from pydantic_ai.models.openai import OpenAIResponsesModel
    from pydantic_ai.providers.openai import OpenAIProvider

    api_key = os.environ.get("PORTKEY_API_KEY")
    if not api_key:
        looked = " or ".join(str(p) for p in ENV_FILES)
        raise RuntimeError(f"PORTKEY_API_KEY is not set. Put it in {looked}. See .env.example.")
    client = AsyncOpenAI(
        base_url=PORTKEY_BASE_URL,
        api_key=api_key,
        default_headers={"x-portkey-api-key": api_key},
    )
    return OpenAIResponsesModel(MODEL_NAME, provider=OpenAIProvider(openai_client=client))


def describe() -> str:
    """Human-readable setup check. Never prints a key's value."""
    def state(name: str) -> str:
        return "set" if os.environ.get(name, "").strip() else "missing"

    lines = ["Looked for .env in:"]
    for p in ENV_FILES:
        lines.append(f"  {'found' if p in LOADED_ENV_FILES else 'none '}  {p}")
    lines.append(f"PORTKEY_API_KEY: {state('PORTKEY_API_KEY')}")
    lines.append(f"PLAID_CLIENT_ID: {state('PLAID_CLIENT_ID')}")
    lines.append(f"PLAID_SECRET:    {state('PLAID_SECRET')}")
    lines.append(f"PLAID_ENV:       {PLAID_ENV}")
    lines.append(f"Bank data:       {'live Plaid ' + PLAID_ENV if plaid_enabled() else 'sample data (no Plaid keys)'}")
    return "\n".join(lines)


if __name__ == "__main__":
    print(describe())
