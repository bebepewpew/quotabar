---
name: quotabar-security-review
description: Review QuotaBar changes for security against the threat model in docs/agent-guides/security-review.md — binary discovery and PATH, Tcl and shell construction, untrusted CLI output, credential handling, child-process lifetime, XDG state and the release supply chain. Use before merging anything that touches process execution, parsing, persistence or CI.
---

# Security review

`AGENTS.md` is the canonical policy and wins over anything here.

QuotaBar discovers and executes other people's binaries, builds a Tcl script by
interpolation, and parses untrusted terminal output. Generic checklists miss all
three.

**The full threat model and the ranking scale are in
`docs/agent-guides/security-review.md`. Read it before reviewing.**

Report only what you can point at in the diff, name the concrete attack, and give
the smallest fix. "I found nothing in this area" is a valid finding.
