# QuotaBar

[![CI](https://github.com/bebepewpew/quotabar/actions/workflows/ci.yml/badge.svg)](https://github.com/bebepewpew/quotabar/actions/workflows/ci.yml)

A small native macOS menu-bar app for monitoring AI coding CLI quotas.

- **Codex:** reads live limits through the local app-server protocol.
- **Claude Code:** runs `claude -p /usage` and parses its usage windows.
- **Gemini CLI:** opens a bounded, screen-reader-friendly terminal session, runs
  interactive `/stats`, and parses every displayed model quota bucket.

QuotaBar discovers installed providers at launch. It caches the last successful
snapshot in `UserDefaults`, refreshes automatically, and keeps cached values
visible with a refresh error if a CLI is unavailable, unauthenticated, or returns
unreadable data.

## Features

- Configurable refresh intervals from 5 minutes to 1 hour.
- Up to three selected quota metrics in the menu bar.
- Compact metric badges: `S`/`W` for session and weekly windows, and
  `P`/`F`/`L` for recognizable Gemini model families.
- Provider-colored progress below 80% used, amber at 80%, and red at 95%.
- Local macOS notifications at the 80% and 95% thresholds, deduplicated per
  provider, quota window, reset period, and threshold.
- Optional launch at login.

## Requirements

- macOS 14 or later.
- Swift 6.
- At least one supported CLI: `codex`, `claude`, or `gemini`.
- Each CLI must already be authenticated. QuotaBar never completes login prompts
  and does not copy, inspect, or store provider credentials or API keys.

## Build and run

```sh
git clone https://github.com/bebepewpew/quotabar.git
cd QuotaBar
./quotabar run
```

The wrapper builds an ad-hoc signed `.build/QuotaBar.app` agent bundle and runs
it as a menu-bar app. Build without launching it with:

```sh
./quotabar build
```

The wrapper also selects a compatible installed macOS SDK when Command Line
Tools contains a compiler/SDK version mismatch.

## Tests

```sh
./quotabar test
```

Tests require the full Xcode toolchain. The wrapper reports a clear error when
the standalone Command Line Tools installation does not include XCTest.

## Privacy and behavior

All probes execute installed CLIs locally. Gemini runs inside a fixed-size
pseudo-terminal with a 45-second deadline; QuotaBar sends only `/stats` and
terminates the complete process group afterward. Failed refreshes preserve the
last successful values rather than clearing the corresponding card.

## License

QuotaBar is available under the [MIT License](LICENSE).

## Contributing

All changes go through pull requests with required CI. Read
[CONTRIBUTING.md](CONTRIBUTING.md) and the shared human/AI rules in
[AGENTS.md](AGENTS.md), then run `scripts/install-hooks` once per clone.
