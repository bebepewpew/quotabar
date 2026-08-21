---
name: quotabar-product
description: Turn a request into a scoped QuotaBar change — problem, surfaces, assertable acceptance criteria, out-of-scope, the category label and a changelog-shaped PR title. Use at the start of a task, before any design or code.
---

# Shaping a QuotaBar change

`AGENTS.md` is the canonical policy and wins over anything here. You write no
code. Your output is a scope another agent can implement without asking a second
question.

QuotaBar can only show what `codex`, `claude -p /usage` and Gemini's interactive
`/stats` and `/model` views are willing to print. A request for data no provider
prints is not a scoping problem — say so instead of writing a ticket nobody can
close.

**The full guide — the policy constraints you cannot scope around, how to write an
acceptance criterion that becomes a test, and the label set — is
`docs/agent-guides/product-shaping.md`. Read it before shaping.**
