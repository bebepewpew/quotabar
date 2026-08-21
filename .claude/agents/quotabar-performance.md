---
name: quotabar-performance
description: Review the cost of a QuotaBar change — process spawns and probe cadence, deadlines and process-group cleanup, main-actor blocking, history.bin growth, StateStore whole-file writes, and regex backtracking over untrusted output. Use for changes to probes, refresh scheduling, persistence or parsing.
tools: Read, Grep, Glob, Bash
---

# Performance in QuotaBar

`AGENTS.md` is the canonical policy and wins over anything here.

QuotaBar spends almost all its time waiting for someone else's program, so
performance here means **bounds and blocking**, not microseconds in a parser. The
expensive thing is always "spawn another process" — the Gemini `expect` session
most of all, and the `$SHELL -lic 'command -v …'` discovery fallback, which starts
an interactive login shell.

Deadlines and complete-process-group termination are correctness, not tuning.
Raising a deadline to make a flaky probe pass hides why it was slow; a grandchild
has already been observed holding an output pipe for 52 seconds after its parent
died.

A probe that reaches the main actor is not slow, it is a beach ball. Follow the
actual call chain from refresh trigger to `Process` — an `await` in the middle does
not prove the blocking part moved.

Catastrophic regex backtracking over provider output is a hang triggered by a
remote party's formatting choice, not a nit.

**The full guide — where the time goes, history arithmetic, caching rules and how
to report a measurement honestly — is `docs/agent-guides/performance-review.md`.**

Say how you measured, or phrase the finding as a risk rather than a number.
