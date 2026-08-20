# QuotaBar Contributor Rules

This file is the canonical instruction source for humans and AI coding agents.
`CLAUDE.md` and `GEMINI.md` point here; keep detailed policy in this file only.

## Project

QuotaBar is a native macOS 14+ menu-bar application written in Swift 6. It reads
quota data from locally installed Codex, Claude Code, and Gemini CLIs. It must
not read, copy, log, or store provider credentials or complete login prompts.

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
- Keep all external processes bounded by deadlines and terminate their complete
  process groups. Preserve cached quota values when a refresh fails.
- Treat CLI output as untrusted: normalize terminal controls, clamp percentages,
  and return concise actionable errors without exposing raw sensitive output.
- Keep UI and observable state on the main actor; do blocking CLI work off the
  cooperative executor.
- Maintain backward-compatible decoding for persisted `UserDefaults` payloads.
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

`./quotabar test` requires full Xcode. If it is unavailable, state that clearly;
GitHub Actions remains the required test authority. Never claim tests passed when
they were not executed.

Parser changes require fixtures for boundaries, malformed data, terminal redraws,
and every supported row form. Process changes require timeout, authentication,
and cleanup coverage where practical. UI threshold changes require exact boundary
tests.

## Repository hygiene

- `README.md` describes current behavior and supported requirements.
- `REVIEW.md` is a local/generated report and must not be committed.
- App icons belong in `Resources`; `.icns` and source icon assets are intentional.
- Use `scripts/install-hooks` once per clone to enable the repository hooks.
