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
- Persist through `StateStore`: `UserDefaults` on macOS, an XDG JSON file on
  Linux. Keep storage keys stable and decoding backward compatible.
- Use stable quota-window keys; labels and reset timestamps are display data,
  not identity.

## Validation

Run the smallest relevant checks during development and all of these before a PR
is ready:

```sh
./quotabar build
./quotabar test
git diff --check
```

On macOS `./quotabar test` requires full Xcode. On Linux it runs natively, or in
the upstream Swift container when no toolchain is installed, and covers
`QuotaCore` and the CLI but not the macOS app. If a suite cannot be executed,
state that clearly; GitHub Actions remains the required test authority across
both platforms. Never claim tests passed when they were not executed.

Parser changes require fixtures for boundaries, malformed data, terminal redraws,
and every supported row form. Process changes require timeout, authentication,
and cleanup coverage where practical. UI threshold changes require exact boundary
tests.

## Repository hygiene

- `README.md` describes current behavior and supported requirements.
- `REVIEW.md` is a local/generated report and must not be committed.
- App icons belong in `Resources`; `.icns` and source icon assets are intentional.
- Use `scripts/install-hooks` once per clone to enable the repository hooks.
