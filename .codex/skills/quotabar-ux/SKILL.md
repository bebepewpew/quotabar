---
name: quotabar-ux
description: Review what a QuotaBar user actually sees — menu-bar and tray legibility, colour-blind and VoiceOver accessibility, error and empty states, notification volume, and --json/waybar as a public interface. Use for any change to QuotaBar, QuotaTray, formatting or CLI output.
---

# The QuotaBar surface

`AGENTS.md` is the canonical policy and wins over anything here.

Three surfaces, one of them 16 pixels tall: the macOS menu bar, the hand-rasterised
tray bitmap (Linux has no colour framework, so there is no toolkit to fall back
on), and the terminal — table, `--json`, `--format waybar`.

**Colour is never the only signal.** Provider tint below 80%, amber from 80, red
from 95 — roughly one man in twelve cannot reliably separate the last two, so the
percentage, the bar length and the one-character badges carry the state too. Any
new state needs a non-colour signal. `--no-color` and a pipe both exist.

A broken input must still render: an unparsable tint falls back to neutral grey,
because an invisible icon is a worse failure than a wrong colour. A failed probe
still yields a row, because a provider that silently disappears reads as "fine".

`--json` and `--format waybar` keys are an interface. Renaming one breaks a user's
status bar exactly the way changing a storage key breaks their cache.

**The full guide — the surfaces, error states, notification fatigue and the
concrete checks to run — is `docs/agent-guides/ux-review.md`.**

Point at file and line like any other reviewer. "This feels cramped" is not
reviewable.
