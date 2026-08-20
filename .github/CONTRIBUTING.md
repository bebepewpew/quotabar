# Contributing to QuotaBar

All changes, including maintainer changes, go through pull requests.

1. Run `scripts/install-hooks` once after cloning. If you use Codex, also
   run `scripts/install-codex-skills` — Codex only loads skills from
   `$CODEX_HOME/skills`, never from the repository.
2. Update `main`, then create a focused branch such as `fix/gemini-timeout` or
   `feature/custom-badges`.
3. Make the change and add proportionate tests.
4. Run `./quotabar build`, `./quotabar test`, and `git diff --check`.
5. Push the branch and open a pull request using the repository template.
6. After required CI passes and all conversations are resolved, use **Squash and
   merge**. Merge commits and rebase merges are disabled.

The local hooks provide fast feedback, but GitHub branch protection and CI are
authoritative. See [AGENTS.md](../AGENTS.md) for architecture, safety, and
testing rules that apply to both human and AI contributors.
