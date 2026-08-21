# Shaping a QuotaBar change

The product role turns a request into something that can actually be built here,
and decides what is *not* in it. It writes no code. Its output is a scope another
agent can implement without asking a second question.

`AGENTS.md` is the canonical policy and wins over anything here.

## The ceiling you are shaping against

QuotaBar shows what three local CLIs are willing to print, and nothing else:

| Provider | Mechanism | What that limits |
| --- | --- | --- |
| Codex | `app-server --stdio` over pipes | whatever the app-server protocol reports |
| Claude Code | `claude -p /usage` | the usage windows that command prints |
| Gemini CLI | interactive `/stats` in a bounded terminal session | the buckets displayed on screen |

There is no API behind this. A request for data no provider prints — cost in
dollars, per-request history, another vendor's quota — is not a scoping problem,
it is impossible, and saying so early is worth more than a ticket nobody can close.

Four constraints are policy, not preference, and cannot be scoped around:

- never read, copy, log or store provider credentials, and never complete a login;
- no network requests of QuotaBar's own;
- Gemini stays terminal-only — never private JavaScript modules;
- Codex and Claude Code stay on pipes — neither acquires a pseudo-terminal.

## Two surfaces, one core

`QuotaCore` is shared; `QuotaBar` (macOS menu bar) and `QuotaBarCLI` (macOS and
Linux) are separate front ends. Nearly every request lands in the core plus one or
both surfaces, so say which. "Add a projected-exhaustion badge" is three decisions:
the core calculation, the menu-bar rendering, and whether the CLI table, `--json`
and `--format waybar` show it too.

A feature that ships on one surface only is a legitimate choice. An unstated one
is a defect someone finds after the pull request.

## Acceptance criteria have to be assertable

The repository tests exact boundaries, so write criteria that can become them.

- Not "warns when usage is high" — **warning at 80.0, none at 79.9, critical at
  95.0, none at 94.9**, because that is what `AlertLevel(usedPercent:)` promises.
- Not "handles bad input" — **`0%` and `100%` both render; a malformed row raises
  a named error rather than returning zero windows.**
- Not "does not spam" — **one notification per provider, window key, reset period
  and threshold.**

If a criterion cannot be written as something a test asserts, it is a preference.
Put it in the notes, not in the scope.

## Pick the label while you are shaping

Every pull request carries exactly one category label, CI fails without one, and
that label chooses the release-notes section. Squash-and-merge means the pull
request *title* becomes the commit subject on `main` and the changelog line, so
write it as a changelog entry rather than a diff summary.

    feature | fix | security | performance | tooling | ci | documentation | docs
    dependencies | skip changelog

The `Labels` job in `ci.yml` fails a pull request carrying none of these or more
than one. `documentation` and `docs` both exist and mean the same section.

Choose by what the change is: a fix on a security surface is `security`, a test
with no behaviour change is `skip changelog`, and `tooling` covers agent runners,
scripts and developer workflow.

## Sequencing and delivery

- Two changes that do not touch the same code can run at once —
  `docs/agent-guides/parallel-tasks.md`. Two that do, cannot: the second reviews a
  base that no longer exists.
- Anything touching `history.bin`, `StateStore` keys or a `--json` / waybar key is
  a **compatibility decision** before it is a feature. Say so in the scope so the
  architect treats it as one.
- A change to `main`-only behaviour needs a named CI job that would catch a
  regression, or an explicit statement that none would.

## What to hand over

1. The problem, in one sentence, from the user's side.
2. Which surfaces are in: core, menu bar, CLI — and which are deliberately out.
3. Acceptance criteria, each assertable.
4. Out of scope, listed, so nobody quietly widens it.
5. The category label and a draft pull-request title written as a changelog line.
6. Risks worth flagging: compatibility, a provider format that may change, a
   platform where this cannot be tested locally.
