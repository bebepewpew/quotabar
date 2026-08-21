# Security policy

## Reporting a vulnerability

Report privately through GitHub's
[security advisories](https://github.com/bebepewpew/quotabar/security/advisories/new)
rather than a public issue. Please include what an attacker gains, the steps to
reproduce, and the version or commit.

This is a personal project maintained in spare time — expect acknowledgement
rather than a guaranteed response time.

## What QuotaBar does, so you can judge the risk yourself

QuotaBar reads quota figures by **executing the AI coding CLIs already installed
on your machine** (`codex`, `claude`, `gemini`) and parsing their output. That is
its whole mechanism, and it shapes the risk:

- It **never reads, copies, logs or stores provider credentials**, and never
  completes a login prompt. Authentication stays entirely inside each vendor's CLI.
- It talks only to those local binaries. It makes no network requests of its own.
- Provider output is treated as untrusted: terminal control sequences are
  stripped, percentages are clamped, and errors are summarised rather than dumped.
- External processes run under a deadline and are terminated as a complete process
  group.
- Persisted state (quota percentages, window keys, notification markers) is stored
  in `UserDefaults` on macOS and `${XDG_CONFIG_HOME:-~/.config}/quotabar/state.json`
  on Linux. Nothing secret is written there.
- Usage history (percentages, timestamps and reset times, retained 120 days) is a
  separate local file: `history.bin` under `~/Library/Application Support/QuotaBar`
  on macOS and `${XDG_STATE_HOME:-~/.local/state}/quotabar` on Linux. It records no
  prompts, filenames or credentials, is never transmitted, and is deleted by
  `quotabar history --clear`.

## In scope

- Command or script injection through binary discovery or the `expect` scripts.
- Anything that causes credentials to be read, logged, transmitted or persisted.
- Privilege or process issues: leaked child processes, unbounded execution.
- Supply-chain issues in the release workflow or its signing.

## Out of scope

- Vulnerabilities in the provider CLIs themselves — report those to their vendors.
- Anything requiring an attacker who can already write to your `$PATH`, home
  directory, or run code as you; at that point QuotaBar is not the weak link.

## Verifying a release

Release artifacts are signed keyless with [cosign](https://docs.sigstore.dev/) and
carry GitHub build provenance, so you can confirm a binary came from this
repository and its release workflow before trusting it.
