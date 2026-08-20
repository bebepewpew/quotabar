# Fixtures for the quota parsers

`AGENTS.md`: *"Parser changes require fixtures for boundaries, malformed data,
terminal redraws, and every supported row form."* Tests live in
`Tests/QuotaCoreTests/QuotaCoreTests.swift` and use `@testable import QuotaCore`,
so internal parsers are reachable directly. Keep parsing logic in a pure static
function taking the raw text plus `now:` — never call a real CLI from a test.

## What every parser change needs

| Case | Why |
| --- | --- |
| Boundary values | `0%` and `100%` are both real and behave differently |
| Malformed / partial rows | must raise a clear error, not silently return zero windows |
| Terminal redraws | ANSI erase sequences and `\r` overwrites arrive mid-line |
| Every supported row form | each provider adds shapes over time; cover them all |
| Reset-time spellings | vendors change these without warning |

Threshold changes need exact boundary tests: 79.9 / 80 / 94.9 / 95.

## Gotchas that have actually bitten this repo

- **Gemini `--screen-reader` wraps one character per line.** `normalize()`
  rejoins single-character lines. A realistic fixture must include that shape,
  not just tidy rows.
- **`expectScript` is a non-raw multiline literal**, so `\t`, `\r` and `\n` in it
  are *real control characters*. A test asserting `contains("[ \\t]+")` looks
  right and always fails; it must be `contains("[ \t]+")`.
- **`JSONSerialization` does not bridge numbers to `NSNumber` on Linux.** Codex
  fixtures must include plain `Int`/`Double` values, not only `NSNumber`, or a
  Linux-only zeroing bug slips through. Read them via `jsonNumber(_:)`.
- **The same screen can mean two things.** Gemini shows its sign-in menu both
  when signed out and when the account tier has been withdrawn. Assert on the
  *decisive* marker and its precedence, not on whichever text appears first.
- Reset spellings seen in the wild: `Aug 22 at 2am` and `Aug 22, 8:59am`.

## Process changes

Cover timeout, authentication and cleanup where practical. Assert the expect
script's exit branches still tear the child down — a leaked provider CLI is
invisible until it is not.
