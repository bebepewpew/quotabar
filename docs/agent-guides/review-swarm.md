# Reviewing with a swarm

One reviewer has one blind spot. A correctness lens waves through a test that
cannot fail, because an unfalsifiable assertion is not a correctness bug — it is a
*test quality* bug, and nobody was looking for one.

Both kinds have turned up here. Review of the coverage work blocked two tests that
could not fail: a barrier that released on the third *arrival* regardless of
whether the earlier waiters had already left, so a serial implementation satisfied
it; and a path assertion that passed only because `/bin` is a symlink to
`/usr/bin` in the container, and would have gone red on macOS. The swarm's own
first run then found `TrayIconTests.swift:180`, where the test's reader slices a
chunk payload *using* the declared length and then asserts the two are equal.

That run is also worth reading for what it **refuted**. A reviewer claimed the
file's adler32 assertions were tautological. They are not: the encoder's copy is
`private`, so file-scoped, and `@testable` cannot reach it — the test's copy is a
separate implementation, and mutating the encoder does make the assertions fail.
The verifier proved it by simulating the mutation. A swarm that only ever adds
findings is not worth much; refusing a plausible one matters as much.

`.claude/workflows/review-swarm.js` runs six narrow reviewers instead of one broad
one.

```
Workflow: {scriptPath: ".claude/workflows/review-swarm.js", args: {target: "17"}}
Workflow: {scriptPath: ".claude/workflows/review-swarm.js"}          # current branch vs main
```

`target` takes a PR number or a branch name; omit it to review the current branch.

## The lenses

| Lens | Mandate |
| --- | --- |
| `correctness` | logic, edge cases, error paths — via `quotabar-reviewer` |
| `security` | the threat model in `security-review.md` — via `quotabar-security-reviewer` |
| `tests` | do the tests prove what they claim, or are they tautologies |
| `portability` | platform assumptions, unguarded Darwin/Glibc, "not macOS" ≠ "Linux" |
| `compatibility` | storage keys, backward decoding, window keys as identity |
| `docs` | do README/AGENTS/docs still describe the code |

Each is told to report **only** its own angle and that an empty report is a valid
answer, so the lenses do not converge into six copies of the same list.

## Findings are attacked before they are believed

Every finding goes to a second agent whose job is to **refute** it, defaulting to
refuted when uncertain. A wrong finding costs more than a silent reviewer, because
someone acts on it and changes working code. Only what survives is reported, with
severity corrected if it was over- or understated.

The result separates `findings` from `refuted`, so a claim that was already
knocked down is not raised again by the next run.

## Reading the result

`blocking` is true when anything critical or high survived.

**`complete` matters more.** A lens can fail to run at all — the first run lost the
security lens because the agent type had not been registered yet — and an errored
lens must never be reported as one that looked and found nothing. `complete` is
false whenever any lens failed, `lensesThatFailed` names them with the reason, and
the log says how many of the angles were actually covered.

`lensesWithNothing` lists only lenses that **ran** and found nothing — worth
reading, because a lens that always finds nothing is either pointed at the wrong
thing or being ignored. `unverified` holds findings whose refutation step itself
failed; they are surfaced rather than dropped.

That distinction was recorded and then thrown away for a while. The review stage
set `ran: false` on a lens whose agent had errored, but the verification stage
passed on a bare array of verdicts, which a failed lens and a silent one both
leave empty — so `complete` came back `true` and the failed lens was listed in
`lensesWithNothing`. `scripts/test-workflows` now runs this workflow with one
lens's agent forced to reject and asserts the result, so the next such
regression fails the repository-policy CI job rather than reaching a reader as a
clean bill of health.
