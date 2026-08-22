---
description: Finish the current goal with verification
agent: qwen-local
subtask: false
---

Treat the current conversation request as a completion contract. Incorporate this additional acceptance criterion when supplied: $ARGUMENTS

Continue the work now. Re-read the request and applicable project instructions, inspect the current repository state and diff, complete every in-scope requirement, and run the authoritative build, lint, typecheck, and test commands that apply. If a check fails because of an in-scope defect, diagnose it, fix it, and rerun the check. Finish only when the acceptance criteria pass or when you can name a concrete blocker with evidence and the exact remaining action.
