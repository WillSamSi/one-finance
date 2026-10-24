"""Shared machinery for the agents (adapted from Homework 5's team.py).

- `build_agent` creates an agent from its prompt file, its own tool list and output type.
- `run_agent` drives an agent step by step, writes every step (with tokens) to the
  run_log table, and enforces the step cap and the run's token budget.
- `delegate` lets the Advisor hand a task to the Accountant or the Investor,
  one level deep and a limited number of times per run.
"""

import json
from collections.abc import Callable, Sequence
from datetime import date, datetime, timezone
from typing import Any
from uuid import uuid4

from pydantic import BaseModel
from pydantic_ai import Agent, RunContext
from pydantic_ai.exceptions import UsageLimitExceeded
from pydantic_ai.messages import RetryPromptPart, TextPart, ToolCallPart, ToolReturnPart
from pydantic_ai.usage import RunUsage

from backend import config, db
from backend.models import AgentDeps

PROMPTS_DIR = config.ROOT / "backend" / "prompts"


class BudgetExceeded(RuntimeError):
    """Today's token budget is used up; no new runs until tomorrow."""


def new_run_id() -> str:
    return uuid4().hex[:12]


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def _jsonable(value: Any) -> Any:
    if isinstance(value, BaseModel):
        value = value.model_dump(mode="json")
    return json.loads(json.dumps(value, default=str))


def log_step(deps: AgentDeps, step_type: str, *, tool: str | None = None, text: str | None = None,
             data: Any = None, usage: dict | None = None) -> None:
    usage = usage or {}
    with db.connect() as conn:
        conn.execute(
            "INSERT INTO run_log (run_id, agent, chain, step, step_type, tool, text, data_json, input_tokens,"
            " cached_tokens, output_tokens, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (deps.run_id, deps.agent, ">".join(deps.chain), deps.next_step(), step_type, tool, text,
             json.dumps(_jsonable(data)) if data is not None else None,
             usage.get("input_tokens"), usage.get("cached_tokens"), usage.get("output_tokens"), _now()),
        )


def tokens_used_today() -> int:
    with db.connect() as conn:
        row = conn.execute(
            "SELECT COALESCE(SUM(COALESCE(input_tokens,0) + COALESCE(output_tokens,0)), 0) FROM run_log"
            " WHERE substr(created_at, 1, 10) = ?",
            (date.today().isoformat(),),
        ).fetchone()
    return int(row[0])


def check_daily_budget() -> None:
    used = tokens_used_today()
    if used >= config.DAILY_TOKEN_LIMIT:
        raise BudgetExceeded(f"Today's token budget is used up ({used:,} of {config.DAILY_TOKEN_LIMIT:,}).")


def build_agent(role: str, tools: Sequence[Callable], output_type: Any = str, prompt_file: str | None = None) -> Agent:
    """Create one agent: its prompt file, its own tools, and its output type."""
    return Agent(
        name=role,
        instructions=(PROMPTS_DIR / f"{prompt_file or role}.md").read_text(),
        deps_type=AgentDeps,
        output_type=output_type,
        tools=list(tools),
        model_settings=config.model_settings(),
        retries=2,
    )


async def run_agent(agent: Agent, prompt: Any, deps: AgentDeps, usage: RunUsage | None = None) -> Any:
    """Run one agent to completion (or its step cap), logging every step with its tokens."""
    log_step(deps, "prompt", text=prompt if isinstance(prompt, str) else str(prompt[0]))
    model_turns = 0
    try:
        async with agent.iter(
            prompt,
            deps=deps,
            model=config.get_model(),
            usage=usage,
            usage_limits=config.run_usage_limits(),
        ) as run:
            async for node in run:
                if Agent.is_model_request_node(node):
                    for p in node.request.parts:
                        if isinstance(p, ToolReturnPart):
                            log_step(deps, "tool_result", tool=p.tool_name, data=p.content)
                        elif isinstance(p, RetryPromptPart):
                            log_step(deps, "retry", tool=p.tool_name, text=str(p.content)[:2000])
                    model_turns += 1
                    if model_turns > config.MAX_AGENT_STEPS:
                        log_step(deps, "limit", text=f"Step cap reached: {config.MAX_AGENT_STEPS} model turns. Agent stopped.")
                        break
                elif Agent.is_call_tools_node(node):
                    response = node.model_response
                    u = response.usage
                    texts = [p.content for p in response.parts if isinstance(p, TextPart)]
                    calls = [{"tool": p.tool_name, "args": p.args_as_dict()} for p in response.parts if isinstance(p, ToolCallPart)]
                    log_step(
                        deps, "model_response",
                        text="\n".join(texts) or None,
                        data=calls or None,
                        usage={"input_tokens": u.input_tokens, "cached_tokens": u.cache_read_tokens,
                               "output_tokens": u.output_tokens},
                    )
            result = run.result
    except UsageLimitExceeded as exc:
        log_step(deps, "limit", text=f"Run budget used up: {exc}")
        raise
    except Exception as exc:
        log_step(deps, "error", text=repr(exc)[:2000])
        raise

    if result is None:
        return f"[{deps.agent}] stopped after {config.MAX_AGENT_STEPS} model turns without finishing (step cap)."
    log_step(deps, "final_output", data=result.output)
    return result.output


async def delegate(ctx: RunContext[AgentDeps], to_agent: str, task: str) -> str:
    """Hand a task to a specialist and get their answer back.

    Args:
        to_agent: 'accountant' (spending, receipts, budgets, the ledger) or 'investor' (positions, company data).
        task: A self-contained request with every fact the specialist needs.
    """
    from backend import agents  # the specialists live there; imported late to avoid a cycle

    deps = ctx.deps
    refusal = None
    if to_agent not in ("accountant", "investor"):
        refusal = "you can only hand work to 'accountant' or 'investor'."
    elif deps.depth + 1 > config.MAX_DELEGATION_DEPTH:
        refusal = "specialists can't hand work further. Answer with what you have."
    elif deps.budget.delegations >= config.MAX_DELEGATIONS_PER_RUN:
        refusal = f"this run already used all {config.MAX_DELEGATIONS_PER_RUN} hand-offs. Answer with what you have."
    if refusal:
        log_step(deps, "delegation", tool="delegate", text=f"refused: {refusal}", data={"to": to_agent, "task": task})
        return f"Hand-off refused: {refusal}"

    deps.budget.delegations += 1
    log_step(deps, "delegation", tool="delegate", text=f"to {to_agent}", data={"to": to_agent, "task": task})
    try:
        output = await run_agent(agents.specialist(to_agent), task, deps.child(to_agent), usage=ctx.usage)
    except UsageLimitExceeded:
        raise
    except Exception as exc:
        return f"Hand-off to {to_agent} failed: {exc!r}"
    return output.model_dump_json() if isinstance(output, BaseModel) else str(output)
