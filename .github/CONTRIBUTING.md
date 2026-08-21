# Contributing to QuotaBar

QuotaBar reads quota figures out of the AI coding CLIs already installed on your
machine and shows them in a macOS menu bar or a terminal. Bug reports, provider
output that the parsers get wrong, and focused pull requests are all welcome —
this is a small project, so a clear issue is worth as much as a patch.

Everything below applies to human and AI contributors alike. All changes,
including maintainer changes, go through pull requests.

## Code of Conduct

This project ships the [Contributor Covenant](CODE_OF_CONDUCT.md) and expects
everyone taking part to follow it. Report unacceptable behaviour to
borisiuk.eugene@gmail.com.

## Reporting a bug

**Never report a security vulnerability in a public issue.** QuotaBar executes
authenticated provider CLIs on your machine, so anything that could cause
credentials to be read, logged or transmitted, any command or script injection
through binary discovery or the `expect` script, and any leaked or unbounded
child process goes privately through GitHub security advisories instead. The
scope, the threat model and the reporting link are in
[SECURITY.md](SECURITY.md).

For everything else, open a
[bug report](https://github.com/bebepewpew/quotabar/issues/new?template=bug_report.yml).
The form asks for the provider CLI involved, your OS and version,
`quotabar --version`, and the output of `quotabar --json`, because a quota bug is
almost always a provider's output that a parser did not expect, and that output
is the only thing that reproduces it.

Two things first:

- Check the [troubleshooting table](../README.md#troubleshooting) in the README.
  A missing `expect`, an unanswered Gemini folder-trust prompt, or a withdrawn
  Gemini Code Assist tier are reported deliberately and are not bugs.
- **Redact before you paste.** QuotaBar output carries account state — plans,
  usage, reset times — and pasting it into a public issue publishes it. Remove
  anything you would not put on the front page. The bug form makes you confirm
  this, and this repository does not accept personal terminal captures in
  commits either.

## Proposing a change

Open a
[feature request](https://github.com/bebepewpew/quotabar/issues/new?template=feature_request.yml)
before writing anything larger than a small fix, so the design can be agreed
before you spend the time. Describe the problem you hit rather than the patch
you already have in mind.

Two constraints shape what is acceptable, and both are non-negotiable:

- QuotaBar uses public, documented CLI interfaces only. Gemini quota collection
  stays terminal-only through the interactive `/stats` view; Codex uses
  `app-server --stdio` over pipes and Claude Code uses `-p /usage`. No private
  JavaScript modules, no new pseudo-terminal dependencies for those two.
- QuotaBar never reads, copies, logs or stores provider credentials and never
  completes a login prompt. Authentication stays inside each vendor's CLI.

[AGENTS.md](../AGENTS.md) carries the rest: process lifetime, untrusted output
handling, persistence compatibility, and the fixture rules a parser change has
to satisfy. Read it before you start.

Work that has already been through that discussion goes in as a
[backlog item](https://github.com/bebepewpew/quotabar/issues/new?template=task.yml)
instead: problem, surfaces, assertable acceptance criteria, out of scope, and the
one category label the closing pull request will carry. AI agents file and answer
issues through [`docs/agent-guides/backlog.md`](../docs/agent-guides/backlog.md),
which has the non-interactive `gh issue create` invocation and what a reply may
not claim.

## Development environment

[docs/development.md](../docs/development.md) has the build, run and test
instructions for both platforms, including the container path for Linux hosts
without a Swift toolchain.

Two things to do once per clone:

```sh
scripts/install-hooks         # enable the repository hooks
scripts/install-codex-skills  # Codex users only
```

Codex loads skills only from `$CODEX_HOME/skills`, never from a repository, so
run the second script again after pulling changes to `.codex/skills/`.

Then run these three before every pull request, and do not push past a failure:

```sh
./quotabar build
./quotabar test
git diff --check
```

The local hooks give fast feedback, but GitHub branch protection and CI are
authoritative. On macOS `./quotabar test` needs full Xcode; if you cannot run the
suite locally, say so in the pull request rather than implying it passed.

## Pull-request process

1. Update `main`, then create a focused branch such as `fix/gemini-timeout` or
   `feature/custom-badges`.
2. Make the change, and keep it to one thing. Unrelated and pre-existing
   working-tree changes stay untouched.
3. Add proportionate tests. A parser change needs fixtures for boundaries,
   malformed data, terminal redraws and every supported row form; a process
   change needs timeout, authentication and cleanup coverage. Update the
   documentation when user-facing behaviour moves.
4. Run `./quotabar build`, `./quotabar test` and `git diff --check`.
5. Push the branch and open a pull request using the repository template, with
   an imperative title. The repository squash-merges, so that title becomes the
   commit subject on `main` **and** the changelog line in the release notes —
   write it for someone reading the release, not for the branch.
6. Apply exactly one category label from the table below. `Labels` is a required
   status check, so a pull request carrying none of them, or more than one,
   cannot be merged until the labels are corrected. The check re-runs as soon as
   a label changes; you do not need to push again.
7. Once the required checks pass and every conversation is resolved, merge with
   **Squash and merge**. Merge commits and rebase merges are disabled.

Do not weaken CI, hooks or branch protection to make a change pass.

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

An unlabelled pull request is not dropped from the notes — it lands in the
catch-all **Other** section. That is a safety net rather than a destination: a
change that reaches a release under Other is a change nobody categorised. It is
also not a way around the `Labels` check, which still blocks the merge.

The issue forms apply `fix` and `feature` to the issue. That is a hint about
where the change belongs, not a head start on the pull request: GitHub does not
carry an issue's labels across to the pull request that closes it. Label the
pull request yourself, or the `Labels` check fails it.

Adding a category to [`release.yml`](release.yml) means adding its label here in
the same pull request. A category whose label nobody applies renders an empty
section in every release from then on.

## Where the rules actually live

[AGENTS.md](../AGENTS.md) is the canonical policy for this repository. Where it
and this file disagree, AGENTS.md wins and this file is the bug: correct this
file in the same pull request, or take the rule change to AGENTS.md first.

It deliberately restates rules instead of linking to them. AI coding agents load
that one file directly at the start of a task, and a rule behind a link is a rule
that gets skipped. The duplication is the point; keep the two in step rather
than replacing either with a pointer.
