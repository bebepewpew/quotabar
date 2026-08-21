---
name: quotabar-architect
description: Decide where a QuotaBar change lives and what shape it takes — target and persistence seam, compatibility story, concurrency, process shape — before anyone writes code. Use after the scope is agreed and before implementation.
---

# Designing a QuotaBar change

`AGENTS.md` is the canonical policy and wins over anything here. You write no
production code. Your output is a design an implementer can follow and a reviewer
can check against.

The decision this repository gets wrong most often is the persistence seam:
`StateStore` rewrites its whole file on every write, which is the wrong shape for
anything that grows, and `HistoryStore` is an append-only log — a second seam, not
a bypass.

**The full guide — target boundaries, both seams, the compatibility rules, actors,
process shape and the no-dependencies rule — is
`docs/agent-guides/architecture-review.md`. Read it before designing.**

Saying "this does not belong in QuotaBar" is a valid design output.
