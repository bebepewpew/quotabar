# Writing QuotaBar's documentation

Documentation here has one job: describe what the code does **now**. A README that
describes an intention is worse than one that says nothing, because a reader acts
on it.

`AGENTS.md` is the canonical policy and wins over anything here.

## Where things live, and why

| File | Holds |
| --- | --- |
| `AGENTS.md` | **all** contributor and architecture policy. The single source |
| `CLAUDE.md`, `GEMINI.md` | pointers at `AGENTS.md`. Never duplicated policy |
| `README.md` | current behaviour, requirements, installation, layout |
| `.github/CONTRIBUTING.md`, `.github/SECURITY.md` | GitHub surfaces both from there, so the root stays short |
| `docs/agent-guides/` | the long-form guidance every agent wrapper points at |
| `docs/development.md` | building, running and developing on a checkout |
| `docs/container.md` | the Linux container path |
| `.github/release.yml` | which label lands a change in which release-notes section |
| `.github/ISSUE_TEMPLATE/` | the three issue forms; blank issues are off, so a new kind of entry means a new template |

The wrapper pattern is deliberate and applies to new tooling too: a
`.claude/agents/*.md`, a `.claude/skills/*/SKILL.md` and a `.codex/skills/*/SKILL.md`
are each a few lines that point at one guide. Guidance lives once. If you find
yourself pasting a paragraph into a second file, the guide is the right home and
the wrapper should link it.

Do not propose moving `Package.swift`, `Sources/`, `Tests/` or `Resources/` —
SwiftPM finds them by convention, and the README says so. The Homebrew formula is
**not** in this repository at all: it lives in `bebepewpew/homebrew-tap`, which the
release workflow pushes. A document that still points at a local `Formula/` is out
of date.

## The pull-request title is the changelog

Squash-and-merge means the title becomes the commit subject on `main` and the line
a user reads in the release notes. Write it for someone scanning a changelog:

- "Store usage history in an append-only fixed-stride log" — says what changed.
- "Update HistoryStore.swift" — says nothing.

The category label decides which section it appears under, and CI fails without
exactly one.

## What goes stale, and how to catch it

- **Numbers.** Coverage figures, version strings, measured counts. Anything with a
  digit in it was true on one day. Cite the day, or re-measure.
- **Thresholds and gates.** If a gate is enforced, every document that mentions it
  says so. A guide claiming a check is advisory while CI fails on it is a trap for
  the next contributor.
- **Mechanisms.** "Codex uses the app-server protocol over pipes", "Gemini needs
  `expect`", "no third-party Swift packages" — each is a claim a change can
  falsify.
- **Commands.** Every command in a document should still exist and still take those
  flags. `./quotabar coverage --lcov <path>` is documented in three places.
- **Requirements.** Minimum macOS, Swift version, `libnotify`, `zsh` for the
  wrapper.

When a change makes a documented claim false, fixing the document is part of that
change, not a follow-up.

## README specifics

- The **screenshot placeholders** are markers, not decoration. Replace a
  placeholder and write its caption in the same change; do not add an image and
  leave the placeholder above it.
- Badges point at real workflows. Adding a workflow does not automatically earn a
  badge — add one only if a reader needs its state.
- Keep the layout table honest when a directory is added.

## Never commit

`REVIEW.md` (a local, generated report), terminal captures containing personal
data, `.build` artifacts, or credentials of any kind. The secret scan fails the
build on the last one, deliberately.

## What to report

The claims your change made false, the files you corrected, and any claim you found
already false but outside your scope — with the file and line, so someone can pick
it up.
