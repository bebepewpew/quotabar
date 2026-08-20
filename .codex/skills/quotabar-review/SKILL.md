---
name: quotabar-review
description: Review QuotaBar changes against the AGENTS.md contributor rules — process cleanup, credential safety, untrusted CLI output, persistence compatibility and fixture coverage. Use before opening or updating a pull request.
---

# Reviewing a QuotaBar change

`AGENTS.md` is the canonical policy and wins over anything here. Report only
what you can point at in the diff: file, line, the concrete failure it causes,
and the smallest fix. Never claim a suite passed unless you ran it.

**The full checklist — process cleanup, credentials, untrusted output,
concurrency, persistence, identity, portability, coverage — is
`docs/agent-guides/review-checklist.md`. Read it before reviewing.**
