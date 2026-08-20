# Building and validating QuotaBar

Always go through `./quotabar`. It picks the right toolchain per platform, and on
Linux falls back to the upstream Swift container so a machine without Swift still
builds. Invoking `swift` or `docker` directly bypasses that and produces
`.build` artifacts owned by the wrong user.

```sh
./quotabar build     # compile everything this platform supports
./quotabar test      # run the suite
./quotabar coverage  # run the suite with coverage and print the report
./quotabar cli ...   # run the quotabar CLI against real provider CLIs
./quotabar run       # macOS only: build and launch the menu-bar app
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

## Coverage

`./quotabar coverage` runs `scripts/coverage`, which re-runs the suite with
`swift test --enable-code-coverage` and prints an `llvm-cov` report for the
sources under `Sources/`, ignoring `Tests/` and `.build/`.

```sh
./quotabar coverage                       # report on stdout
./quotabar coverage --lcov coverage.lcov  # also write lcov, for upload
./quotabar coverage --filter QuotaCore    # anything else goes to `swift test`
```

At the time it was added the totals were **63.52% region / 73.19% line** (721
regions, 1518 lines, on Linux). There is **no threshold**: CI reports the numbers
and does not fail on them. Enforcement is a separate change.

Things worth knowing before you touch it:

- Only `QuotaCore` and `QuotaTray` are measured. They are the libraries the test
  binary links; the CLI and the macOS app are separate executables the tests do
  not link, so a percentage here says nothing about them.
- The report goes to stdout and everything else to stderr, so
  `./quotabar coverage > report.txt` captures the report alone. CI appends it to
  `$GITHUB_STEP_SUMMARY` and uploads the lcov file as an artifact.
- `llvm-cov` must be the toolchain that wrote the profile, so on Linux without
  Swift the whole script runs inside the container, not just `swift test`
  (`docker_run` in `./quotabar` runs any command there). Paths you pass, `--lcov`
  included, are then container paths under `/workspace`: keep them relative to
  the repository root.
- macOS reaches `llvm-cov` through `xcrun`, so `./quotabar coverage` needs full
  Xcode there for the same reason `./quotabar test` does.
- The lcov file is a build artifact. Write it somewhere you will not commit.

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
