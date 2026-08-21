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
| `docs/` | [`development.md`](docs/development.md) for building and testing from a checkout, [`container.md`](docs/container.md) for the published image, and `agent-guides/` for the long-form guidance the agent tooling points at |
| `.github/` | Workflows, `CODEOWNERS`, `dependabot.yml`, the pull request template, `ISSUE_TEMPLATE/`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md` |
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
  provider, quota window, reset period, and threshold — plus a forecast alert
  when a window is on course to run out before it resets.
- A usage strip under each quota showing the last seven days, and an advisor
  panel when a subscription looks oversized or keeps running out.
- Optional launch at login.

### `quotabar` command (macOS, Linux)

- One-shot table, `--json`, or a `--format waybar` payload.
- `--watch` polls on an interval; `--notify` raises the same 80%/95% alerts
  through `notify-send`, so any `org.freedesktop.Notifications` daemon (KDE
  Plasma, GNOME, dunst, mako) shows them.
- `quotabar history` charts recorded consumption; `quotabar advise` says whether
  your subscriptions match how you actually use them.
- Same dedup rules and same cached-value retention as the macOS app.

### Consumption history and the advisor

Every refresh records one sample per quota window — a percentage, a timestamp
and the reset time — to a local file. Readings that have not moved are skipped,
so three months costs well under a megabyte, and anything older than 120 days is
dropped.

`quotabar history --format csv` exports that record one row per sample, but only
for the window it was asked for: `--since` defaults to 7 days, so a full backup
of what is still retained is `quotabar history --since 120d --format csv`.

From that QuotaBar reconstructs *cycles*: the span between one reset and the
next. Providers report a level, not a cycle, so a reset is inferred from usage
falling sharply, from the reported reset jumping forward, or from the clock
passing a reset already reported.

`quotabar advise` then applies fixed rules — no model, no network, nothing
leaves your machine:

| It says | When |
|---|---|
| on course to run out before it resets | the recent trend reaches 100% before the reset |
| runs out most cycles | at least half of the last 8 cycles hit 95% |
| usage is bursty, not oversubscribed | the session limit keeps biting while the week stays quiet |
| looks oversized | even the busiest of the last cycles peaked at 40% or less |
| has gone unused | four or more cycles at 1% or less |
| has headroom | one provider is full while another is half empty |

Advice is withheld unless there are at least four complete cycles, each watched
for at least 60% of its length. A laptop that was shut for four days understates
that week, and `advise` says *"not enough history yet"* rather than reading the
gap as a quiet week. History is only recorded while something is running to
record it — the macOS app, `quotabar --watch`, or each one-shot invocation.

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
build from a checkout instead, see [From source](#from-source).

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

Both install `/usr/bin/quotabar` and, since the tray landed, `/usr/bin/quotabar-tray`. The binary is linked with
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
`quotabar` binary alongside `README.md` and `LICENSE`; the Linux one also carries
`quotabar-tray`, which you can install the same way:

```sh
sudo install -m 0755 "${NAME}/quotabar-tray" /usr/local/bin/   # Linux only
```
 Prefer the Homebrew tap on
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

### From source

```sh
git clone https://github.com/bebepewpew/quotabar.git
cd quotabar
./quotabar run          # macOS: builds and launches the menu-bar app
./quotabar cli --json   # Linux and macOS: builds and runs the command
```

The wrapper picks the toolchain for you, and on Linux without Swift installed it
builds in a container. [`docs/development.md`](docs/development.md) has the
detail, along with how to run the tests.

## Usage

```
quotabar                      human-readable table
quotabar --json               machine readable snapshots
quotabar --format waybar      {"text","tooltip","class","percentage","stale"}
quotabar --format csv         one row per window, in history's columns
quotabar --provider claude    limit to one provider; repeatable
quotabar --watch              keep running and re-probe on an interval
quotabar --watch --interval 15 --notify
quotabar --no-color           disable ANSI colour ($NO_COLOR is honoured too)

quotabar history              usage graph for the last 7 days
quotabar history --since 30d  a longer window (90m, 24h, 7d, 3w all work)
quotabar history --cycles     completed cycles with peak and coverage
quotabar history --format csv export the --since window, same columns (7d)
quotabar history --clear      delete all recorded history
quotabar advise               whether your subscriptions fit your usage
quotabar advise --json        the same findings, machine readable
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

The `class` field is `normal`, `warning`, `critical`, or `unavailable` when no
provider reported a reading at all, so it can be styled:

```css
#custom-quotabar.warning     { color: #d79921; }
#custom-quotabar.critical    { color: #cc241d; }
#custom-quotabar.unavailable { color: #928374; }
```

In that `unavailable` state `percentage` is `null` rather than `0`, so nothing
reads as 0% used; `tooltip` says why each provider is missing. `stale` is `true`
when the number shown is a retained reading whose refresh failed, and `text`
then ends in `⚠` so the state is visible without colour.

polybar and the Plasma command-output widget can run `quotabar --format waybar`
and read the `text` field, or use plain `quotabar` for the full table.

### Tray icon

```sh
quotabar-tray                    # runs until you quit it from the menu
quotabar-tray --interval 300     # seconds between refreshes (default 900)
```

`quotabar-tray` puts QuotaBar in the system tray as a
[StatusNotifierItem](https://www.freedesktop.org/wiki/Specifications/StatusNotifierItem/),
which is what KDE Plasma reads natively and what libayatana-appindicator exposes
to most other panels. It colours bars amber at 80% and red at 95%, lists every
window in the tooltip, and offers Refresh and Quit. A left click refreshes.

The icon shows the three busiest windows. Choosing which ones appear is a macOS
feature today — the setting is stored per platform and no Linux front-end writes
it yet — so on Linux the tray picks them by usage on every refresh.

It needs a session bus with a StatusNotifierWatcher on it — Plasma provides one;
on GNOME it comes from the AppIndicator extension. The `quotabar` command needs
neither and works anywhere. Linux only: macOS has the menu-bar app instead.

To start it with your desktop session:

```sh
quotabar-tray --install-autostart
systemctl --user enable --now quotabar-tray.service
```

`--install-autostart` writes the unit to
`${XDG_CONFIG_HOME:-~/.config}/systemd/user/quotabar-tray.service`, pointing at
the binary you ran it from. `--remove-autostart` deletes it again.

QuotaBar speaks the D-Bus protocol directly rather than linking `libdbus`, so the
tray is as self-contained as the command — the `.deb`, `.rpm` and tarball all
carry both binaries and neither adds a package dependency.

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

## Privacy and behavior

All probes execute installed CLIs locally. Gemini runs inside a fixed-size
pseudo-terminal with a bounded deadline; QuotaBar sends only `/stats` and
terminates the complete process group afterward. Failed refreshes preserve the
last successful values rather than clearing the corresponding card.

State is stored per platform: `UserDefaults` on macOS, and
`${XDG_CONFIG_HOME:-~/.config}/quotabar/state.json` on Linux.

Usage history is a separate file — `history.bin` under
`~/Library/Application Support/QuotaBar` on macOS and
`${XDG_STATE_HOME:-~/.local/state}/quotabar` on Linux. It holds usage
percentages, timestamps and reset times, and nothing else: no prompts, no
filenames, no credentials. It never leaves the machine, and QuotaBar makes no
network requests of its own. Delete it with `quotabar history --clear`, or from
Settings in the macOS app.

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
[`docs/development.md`](docs/development.md) covers building, testing, and what a
new platform front-end would take.

## Issues

Three forms, in [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE): a bug
report, a feature request, and a scoped backlog item. Blank issues are off, so
every entry arrives with its fields.
[`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md#filing-an-issue) has the rest
— which form, and what to redact before pasting. A vulnerability is never a
public issue; see [Security](#security) above.

If [Troubleshooting](#troubleshooting) already names the message you are seeing,
start there.

## Pull requests

The repository squash-merges, and merge commits and rebase merges are disabled.
One pull request therefore becomes exactly one commit on `main` and exactly one
line in the release notes, and the **pull-request title** is that line — not the
branch name, and not the commit messages on the branch. Write it concise and
imperative: "Bound the Gemini probe deadline", not "gemini fixes".

Every pull request also carries exactly **one** category label, applied when the
pull request is opened. The `Labels` CI job fails the pull request until exactly
one is present. The label decides which section the title appears under, exactly
as [`.github/release.yml`](.github/release.yml) configures:

| Label | Release-notes section |
| --- | --- |
| `feature` | Added |
| `fix` | Fixed |
| `security` | Security |
| `performance` | Performance |
| `tooling` | Tooling |
| `ci` | Tooling |
| `documentation` | Documentation |
| `docs` | Documentation |
| `dependencies` | Dependencies |
| `skip changelog` | none — the pull request is left out of the notes entirely |

Use `skip changelog` for a change that should not appear in the release notes at
all. An unlabelled pull request is not dropped: it lands in the catch-all
**Other** section, which is a safety net rather than a destination — a change
that reaches a release under Other is a change nobody categorised.

[`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md) lists the same labels with
the colours to create them in.
