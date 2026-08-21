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

## Filing an issue

Blank issues are turned off, so every entry arrives with the fields the next
reader needs. Pick the template that matches what you have:

| Template | Use it for |
| --- | --- |
| **Bug report** | QuotaBar reads a quota wrong, shows the wrong thing, or fails where it should not |
| **Feature request** | Something QuotaBar should show or do that it does not today |
| **Backlog item** | Work already scoped — problem, surfaces, assertable acceptance criteria, out of scope, the category label |

Two things before you post. **Search closed issues too**: the answer is often
that this was decided already. And **redact** — no tokens, account identifiers,
home-directory paths, or terminal captures containing personal data, the same
rule that keeps them out of commits.

A vulnerability never goes in a public issue. Report it privately through a
GitHub security advisory; [`SECURITY.md`](SECURITY.md) has the process.

AI agents file and answer issues through
[`docs/agent-guides/backlog.md`](../docs/agent-guides/backlog.md), which covers
the non-interactive `gh issue create` invocation and what a reply may not claim.

## Pull-request labels

A release's notes are generated from the merged pull requests, and
[`release.yml`](release.yml) sorts them into sections by label. Because the
repository squash-merges, one pull request is one changelog line and the pull
request's title is that line — so give every pull request exactly one category
label and a title worth reading in a release.

These labels are not created automatically. A maintainer adds them once per
repository under **Issues → Labels**; the colours are suggestions that keep the
list readable, not requirements.

| Label | Colour | Release-notes section |
| --- | --- | --- |
| `feature` | `#0e8a16` | Added |
| `fix` | `#d73a4a` | Fixed |
| `security` | `#b60205` | Security |
| `performance` | `#fbca04` | Performance |
| `tooling` | `#5319e7` | Tooling |
| `ci` | `#5319e7` | Tooling |
| `documentation` | `#0075ca` | Documentation |
| `docs` | `#0075ca` | Documentation |
| `dependencies` | `#0366d6` | Dependencies |
| `skip changelog` | `#cfd3d7` | none — the pull request is left out entirely |

An issue carries the same category label the pull request that closes it will
carry, so the backlog sorts the way the release notes do. Triage adds two labels
that never reach a pull request:

| Label | Colour | Means |
| --- | --- | --- |
| `needs-info` | `#d4c5f9` | One fact is missing and has been asked for. Closed if it never arrives |
| `provider-limited` | `#c2e0c6` | Not buildable until a provider CLI prints the data. Nothing on our side unblocks it |

Like the category labels, a maintainer creates these once under **Issues →
Labels**.

`documentation` and `dependencies` already exist in most repositories:
GitHub creates the first with a new repository and Dependabot applies the second
to its own pull requests, so leave both spelled exactly as they are.

An unlabelled pull request is not dropped — it lands in the catch-all **Other**
section. That is a safety net rather than a destination: a change that reaches a
release under Other is a change nobody categorised.

Adding a category to [`release.yml`](release.yml) means adding its label here in
the same pull request. A category whose label nobody applies renders an empty
section in every release from then on.
