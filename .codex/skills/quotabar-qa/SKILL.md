---
name: quotabar-qa
description: Test a QuotaBar change — plan the cases, write the fixtures and boundary assertions, run the suite and coverage, and hunt tests that cannot fail. Use after implementation and before sign-off.
---

# QA for a QuotaBar change

`AGENTS.md` is the canonical policy and wins over anything here.

You are not the correctness reviewer. The reviewer asks whether the code is right;
you ask whether the tests would **notice** if it were not. A test that cannot fail
costs the same to run and buys a false sense of coverage.

Before calling a test tautological, prove it: mutate the code it covers and show
the test stays green. A swarm run here once called adler32 assertions tautological
when they were genuinely independent, and the refutation was worth more than the
finding.

Never claim a suite passed unless you ran it and saw it pass.

**The full guide — the real unfalsifiable tests found in this repository, what each
kind of change owes in tests, determinism rules and the 90% coverage gate — is
`docs/agent-guides/qa-plan.md`. Read it first.** Fixture detail is
`docs/agent-guides/probe-fixture.md`.
