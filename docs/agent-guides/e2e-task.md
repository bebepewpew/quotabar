# Taking one task end to end

`review-swarm` reviews a branch that already exists. `parallel-tasks` runs several
changes at once and reviews each with one reviewer. Neither covers the part before
the first edit — deciding whether the change is buildable at all, and where it
belongs — or the part after review, where somebody has to decide that what is now
known is acceptable to ship.

`.claude/workflows/e2e-task.js` runs the whole line.

```
Workflow: {scriptPath: ".claude/workflows/e2e-task.js", args: {request: "warn before a weekly window runs out early"}}
Workflow: {scriptPath: ".claude/workflows/e2e-task.js", args: {request: "...", publish: false, maxRemediation: 1}}
```

Resolving it by name only works in a session that started after the file existed —
the workflow registry is built at startup. In the session that adds or moves it,
pass the path.

| Argument | Default | Effect |
| --- | --- | --- |
| `request` | required | what to build, in plain words. A bare string works too |
| `publish` | `true` | `false` stops after sign-off with the branch pushed and no pull request |
| `maxRemediation` | `2` | how many fix-and-recheck rounds before it stops trying |

## The roster

Each role is a thin wrapper in `.claude/agents/` over one guide in
`docs/agent-guides/`, the same way `CLAUDE.md` points at `AGENTS.md`. They are all
usable on their own; the workflow is just the order they run in.

| Agent | Guide | Owns |
| --- | --- | --- |
| `quotabar-product` | `product-shaping.md` | scope, assertable acceptance criteria, the category label |
| `quotabar-architect` | `architecture-review.md` | target and persistence seam, compatibility, concurrency |
| `quotabar-developer` | `implementing.md` | the change, the tests, the gate, the pushed branch |
| `quotabar-reviewer` | `review-checklist.md` | correctness against the contributor rules |
| `quotabar-security-reviewer` | `security-review.md` | the threat model |
| `quotabar-qa` | `qa-plan.md` | whether the tests would notice a regression |
| `quotabar-red-team` | `red-team.md` | building the hostile input and running it |
| `quotabar-ux` | `ux-review.md` | what a person actually sees, and can distinguish |
| `quotabar-performance` | `performance-review.md` | process spawns, blocking, deadlines, growth |
| `quotabar-devops` | `ci-and-delivery.md` | the workflows, the gates, which job catches what |
| `quotabar-writer` | `docs-writing.md` | documentation that is still true |
| `quotabar-ciso` | `risk-signoff.md` | ship, ship with conditions, or hold |
| `quotabar-release` | `release.md` | cutting and verifying a release |

`quotabar-release` is deliberately **not** in the pipeline. A release is a manual
`workflow_dispatch` act over a set of merged changes, not the tail of one of them.

## The phases

**Shape** — the product role scopes it, or refuses it. QuotaBar can only show what
the local provider CLIs print, so a request for data none of them prints ends here
with `state: "specRejected"` and a reason. That is a success, not a failure.

**Design** — the architect picks the target and the seam and writes the
compatibility story. It can also return `viable: false`, which ends the run as
`designRejected`.

**Build** — one developer owns the change from the first edit to a pushed branch,
in its own worktree. It is deliberately not split across stages: a later agent gets
a different worktree and would not see work that was never pushed. If the gate does
not pass, the run stops at `gateFailed` with the branch, if one was pushed.

**Assure** — eight narrow angles read the pushed branch at once. Narrow on purpose:
a generalist waves through a test that cannot fail, because that is not a
correctness bug, and waves through an unreadable icon, because that is not a bug at
all. Two of the angles — tests and attack — get their own worktree so they can
check the branch out and actually run what they write; the other six read the diff.

**Verify** — every finding goes to a second agent whose job is to **refute** it,
defaulting to refuted when uncertain. A wrong finding costs more than a silent
reviewer, because someone acts on it and changes working code. Only what survives
is carried forward, with the severity corrected if it was over- or understated.

**Remediate** — if anything critical or high survived, the developer checks the
branch out fresh, fixes only those, adds a test that would have caught each, re-runs
the gate and pushes. Then **only the angles that raised something blocking** run
again — the others are reading a diff that has not changed in the way they care
about. Up to `maxRemediation` rounds. A reasoned refusal to fix a finding is a valid
outcome and is carried into sign-off rather than silently dropped.

**Sign-off** — the CISO decides. It finds nothing itself: if it is discovering
defects, the reviewers did not run. It returns `ship`, `conditions` (each one named
and checkable) or `hold`, plus the risks it accepted and what would change each
answer.

**Ship** — the pull request is opened with the title the product role wrote as a
changelog line and exactly one category label, the template checklists filled in
from what was actually reported, and the whole review history in Notes. It never
merges.

## Reading the result

`state` is one of:

| State | Meaning |
| --- | --- |
| `opened` | signed off and the pull request is open |
| `openedWithConditions` | open, and the sign-off named conditions to meet before merging |
| `awaitingPublish` | **the work is finished and pushed** — only opening the PR failed, or `publish: false`. Do not re-run it |
| `held` | sign-off said hold. The branch exists; nothing was opened |
| `gateFailed` | build, tests or `git diff --check` did not pass |
| `buildFailed` | nothing was pushed |
| `designRejected` / `specRejected` | it stopped before any code, with a reason |

**`complete` matters more than `blocking`.** An angle can fail to run at all, and an
errored angle must never be reported as one that looked and found nothing —
`review-swarm`'s first run lost its security lens entirely because the agent type
had not been registered, and reported five angles as six. `complete` is false
whenever any angle failed, `anglesThatFailed` names them with the reason, and the
sign-off treats it as a reason to hold.

`anglesWithNothing` lists angles that **ran** and found nothing. Worth reading: an
angle that always finds nothing is either pointed at the wrong thing or being
ignored.

`refuted` is kept so a claim that was already knocked down is not raised again by
the next run, and `unverified` holds findings whose refutation step itself failed —
surfaced rather than dropped.

## When not to use it

- A one-line fix. The pipeline costs more than the change.
- Two unrelated changes — `docs/agent-guides/parallel-tasks.md` runs those at once,
  and this one is deliberately single-threaded through a single branch.
- A branch that already exists and only needs reviewing —
  `docs/agent-guides/review-swarm.md`.
