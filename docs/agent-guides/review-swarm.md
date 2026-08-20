# Reviewing with a swarm

One reviewer has one blind spot. The correctness lens waves through a test that
asserts a function against a copy of its own algorithm, because that is not a
correctness bug — it is a *test quality* bug, and nobody was looking for it. That
happened here: a self-referential adler32 assertion was marked non-blocking and
merged.

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

`blocking` is true when anything critical or high survived. `lensesWithNothing`
lists the angles that found nothing — worth reading, because a lens that *always*
finds nothing is either pointing at the wrong thing or being ignored.
