# QuotaBar

[![CI](https://github.com/bebepewpew/quotabar/actions/workflows/ci.yml/badge.svg)](https://github.com/bebepewpew/quotabar/actions/workflows/ci.yml)
[![CodeQL](https://github.com/bebepewpew/quotabar/actions/workflows/codeql.yml/badge.svg)](https://github.com/bebepewpew/quotabar/actions/workflows/codeql.yml)
[![Security scan](https://github.com/bebepewpew/quotabar/actions/workflows/security-scan.yml/badge.svg)](https://github.com/bebepewpew/quotabar/actions/workflows/security-scan.yml)
[![Latest release](https://img.shields.io/github/v/release/bebepewpew/quotabar?sort=semver)](https://github.com/bebepewpew/quotabar/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Monitoring for AI coding CLI quotas — a native macOS menu-bar app, and a
cross-platform `quotabar` command for everything else.

- **Codex:** reads live limits through the local app-server protocol.
- **Claude Code:** runs `claude -p /usage` and parses its usage windows.
- **Gemini CLI:** opens a bounded, screen-reader-friendly terminal session, runs
  interactive `/stats`, and parses every displayed model quota bucket.

QuotaBar discovers installed providers at launch. It caches the last successful
snapshot, refreshes automatically, and keeps cached values visible with a refresh
error if a CLI is unavailable, unauthenticated, or returns unreadable data.

## Screenshots

None are committed yet. Each bullet below marks where one goes; add the image
and write its caption at the same time, and delete the placeholder it replaces.

- **Screenshot placeholder** — the macOS menu-bar item with its menu open.
- **Screenshot placeholder** — `quotabar` printing its table in a terminal.
- **Screenshot placeholder** — `quotabar --format waybar` inside a status bar.

## Repository layout

| Path | What lives there |
| --- | --- |
| `Package.swift`, `Sources/`, `Tests/` | The SwiftPM package: every target and its tests |
| `Resources/` | `Info.plist` and the icons the macOS app bundle is built from |
| `packaging/` | What the release workflow builds distributables from: the nfpm configuration for the `.deb` and `.rpm`, the container `Dockerfile`, and `homebrew/quotabar.rb` |
| `scripts/` | `install-hooks`, `install-codex-skills`, `coverage`, `codex-parallel` |
| `docs/agent-guides/` | The long-form guidance the agent tooling points at |
| `.github/` | Workflows, `CODEOWNERS`, `dependabot.yml`, the pull request template, `CONTRIBUTING.md`, `SECURITY.md` |
| `.claude/`, `.codex/`, `.githooks/` | Per-tool wrappers and the repository hooks |
| `quotabar` | The wrapper that picks a toolchain: `./quotabar build`, `test`, `coverage`, `run`, `cli` |

One of those cannot move, so please do not re-litigate it:

- **`Package.swift`, `Sources/`, `Tests/` and `Resources/` stay where they
  are.** SwiftPM requires the manifest at the package root and finds target
  sources by convention.

The Homebrew formula is `packaging/homebrew/quotabar.rb`, and that directory is
not a tap — Homebrew installs from
[`bebepewpew/homebrew-tap`](https://github.com/bebepewpew/homebrew-tap), which
the release workflow renders this file into. It is kept here because a formula's
`install` and `test` blocks execute on every user's machine, so they belong
behind this repository's review and branch protection; the tap is generated
output. See [Homebrew](#macos--homebrew) below.

`CONTRIBUTING.md` and `SECURITY.md` live under `.github/` deliberately: GitHub
still surfaces both from there, and the root stays short enough to read.

### Modules

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

## Installation

Released binaries and packages are published on the
[releases page](https://github.com/bebepewpew/quotabar/releases). To
build from a checkout instead, skip to [Build and run](#build-and-run).

Every artifact is signed and checksummed. The commands below install without
checking that — see [Verifying a release](#verifying-a-release) for the one extra
step, which is worth taking on anything you are about to run as root.

### macOS — Homebrew

```sh
brew tap bebepewpew/tap
brew install quotabar
```

No URL is needed: Homebrew maps `user/name` to `github.com/user/homebrew-name`,
which is the [`homebrew-tap`](https://github.com/bebepewpew/homebrew-tap)
tap. The release workflow renders `packaging/homebrew/quotabar.rb` into that
tap and then audits, installs and tests it on a macOS runner — pushing only if
all three pass, so a release cannot publish a formula that does not build. If `quotabar` is ambiguous on your machine, name it in full:
`brew install bebepewpew/tap/quotabar`.

The formula builds from source on purpose. A downloaded Mach-O that Apple has
not notarized picks up the `com.apple.quarantine` attribute and Gatekeeper
blocks it on first run; a binary compiled on the installing machine never
carries that attribute. The trade-off is a build dependency: Xcode 16 or later,
for the Swift 6 toolchain.

### Linux — `.deb` and `.rpm`

```sh
VERSION=0.1.0
BASE=https://github.com/bebepewpew/quotabar/releases/download/v$VERSION

# Debian, Ubuntu
curl -fLO "$BASE/quotabar_${VERSION}_amd64.deb"
sudo apt install "./quotabar_${VERSION}_amd64.deb"

# Fedora, RHEL
curl -fLO "$BASE/quotabar-${VERSION}.x86_64.rpm"
sudo rpm -i "quotabar-${VERSION}.x86_64.rpm"
```

Set `VERSION` to the release you want; the
[releases page](https://github.com/bebepewpew/quotabar/releases/latest) has the
current one. The filenames are not stable across versions, which is why there is
no `releases/latest/download/…` shortcut here.

Both install `/usr/bin/quotabar`. The binary is linked with
`--static-swift-stdlib`, so it carries the Swift runtime and needs no Swift
package installed. `expect` and libnotify are recommended rather than required:
the first is used only by the Gemini probe, the second only by `--notify`.

### Any platform — static tarball

```sh
VERSION=0.1.0
BASE=https://github.com/bebepewpew/quotabar/releases/download/v$VERSION

# Linux
NAME=quotabar-${VERSION}-linux-x86_64
# macOS
NAME=quotabar-${VERSION}-macos-universal

curl -fLO "$BASE/${NAME}.tar.gz"
tar -xzf "${NAME}.tar.gz"
sudo install -m 0755 "${NAME}/quotabar" /usr/local/bin/
```

Set `NAME` to whichever of the two matches your platform. Each tarball holds the
`quotabar` binary alongside `README.md` and `LICENSE`. Prefer the Homebrew tap on
macOS: a browser download picks up `com.apple.quarantine` and Gatekeeper then
blocks the unnotarized binary on first run.

### Container

```sh
docker run --rm ghcr.io/bebepewpew/quotabar:latest --json
```

Tagged with the release version as well as `latest`. The image is only useful
for the CLI's own output — it cannot see provider CLIs or credentials on the
host unless you mount them, which QuotaBar deliberately does not do for you.
[`docs/container.md`](docs/container.md) covers what to mount and why.

### Verifying a release

Every release artifact is signed keylessly with
[cosign](https://docs.sigstore.dev/) through this repository's GitHub OIDC
identity and carries a GitHub build provenance attestation, and `SHA256SUMS`
covers the whole set. Each release's notes carry the exact `cosign verify-blob`
and `gh attestation verify` commands for that version.

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

## Troubleshooting

QuotaBar reports why a provider is unavailable rather than hiding it. The common
causes:

| Message | Cause |
| --- | --- |
| `expect is not installed` | Only the Gemini probe needs it. Install it, or ignore it if you do not use Gemini. |
| `Gemini rejected this client…` | Google has withdrawn this account's Gemini Code Assist tier. Signing in again cannot fix it; see <https://antigravity.google>. |
| `Gemini is waiting for a folder-trust decision` | Gemini CLI asks whether to trust the working directory before it will start. Run `gemini` once and answer it. |
| `Gemini authentication is required` | Genuinely signed out. Run `gemini` and sign in. |
| `… is not installed` | The provider's CLI was not found on `PATH` or in the usual install locations. |

A failed provider never clears the values QuotaBar already had; the last
successful reading stays visible with the error beside it.

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

## Security

Report vulnerabilities privately through GitHub security advisories rather than
a public issue. [`.github/SECURITY.md`](.github/SECURITY.md) has the reporting
process, what is in and out of scope, and what QuotaBar does with your machine
so you can judge the risk yourself.

## Contributing

All changes go through pull requests with required CI. Read
[`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md) and the shared human/AI
rules in [AGENTS.md](AGENTS.md), then run `scripts/install-hooks` once per clone
(and `scripts/install-codex-skills` if you use Codex).
