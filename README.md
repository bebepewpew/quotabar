# QuotaBar

[![CI](https://github.com/bebepewpew/quotabar/actions/workflows/ci.yml/badge.svg)](https://github.com/bebepewpew/quotabar/actions/workflows/ci.yml)

Monitoring for AI coding CLI quotas — a native macOS menu-bar app, and a
cross-platform `quotabar` command for everything else.

- **Codex:** reads live limits through the local app-server protocol.
- **Claude Code:** runs `claude -p /usage` and parses its usage windows.
- **Gemini CLI:** opens a bounded, screen-reader-friendly terminal session, runs
  interactive `/stats`, and parses every displayed model quota bucket.

QuotaBar discovers installed providers at launch. It caches the last successful
snapshot, refreshes automatically, and keeps cached values visible with a refresh
error if a CLI is unavailable, unauthenticated, or returns unreadable data.

## Layout

| Module | Platforms | What it is |
| --- | --- | --- |
| `QuotaCore` | macOS, Linux | Probes, discovery, caching, threshold alerts, formatting |
| `QuotaBar` | macOS | SwiftUI menu-bar app |
| `QuotaBarCLI` | macOS, Linux | The `quotabar` command |

## Features

### Menu-bar app (macOS)

- Configurable refresh intervals from 5 minutes to 1 hour.
- Up to three selected quota metrics in the menu bar.
- Compact metric badges: `S`/`W` for session and weekly windows, and
  `P`/`F`/`L` for recognizable Gemini model families.
- Provider-colored progress below 80% used, amber at 80%, and red at 95%.
- Local macOS notifications at the 80% and 95% thresholds, deduplicated per
  provider, quota window, reset period, and threshold.
- Optional launch at login.

### `quotabar` command (macOS, Linux)

- One-shot table, `--json`, or a `--format waybar` payload.
- `--watch` polls on an interval; `--notify` raises the same 80%/95% alerts
  through `notify-send`, so any `org.freedesktop.Notifications` daemon (KDE
  Plasma, GNOME, dunst, mako) shows them.
- Same dedup rules and same cached-value retention as the macOS app.

## Requirements

- At least one supported CLI: `codex`, `claude`, or `gemini`, already
  authenticated. QuotaBar never completes login prompts and does not copy,
  inspect, or store provider credentials or API keys.
- `expect` — required by the Gemini probe only, which drives an interactive TUI
  and therefore needs a pseudo-terminal.
  (`brew install expect`, `sudo pacman -S expect`, `sudo apt install expect`)
  Codex and Claude Code speak over plain pipes and need nothing extra.
- **macOS:** macOS 14 or later, Swift 6.
- **Linux:** Swift 6 — or just docker, see below. `libnotify` for `--notify`, and
  `zsh` if you use the `./quotabar` wrapper (`swift build` / `swift run quotabar`
  work without it).

## Build and run

### macOS

```sh
git clone https://github.com/bebepewpew/quotabar.git
cd quotabar
./quotabar run
```

The wrapper builds an ad-hoc signed `.build/QuotaBar.app` agent bundle and runs
it as a menu-bar app. Build without launching it with `./quotabar build`. The
wrapper also selects a compatible installed macOS SDK when Command Line Tools
contains a compiler/SDK version mismatch.

### Linux

```sh
git clone https://github.com/bebepewpew/quotabar.git
cd quotabar
./quotabar cli --json
```

With a Swift toolchain installed, this is `swift run quotabar`. Without one — as
on Arch, which has no official Swift package — the wrapper builds a statically
linked binary inside the upstream `swift:6.3-noble` container and then runs it on
the host, where the provider CLIs and your session bus actually live. Override
the image with `QUOTABAR_SWIFT_IMAGE`.

## Usage

```
quotabar                      human-readable table
quotabar --json               machine readable snapshots
quotabar --format waybar      {"text","tooltip","class","percentage"}
quotabar --provider claude    limit to one provider; repeatable
quotabar --watch              keep running and re-probe on an interval
quotabar --watch --interval 15 --notify
quotabar --no-color           disable ANSI colour ($NO_COLOR is honoured too)
```

Exit codes: `0` every probe succeeded, `1` at least one provider failed to
report, `2` invalid usage.

### Status bar integration

waybar:

```jsonc
"custom/quotabar": {
  "exec": "/path/to/quotabar --format waybar --watch --interval 15",
  "return-type": "json"
}
```

The `class` field is `normal`, `warning`, or `critical`, so it can be styled:

```css
#custom-quotabar.warning  { color: #d79921; }
#custom-quotabar.critical { color: #cc241d; }
```

polybar and the Plasma command-output widget can run `quotabar --format waybar`
and read the `text` field, or use plain `quotabar` for the full table.

A native KDE tray icon (StatusNotifierItem) is planned as a separate front-end
on top of `QuotaCore`.

## Porting to another platform

`QuotaCore` carries no UI framework, and the platform seams are `StateStore`,
`QuotaNotificationSink` and `QuotaProbe`. A new platform means a new front-end
target plus implementations of those, declared in `Package.swift` the way the
macOS app already is.

What Windows would still need, none of which is in the way today:

- process termination via a Job Object, where POSIX uses `setpgid` and a
  process-group `kill`;
- `LockFileEx` in `JSONFileStateStore` in place of `flock`;
- `ENABLE_VIRTUAL_TERMINAL_PROCESSING` before ANSI colour means anything;
- a toast notification sink instead of `notify-send`;
- a native pseudo-terminal (ConPTY) for the Gemini probe, which is the only
  part that genuinely needs one. Codex and Claude Code already run over pipes.

## Tests

```sh
./quotabar test
```

On macOS this requires the full Xcode toolchain; the wrapper reports a clear
error when the standalone Command Line Tools installation does not include
XCTest. On Linux it runs natively or in the container, matching `./quotabar build`.

## Privacy and behavior

All probes execute installed CLIs locally. Gemini runs inside a fixed-size
pseudo-terminal with a bounded deadline; QuotaBar sends only `/stats` and
terminates the complete process group afterward. Failed refreshes preserve the
last successful values rather than clearing the corresponding card.

State is stored per platform: `UserDefaults` on macOS, and
`${XDG_CONFIG_HOME:-~/.config}/quotabar/state.json` on Linux.

## License

QuotaBar is available under the [MIT License](LICENSE).

## Contributing

All changes go through pull requests with required CI. Read
[CONTRIBUTING.md](CONTRIBUTING.md) and the shared human/AI rules in
[AGENTS.md](AGENTS.md), then run `scripts/install-hooks` once per clone.
