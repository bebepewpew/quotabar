# Building and validating QuotaBar

Always go through `./quotabar`. It picks the right toolchain per platform and
falls back to the upstream Swift container when the machine has no usable one,
so a Linux box without Swift still builds and a macOS box without full Xcode
still tests. Invoking `swift` or `docker` directly bypasses that and produces
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

**The Linux CI job fails below 90% region.** The threshold was switched on only
once the suite cleared it — 95.18% region and 98.27% line at the time — so it has
never been a gate `main` could not pass. Raise it when the code genuinely supports
a higher number; never exclude a file to reach one, and never lower it to land a
change.

Things worth knowing before you touch it:

- Only `QuotaCore` and `QuotaTray` are measured. They are the libraries the test
  binary links; the CLI and the macOS app are separate executables the tests do
  not link, so a percentage here says nothing about them.
- The report goes to stdout and everything else to stderr, so
  `./quotabar coverage > report.txt` captures the report alone. CI appends it to
  `$GITHUB_STEP_SUMMARY` and uploads the lcov file as an artifact.
- `llvm-cov` must be the toolchain that wrote the profile, so whenever the suite
  runs in the container the whole script does, not just `swift test`
  (`docker_run` in `./quotabar` runs any command there). Paths you pass, `--lcov`
  included, are then container paths under `/workspace`: keep them relative to
  the repository root.
- macOS reaches `llvm-cov` through `xcrun`, so with full Xcode installed the
  report is a macOS one. Without it, `./quotabar coverage` takes the container
  path with the same caveat as `./quotabar test` — no app target in it.
- The lcov file is a build artifact. Write it somewhere you will not commit.

## Platform truths worth knowing

- **macOS:** full Xcode runs the whole suite, the app target included, and
  nothing else can. Command Line Tools ship neither XCTest nor Swift Testing, so
  with only those `./quotabar test` and `./quotabar coverage` run in the
  container instead when docker is installed, printing the caveat first. Report
  that as what it is: the app was not tested. With no docker either they refuse
  with exit 2, GitHub Actions is the only authority, and you say so plainly
  rather than implying the suite ran.
- **Linux:** runs natively if Swift is installed, otherwise inside
  `$QUOTABAR_SWIFT_IMAGE` (default `swift:6.3-noble`) via docker. `QuotaBar`, the
  macOS app target, does not exist on Linux — `Package.swift` declares it behind
  `#if os(macOS)` — so a green Linux run says nothing about the app, and neither
  does a green container run on macOS.
- **The container shares `.build` with the host**, because it bind-mounts the
  repository. SwiftPM keeps products in per-triple subdirectories, so the two do
  not overwrite each other, but they do share the manifest cache and the
  `debug`/`release` symlinks: alternating between a host build and a container
  run on the same machine can cost a rebuild.
- `scripts/wrapper-tests` covers that selection logic — which toolchain the
  wrapper picks, what it forwards and what it refuses — against a stubbed `uname`
  and `docker`, so it compiles nothing and starts no container. Run it after
  editing `./quotabar`; CI runs it in the `Repository policy` job. The branches
  behind an installed full Xcode are the one thing it cannot reach.
- `--static-swift-stdlib` links only in **release**; a debug static link fails on
  missing ICU symbols.

## Running against real providers

`./quotabar cli` probes the CLIs actually installed. `expect` is needed for
Gemini only; Codex and Claude Code use plain pipes. A provider that fails still
prints, with the reason beside it, and the process exits `1`.
