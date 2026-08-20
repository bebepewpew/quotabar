---
name: quotabar-dev
description: Build, test and pre-PR validation for QuotaBar, including the Linux/docker path when no Swift toolchain is installed. Use before committing or opening a pull request, or whenever a change needs compiling or testing.
---

# Building and validating QuotaBar

Always go through `./quotabar`. It picks the right toolchain per platform, and on
Linux falls back to the upstream Swift container so a machine without Swift still
builds. Invoking `swift` or `docker` directly bypasses that and produces
`.build` artifacts owned by the wrong user.

```sh
./quotabar build    # compile everything this platform supports
./quotabar test     # run the suite
./quotabar cli ...  # run the quotabar CLI against real provider CLIs
./quotabar run      # macOS only: build and launch the menu-bar app
```

## Before a pull request

`AGENTS.md` requires all three, and CI enforces the first two:

```sh
./quotabar build
./quotabar test
git diff --check
```

Then confirm against `AGENTS.md`:

- external processes bounded by a deadline and their **complete process group**
  terminated — not just `terminate()`;
- cached quota values preserved when a refresh fails;
- CLI output treated as untrusted: terminal controls normalised, percentages
  clamped, errors concise and actionable without echoing raw output;
- persisted payloads still decode from older versions, storage keys unchanged;
- parser changes carry fixtures (use the `probe-fixture` skill).

## Platform truths worth knowing

- **macOS:** `./quotabar test` needs full Xcode. With only Command Line Tools it
  refuses, and GitHub Actions is then the only authority. Say so plainly rather
  than implying the suite ran.
- **Linux:** runs natively if Swift is installed, otherwise inside
  `$QUOTABAR_SWIFT_IMAGE` (default `swift:6.3-noble`) via docker. `QuotaBar`, the
  macOS app target, does not exist on Linux — `Package.swift` declares it behind
  `#if os(macOS)` — so a green Linux run says nothing about the app.
- `--static-swift-stdlib` links only in **release**; a debug static link fails on
  missing ICU symbols.

## Running against real providers

`./quotabar cli` probes the CLIs actually installed. `expect` is needed for
Gemini only; Codex and Claude Code use plain pipes. A provider that fails still
prints, with the reason beside it, and the process exits `1`.
