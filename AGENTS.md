# QuotaBar Contributor Rules

This file is the canonical instruction source for humans and AI coding agents.
`CLAUDE.md` and `GEMINI.md` point here; keep detailed policy in this file only.

## Project

QuotaBar is written in Swift 6 and split into three targets. `QuotaCore` is a
cross-platform library holding the probes, provider discovery, caching, and
threshold alerts. `QuotaBar` is the native macOS 14+ menu-bar app. `QuotaBarCLI`
builds the `quotabar` command on macOS and Linux. It reads quota data from
locally installed Codex, Claude Code, and Gemini CLIs. It must not read, copy,
log, or store provider credentials or complete login prompts.

## Required workflow

- Never commit or push directly to `main`. Create a focused branch and open a
  pull request for every change.
- Merge pull requests with **Squash and merge** only. Keep the PR title concise
  and imperative because it becomes the commit subject on `main` and the
  changelog line in the release notes.
- Label every pull request with exactly one category label, applied when the
  pull request is opened: `feature`, `fix`, `security`, `performance`,
  `tooling`, `ci`, `documentation`, `docs`, `dependencies`, or
  `skip changelog`. The `Labels` CI job fails a pull request that carries none
  of them or more than one.
- Preserve unrelated and pre-existing working-tree changes. Do not rewrite,
  delete, or stage them.
- Keep commits focused and use imperative commit subjects.
- Update tests and documentation when behavior or user-facing interfaces change.
- Do not commit `.build`, credentials, terminal captures containing personal
  data, generated review reports, or other local artifacts.
- Do not weaken CI, hooks, or branch protection to make a change pass.

### Release notes

Release notes are generated from merged pull requests and grouped by label, as
`.github/release.yml` configures. Give every pull request exactly one category
label from the table in `.github/CONTRIBUTING.md`; an unlabelled one still
appears, under the catch-all Other section. Because the repository squash-merges,
the pull-request title is the changelog line — write it for someone reading the
release, not for the branch.

## Implementation constraints

- Prefer public, documented CLI interfaces. Gemini quota collection must remain
  terminal-only and use interactive `/stats`, never private JavaScript modules.
  Codex uses `app-server --stdio` over pipes and Claude Code uses `-p /usage`;
  neither should acquire a pseudo-terminal dependency.
- Keep all external processes bounded by deadlines and terminate their complete
  process groups. Preserve cached quota values when a refresh fails.
- Treat CLI output as untrusted: normalize terminal controls, clamp percentages,
  and return concise actionable errors without exposing raw sensitive output.
- Keep UI and observable state on the main actor; do blocking CLI work off the
  cooperative executor.
- Persist settings and small state through `StateStore`: `UserDefaults` on macOS,
  an XDG JSON file on Linux. Keep storage keys stable and decoding backward
  compatible.
- Persist usage history through `HistoryStore` instead. It is a second seam, not
  a bypass: `StateStore` rewrites its whole file on every write, which is the
  wrong shape for an append-only series that has to retain three months. The log
  is `history.bin` under `~/Library/Application Support/QuotaBar` on macOS,
  `${XDG_STATE_HOME:-~/.local/state}/quotabar` on Linux — history is state, not
  configuration. Its series catalogue still goes through `StateStore`.
- Keep the history format backward compatible the same way storage keys are kept
  stable. The header carries a version and a record stride; a file written by a
  newer build is read as far as it can be and **never appended to or deleted**,
  and a file that is not ours is left alone rather than replaced.
- Recording history is best effort. A history file that cannot be written or is
  damaged must never turn a working quota refresh into a failure — read paths
  report what they skipped, write paths stay silent.
- Use stable quota-window keys; labels and reset timestamps are display data,
  not identity. History is keyed on the window key for the same reason.

## Validation

Run the smallest relevant checks during development and all of these before a PR
is ready:

```sh
./quotabar build
./quotabar test
git diff --check
```

`./quotabar coverage` runs the same suite with instrumentation and prints a
per-file report; `--lcov <path>` also writes an lcov file, and anything else is
forwarded to `swift test`, so `--filter QuotaCore` still works. It measures
`QuotaCore` and `QuotaTray` — the library targets the test binary links — and
not the CLI or the macOS app, which are separate executables the tests do not
link. Use it when adding or changing tests, to see what a change actually
covers. It is not a merge gate; the three commands above are. Go through the
wrapper rather than `scripts/coverage` directly: without a local toolchain the
wrapper runs the script inside the container that produced the profile.

Coverage is enforced: the Linux CI job fails below 90% region. The threshold
was switched on only once the suite cleared it — 95.18% region and 98.27% line
at the time — so it has never been a gate main could not pass. Raise it when the
code genuinely supports a higher number; do not exclude files to reach one.

On macOS `./quotabar test` and `./quotabar coverage` use full Xcode when it is
installed, and that is the only way to cover the menu-bar app. Without it they
fall back to the upstream Swift container, exactly as Linux without a toolchain
does — the wrapper says so before it starts, because that path covers
`QuotaCore`, `QuotaTray` and the CLI and cannot build the app target at all.
With neither full Xcode nor docker they still refuse, with exit code 2. On Linux
the suite runs natively when Swift is installed, in the container otherwise.
If a suite cannot be executed, state that clearly, and say which path ran when
one did: GitHub Actions remains the required test authority across both
platforms, and a container run on macOS is not a result for the app. Never claim
tests passed when they were not executed.

`scripts/wrapper-tests` checks that selection itself — which toolchain the
wrapper picks per platform, and what it refuses — with a stubbed `uname` and
`docker`, so it needs neither. The `Repository policy` CI job runs it.

Parser changes require fixtures for boundaries, malformed data, terminal redraws,
and every supported row form. Process changes require timeout, authentication,
and cleanup coverage where practical. UI threshold changes require exact boundary
tests.

## Agent tooling

The guidance lives once, in `docs/agent-guides/`. Everything else — every skill,
agent and workflow, in both toolchains — is a thin wrapper pointing at one of
these, the same way `CLAUDE.md` and `GEMINI.md` point here instead of restating
policy.

**Doing the work**

- `product-shaping.md` — turning a request into a scope with assertable
  acceptance criteria, and refusing one no provider CLI can supply.
- `architecture-review.md` — which target a change belongs in, which persistence
  seam, and the compatibility story that comes with it.
- `implementing.md` — the loop from branch to pushed branch, and the traps this
  repository has already paid for.
- `quotabar-dev.md` — build, test and pre-PR validation, including the Linux
  container path and the platform facts that are easy to get wrong.
- `probe-fixture.md` — what a parser change must cover, and the parsing traps
  this repository has already hit.
- `qa-plan.md` — what each kind of change owes in tests, and how to prove a test
  can actually fail.
- `backlog.md` — filing an issue nobody is building yet, and answering one that
  arrives: the templates, the labels, and the five outcomes triage can reach.

**Checking the work**

- `review-checklist.md` — how a change is reviewed against this file.
- `security-review.md` — the threat model: binary discovery, script
  construction, untrusted CLI output, credentials, process lifetime, supply chain.
- `red-team.md` — the attacks to actually build and run against those surfaces.
- `ux-review.md` — the visible surface: legibility, a non-colour signal for every
  state, error and empty states, `--json` and waybar as an interface.
- `performance-review.md` — process spawns, deadlines, main-actor blocking,
  history growth, backtracking over untrusted output.
- `ci-and-delivery.md` — the four workflows, what each is authoritative for, and
  the pinning and permission rules.
- `docs-writing.md` — where each document lives, and what goes stale.
- `harness-review.md` — reviewing the harness itself: the guides, the wrappers,
  the workflows and the allowlist, where a defect fails silently rather than red.
- `risk-signoff.md` — deciding that what is now known is acceptable to ship, and
  recording what was accepted.
- `release.md` — cutting and verifying a release.

**Running several agents at once**

- `review-swarm.md` — reviewing through six narrow lenses instead of one broad one.
- `parallel-tasks.md` — running independent tasks at once in separate
  worktrees, one pull request per task.
- `e2e-task.md` — one task from scope to an open pull request: shape, design,
  build, assure from every angle, remediate what survives refutation, sign off.

The wrappers:

- `.claude/skills/` — `quotabar-dev` and `quotabar-fixtures`. Claude Code reads
  these from the repository.
- `.claude/agents/` — one per role: `quotabar-pm`, `quotabar-product`,
  `quotabar-architect`, `quotabar-developer`, `quotabar-qa`, `quotabar-reviewer`,
  `quotabar-security-reviewer`, `quotabar-harness-reviewer`, `quotabar-red-team`,
  `quotabar-ux`, `quotabar-performance`, `quotabar-devops`, `quotabar-writer`,
  `quotabar-ciso` and `quotabar-release`. Each is usable on its own; the
  workflows only decide the order they run in.
- `.claude/workflows/review-swarm.js` — six-lens review with adversarial
  verification of every finding. Use it before merging anything substantial.
- `.claude/workflows/e2e-task.js` — the full line for a single task, with the
  same adversarial verification and a sign-off that treats an angle which failed
  to run as a reason to hold rather than a clean result.
- `.claude/workflows/parallel-tasks.js` and `scripts/codex-parallel` — the
  parallel runners for each toolchain. Both open a pull request only for a
  task that passed the validation above.
- `scripts/test-workflows` — the two workflows above, run against a stub engine.
  It needs Node and nothing else, and the repository-policy CI job runs it for
  every change. It pins the one behaviour whose failure is invisible: an angle
  whose agent errored is reported as one that did not run, never as one that
  looked and found nothing. Run it after editing either workflow.
- `.codex/skills/` — the same roles with `agents/openai.yaml` manifests. Codex
  discovers skills only under `$CODEX_HOME/skills` and does not read them from a
  repository, so run `scripts/install-codex-skills` once per clone and again
  after pulling changes to them. It also removes the skills it installed that the
  repository no longer has, so a renamed role stops being offered under both
  names; a skill it did not install is never touched. A role is spelled the same
  in `.claude/agents/` and `.codex/skills/`. Codex reads `AGENTS.md` natively,
  which is why there is no `CODEX.md`. Codex has no workflow engine, so the
  multi-agent runners above have no Codex equivalent beyond
  `scripts/codex-parallel`.

`quotabar-dev` is the build-and-test **skill**; `quotabar-developer` is the agent
that implements a change and uses it. Keep the two straight when adding either.
`quotabar-pm` and `quotabar-product` divide the same way: the first owns the
backlog — filing what nobody is building yet and answering what arrives — and the
second scopes a change that is about to be built.

`.claude/settings.json` allows `./quotabar build|test|cli` and no raw
`swift build`, `swift test` or `docker run ...` at all, deliberately: the wrapper
selects the right toolchain, keeps `.build` owned by the invoking user, and on
macOS refuses a suite that only Command Line Tools could run. A bare `swift test`
skips that refusal and reports green for a run the wrapper declined, so an
allowlist entry for it is an unprompted bypass for every agent, forever. The only
`swift` entries left are `swift run quotabar ...`, which runs the built CLI rather
than the gate; the `Repository policy` job in `ci.yml` fails if a `swift build` or
`swift test` entry comes back. The deny entries for pushes to `main` are a speed
bump only; `.githooks/pre-push` and branch protection are the enforcement.

These describe the rules; they do not replace them. This file stays canonical.

## Repository hygiene

- `README.md` describes current behavior and supported requirements.
- Contributor and security policy live in `.github/CONTRIBUTING.md` and
  `.github/SECURITY.md`. GitHub surfaces both from there, so the repository
  root stays short; link to those paths rather than the old root ones.
- Issues are filed through `.github/ISSUE_TEMPLATE/` — `bug_report.yml`,
  `feature_request.yml` and `task.yml` for a scoped backlog item. Blank issues
  are off, so every entry arrives with its fields; `docs/agent-guides/backlog.md`
  covers filing one non-interactively and answering one that arrives. A
  vulnerability is never a public issue.
- `REVIEW.md` is a local/generated report and must not be committed.
- App icons belong in `Resources`; `.icns` and source icon assets are intentional.
- Use `scripts/install-hooks` once per clone to enable the repository hooks.
