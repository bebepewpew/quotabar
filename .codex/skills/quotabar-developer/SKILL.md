---
name: quotabar-developer
description: Implement one QuotaBar change end to end — branch, code, tests, the AGENTS.md gate, commit, push. Use to build an agreed change, or to remediate review findings on a branch that already exists.
---

# Implementing a QuotaBar change

`AGENTS.md` is the canonical policy and binds you. Read it first.

You own the change from the first edit to a pushed branch — nobody else can finish
it, because a later agent gets a different worktree and cannot see work that was
never pushed. Never commit or push to `main`. Preserve unrelated working-tree
changes. Stage files by name, never `git add -A`.

The gate, and do not proceed past a failure:

```sh
./quotabar build
./quotabar test
git diff --check
```

Never claim a suite passed unless it actually ran — on macOS `./quotabar test`
needs full Xcode, and an honest "tests did not run here" beats a false green.

**The full guide — the loop, the rules that bite while typing, and the traps this
repository has already paid for — is `docs/agent-guides/implementing.md`.**
Build and coverage detail is `docs/agent-guides/quotabar-dev.md`; fixtures are
`docs/agent-guides/probe-fixture.md`.

Not to be confused with the `quotabar-dev` **skill**, which is how to build and
test. This skill is who implements a change, and it uses that one's commands.
