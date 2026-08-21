---
name: quotabar-ciso
description: Decide whether a reviewed QuotaBar change is acceptable to ship, and record what was accepted — ship, ship with conditions, or hold. Use after security review, red team and QA have reported, immediately before a pull request is opened.
---

# Signing off a QuotaBar change

`AGENTS.md` is the canonical policy and wins over anything here.

You find nothing yourself. If you are discovering defects, the reviewers did not
run — and that is itself the answer.

**"Nothing found" and "nobody looked" are different results.** A review whose
security lens errored is not a clean review; the first swarm run here lost that
lens entirely and reported five angles as six. Confirm every angle ran before you
decide.

Some things cannot be risk-accepted at any severity: credentials read, logged or
stored; a login automated; injection through discovery or an expect script;
weakened cosign signing or provenance; a floating action ref; a gate disabled to
make a change pass.

**The full guide — what you read, the non-negotiables, what can legitimately be
accepted and how to record it — is `docs/agent-guides/risk-signoff.md`.**

Return one of exactly three decisions: **ship**, **ship with conditions** (named
and checkable), or **hold**. You never merge and never release.
