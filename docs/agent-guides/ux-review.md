# The QuotaBar surface

QuotaBar has two shipping surfaces and one of them is 16 pixels tall, plus a
third — the Linux tray — that is written and tested but not yet packaged. This
role judges what a person actually sees, at the size and in the conditions they
see it.

`AGENTS.md` is the canonical policy and wins over anything here.

## The surfaces

| Surface | Where | Constraint |
| --- | --- | --- |
| macOS menu bar | `QuotaBar` | up to three metrics, a one-character badge each, legible at 16pt and @2x |
| Tray icon | `QuotaTray` | rasterised to RGBA8 by hand — Linux has no colour framework, so there is no toolkit to fall back on. Built and tested, but no product ships it yet: review it as code a user will eventually see, not as one they see today |
| Terminal | `QuotaBarCLI` | a padded table, `--json`, `--format waybar` |

## Colour is never the only signal

The thresholds are provider tint below 80% used, amber (`FF9F0A`) from 80, red
(`FF453A`) from 95. Roughly one man in twelve cannot reliably separate the last
two.

So the state is always carried by something else as well: the percentage text
itself, the bar length, and the compact badges — `S`/`W` for session and weekly
windows, `P`/`F`/`L` for the recognisable Gemini model families. **Any new state
needs a non-colour signal too.** A design that adds a fourth tint and nothing else
is not readable by everyone who uses this.

The terminal path has the same rule twice over: `--no-color`, a pipe, and a
non-ANSI terminal all exist, so the text must be complete without the escape codes.
Note where the CLI already does this deliberately — advice output colours only the
severity badge, because escape codes travel with a copy and the evidence lines are
numbers a user may want to paste somewhere.

## A broken input must still render

`TintRGB(hex:)` falls back to neutral grey for anything it cannot parse,
because an unparsable tint must still be a **visible** icon — never a transparent
or a black one. It is one parse in `QuotaCore` for both front-ends —
`TrayColor(hex:)` on Linux, `NSColor(hex:)` and `Color(hex:)` on macOS — because
when the rule was written twice the second copy fell back to black. Hold every
new visual default to that: what does this draw when the value is missing, out of
range, or nonsense?

Related, from `QuotaFormatting.rows`: a failed probe with no cached windows still
yields a row, so a provider never silently disappears. Disappearance is the worst
possible error state — the user reads it as "fine".

## Errors are part of the UI

- Cached values stay visible with the refresh error beside them. An error must not
  blank the display.
- Messages are concise and **actionable**, and never a raw dump of CLI output —
  that is how a token ends up in a screenshot.
- An error that sends the user somewhere that cannot fix the problem is a defect,
  not a wording choice. "No supported CLI found. Install codex, claude or gemini
  and authenticate it." is the shape to match.

## Notifications

80% and 95%, deduplicated per provider, quota window, reset period and threshold,
identically on macOS `UserNotifications` and Linux `notify-send`. A change that
makes them fire more often, or fire again after a reset that did not happen, is a
user-experience regression even when the logic is correct. Notification fatigue
ends with the feature turned off.

## `--json` and `--format waybar` are an interface, not output

Another program reads them. Renaming a key breaks someone's status bar exactly the
way changing a storage key breaks their cache — treat it as a compatibility
decision, add fields rather than rename them, and say so in the pull request.

## Text that has to survive translation of a sort

`RelativeDateTimeFormatter` is absent from swift-corelibs-foundation, so both front
ends share one locale-free implementation of "resets in" rather than diverging on
wording. Keep new user-visible wording in `QuotaCore` for the same reason: the
menu bar and the terminal should not describe the same state differently.

## What to check, concretely

1. Read it at the real size — 16pt menu bar, @2x, and a 16×16 tray bitmap.
2. Turn colour off. Is every state still distinguishable?
3. Put it in the worst state: no provider installed, an unauthenticated provider, a
   probe timing out, 0%, 100%, a window with no reset time.
4. Check the accessibility labels on anything new in the macOS menu — a
   colour-and-shape badge with no label is invisible to VoiceOver.
5. Compare the menu bar and the terminal wording for the same state.

## What to report

What a user sees before and after, in which states, and what a colour-blind or
screen-reader user gets. Point at the file and line like any other reviewer —
"this feels cramped" is not reviewable, "three badges plus a two-digit percentage
exceeds the width budget at 16pt" is.
