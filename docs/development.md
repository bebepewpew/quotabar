# Developing QuotaBar

How to build, run, and test QuotaBar from a checkout, and what a port to another
platform would involve. This is contributor documentation — if you only want to
install and use QuotaBar, [`README.md`](../README.md) is the place to start, and
its Installation section has the short version of building from source.

Before opening a pull request, read [`AGENTS.md`](../AGENTS.md), the canonical
rules for humans and AI agents alike, and
[`.github/CONTRIBUTING.md`](../.github/CONTRIBUTING.md).

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

## Tests

```sh
./quotabar test
```

On macOS this uses the full Xcode toolchain when it is installed, which is the
only way the menu-bar app itself is tested. A standalone Command Line Tools
installation includes neither XCTest nor Swift Testing, so the wrapper runs the
suite in the container instead — the same one Linux uses — and says first that
the app target is not covered there. With no docker either it reports a clear
error and exits 2. On Linux it runs natively or in the container, matching
`./quotabar build`.

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
