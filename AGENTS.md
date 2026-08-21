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
  and imperative because it becomes the commit subject on `main`.
- Preserve unrelated and pre-existing working-tree changes. Do not rewrite,
  delete, or stage them.
- Keep commits focused and use imperative commit subjects.
- Update tests and documentation when behavior or user-facing interfaces change.
- Do not commit `.build`, credentials, terminal captures containing personal
  data, generated review reports, or other local artifacts.
- Do not weaken CI, hooks, or branch protection to make a change pass.

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
wrapper rather than `scripts/coverage` directly: on Linux without a toolchain
the wrapper runs the script inside the container that produced the profile.

Coverage is enforced: the Linux CI job fails below 90% region. The threshold
was switched on only once the suite cleared it — 95.18% region and 98.27% line
at the time — so it has never been a gate main could not pass. Raise it when the
code genuinely supports a higher number; do not exclude files to reach one.

On macOS `./quotabar test` requires full Xcode. On Linux it runs natively, or in
the upstream Swift container when no toolchain is installed, and covers
`QuotaCore` and the CLI but not the macOS app. If a suite cannot be executed,
state that clearly; GitHub Actions remains the required test authority across
both platforms. Never claim tests passed when they were not executed.

Parser changes require fixtures for boundaries, malformed data, terminal redraws,
and every supported row form. Process changes require timeout, authentication,
and cleanup coverage where practical. UI threshold changes require exact boundary
tests.

## Agent tooling

The guidance lives once, in `docs/agent-guides/`:

- `quotabar-dev.md` — build, test and pre-PR validation, including the Linux
  container path and the platform facts that are easy to get wrong.
- `probe-fixture.md` — what a parser change must cover, and the parsing traps
  this repository has already hit.
- `review-checklist.md` — how a change is reviewed against this file.
- `security-review.md` — the threat model: binary discovery, script
  construction, untrusted CLI output, credentials, process lifetime, supply chain.
- `review-swarm.md` — reviewing through six narrow lenses instead of one broad one.
- `parallel-tasks.md` — running independent tasks at once in separate
  worktrees, one pull request per task.

Each tool gets a thin wrapper pointing at those, the same way `CLAUDE.md` and
`GEMINI.md` point here instead of restating policy:

- `.claude/` — `settings.json`, `skills/quotabar-dev`, `skills/quotabar-fixtures`
  and `agents/quotabar-reviewer`. Claude Code reads these from the repository.
- `.claude/workflows/review-swarm.js` — six-lens review with adversarial
  verification of every finding. Use it before merging anything substantial.
- `.claude/workflows/parallel-tasks.js` and `scripts/codex-parallel` — the
  parallel runners for each toolchain. Both open a pull request only for a
  task that passed the validation above.
- `.codex/skills/` — the same three with `agents/openai.yaml` manifests. Codex
  discovers skills only under `$CODEX_HOME/skills` and does not read them from a
  repository, so run `scripts/install-codex-skills` once per clone and again
  after pulling changes to them. Codex reads `AGENTS.md` natively, which is why
  there is no `CODEX.md`.

`.claude/settings.json` allows `./quotabar ...` rather than raw `docker run ...`
deliberately: the wrapper selects the right toolchain and keeps `.build` owned by
the invoking user. Its deny entries for pushes to `main` are a speed bump only;
`.githooks/pre-push` and branch protection are the enforcement.

These describe the rules; they do not replace them. This file stays canonical.

## Repository hygiene

- `README.md` describes current behavior and supported requirements.
- Contributor and security policy live in `.github/CONTRIBUTING.md` and
  `.github/SECURITY.md`. GitHub surfaces both from there, so the repository
  root stays short; link to those paths rather than the old root ones.
- `REVIEW.md` is a local/generated report and must not be committed.
- App icons belong in `Resources`; `.icns` and source icon assets are intentional.
- Use `scripts/install-hooks` once per clone to enable the repository hooks.
