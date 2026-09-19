# AGENTS.GIT.md

## Scope

Git and GitHub workflow guidance for this repository. Use this guide whenever branch, commit, pull request, release, or history operations are in scope.

## Rules

- The production branch is `master` unless the repo explicitly documents a different current branch.
- Use forward-only history. Do not rewrite, rebase, force-push, or amend published work.
- Branch names use taxonomy prefixes: `feature/`, `improvement/`, `bugfix/`, `maintenance/`, or `blocked/`.
- Keep one concrete issue or task per branch.
- Never create or use a separate Git worktree unless the user explicitly requests it in the current request.
- Work only in the existing primary checkout. If the checkout is not safe, stop and ask the user.
- Do not infer worktree permission from a request to isolate work or preserve unrelated changes.
- Do not infer permission from a request to branch, implement, commit, push, open a pull request, or parallelize.
- Prefer repo-native commands and documented release helpers.
- Do not commit secrets, local env files, generated caches, or ephemeral planning files.
- Run a deploy or publish command only when the user explicitly requests it and the repository contract permits it.

## Pull Requests

- Open pull requests only after necessary local validation passes or a concrete blocker is documented.
- A pull request description must summarize changed behavior and completed validation.
- Keep release, publish, deploy, and production availability as separate statuses.

## Forbidden Operations

- `git push --force`
- `git rebase`
- `git reset --hard`
- history rewrites
- deleting or replacing user work without explicit instruction

## Validation

Before you finalize Git work, complete the applicable validation after the last change.

Use that result while the applicable files stay the same.

Then, run these commands:

```bash
git diff --check
git status --short
```
