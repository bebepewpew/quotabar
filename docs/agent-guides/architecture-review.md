# Designing a QuotaBar change

The architect decides *where* a change lives and *what shape* it takes, before an
implementer starts typing. It writes no production code. Its output is a design an
implementer can follow and a reviewer can check against.

`AGENTS.md` is the canonical policy and wins over anything here.

## Where code goes

| Target | Platforms | Rule |
| --- | --- | --- |
| `QuotaCore` | macOS, Linux | probes, discovery, caching, alerts, formatting. **No UI framework, no unguarded platform calls.** |
| `QuotaTray` | macOS, Linux | pixel-level tray rendering; carries its own RGBA because Linux has no colour framework |
| `QuotaBar` | macOS only | SwiftUI menu-bar app, declared behind `#if os(macOS)` in `Package.swift` |
| `QuotaBarCLI` | macOS, Linux | the `quotabar` command |

Two consequences people get wrong:

- A green Linux run says **nothing** about `QuotaBar` — that target does not exist
  there. If the design puts logic in the app, say which job covers it.
- `QuotaCore` and `QuotaTray` are the only targets the test binary links, so they
  are the only ones coverage measures. Logic placed in the CLI or the app is
  logic the coverage gate cannot see. That is an argument for pushing testable
  behaviour down into the core.

Platform conditionals must name the platform. Treating "not macOS" as "Linux" is a
portability bug waiting for the first BSD build.

## Choosing the persistence seam

There are two, and picking the wrong one is the mistake this repository already had
to write a rule about.

- **`StateStore`** — `UserDefaults` on macOS, an XDG JSON file on Linux. It
  **rewrites its whole file on every write**. Correct for settings, selections,
  the cached snapshot, notification dedup markers and the history *series
  catalogue*. Wrong for anything that grows.
- **`HistoryStore`** — an append-only fixed-stride log, `history.bin`, under
  `~/Library/Application Support/QuotaBar` on macOS and
  `${XDG_STATE_HOME:-~/.local/state}/quotabar` on Linux. History is state, not
  configuration, which is why it is not beside the settings file.

`HistoryStore` is a second seam, not a bypass. A design that puts a growing series
through `StateStore`, or configuration through `HistoryStore`, is wrong regardless
of how well it is implemented.

## Compatibility is part of the design, not a follow-up

- Storage keys stay stable and decoding stays backward compatible, so an existing
  install keeps its cache, settings and dedup state. `QuotaWindow` and
  `QuotaSelection` already show the pattern: `decodeIfPresent` with a derived
  fallback for a field that did not used to exist.
- The history header carries a **version and a record stride**. A file written by
  a newer build is read as far as it can be and is **never appended to or
  deleted**; a file that is not ours is left alone rather than replaced.
- `--json` and `--format waybar` keys are a public interface. Renaming one breaks
  a user's status bar as surely as changing a storage key breaks their cache.

If the design changes any of these, the compatibility story is a required section,
not a note.

## Identity

Quota windows are keyed on a **stable window key**. Labels and reset timestamps are
display data and must never be used to match one window to another — vendors change
both without warning. History is keyed the same way for the same reason.

## Concurrency

- UI and observable state on the main actor.
- Blocking CLI work off the cooperative executor. A probe run on the main actor is
  not slow, it is a hang.
- Shared mutable state gets an actor — `AlertEvaluator` is the existing example.
- `Sendable` across every boundary the design introduces; Swift 6 will not let you
  postpone it, so do not design something that needs a `@unchecked` escape.

## Process shape

- Prefer an **argument array** over building a script. Codex was moved off `expect`
  onto plain pipes precisely to delete an interpolation surface; the same reasoning
  applies to anything new. Gemini keeps `expect` only because an interactive TUI
  genuinely needs a pseudo-terminal.
- Every external process gets a deadline **and** termination of its complete
  process group. Design the cleanup path at the same time as the happy path,
  including every early exit.
- Cached quota values survive a failed refresh. A design where an error clears the
  display is a regression even when the error handling is correct.

## Best effort has a precise meaning here

Recording history is best effort: a history file that cannot be written or is
damaged must never turn a working quota refresh into a failure. Read paths report
what they skipped; write paths stay silent. If the design introduces another
best-effort side channel, say which of those two it is.

## Dependencies

There are no third-party Swift packages. Adding one is a security and supply-chain
decision, not a convenience, and it has to be argued in the pull request. Most of
the time the answer is to write the twenty lines.

## What to hand over

1. The seam and target for each piece, and why not the other one.
2. What changes in `QuotaCore`, in each front end, and in persistence.
3. The compatibility story: keys, decoding, history header, public output keys.
4. The test surface — what becomes a fixture, what becomes a boundary assertion,
   what can only be covered on one platform.
5. The risks, and the one or two decisions a reviewer should push back on.
6. When the honest answer is "this does not belong in QuotaBar", say that instead.
