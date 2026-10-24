"""Run the agents from the command line (no Xcode needed). From the repo folder:

    .venv/bin/python -m backend.run month-end 2026-09   # the Accountant's month-end check
    .venv/bin/python -m backend.run receipt 1           # the Accountant reads receipt #1
    .venv/bin/python -m backend.run brief               # the Investor's portfolio brief
    .venv/bin/python -m backend.run digest              # the Advisor's weekly digest (hands off to the Investor)
    .venv/bin/python -m backend.run chat "How is my dining budget?"
    .venv/bin/python -m backend.run reset               # start over from the sample data

Every step and its tokens go to the run_log table; the totals are printed at the end.
"""

import asyncio
import json
import sys

from backend import agents, db


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "reset":
        db.reset_working_db()
        print("Working database reset from data/sample.db")
        return
    runs = {
        "month-end": lambda: agents.month_end(args[0] if args else "2026-09"),
        "receipt": lambda: agents.read_receipt(int(args[0])),
        "brief": agents.portfolio_brief,
        "digest": agents.weekly_digest,
        "chat": lambda: agents.chat(" ".join(args)),
    }
    if cmd not in runs:
        sys.exit(__doc__)
    out = asyncio.run(runs[cmd]())
    print(json.dumps(out, indent=2, default=str))


if __name__ == "__main__":
    main()
