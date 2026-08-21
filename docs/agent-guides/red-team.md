# Attacking QuotaBar

The security reviewer reads the diff and reasons about it. The red team **builds
the input and runs it**. A finding from here comes with a fixture that goes red.

`docs/agent-guides/security-review.md` holds the threat model; read it first — this
guide is about turning it into attacks. `AGENTS.md` wins over both.

## Rules of engagement

- Attacks land in `Tests/`, as fixtures and test cases. **Never edit `Sources/` to
  make an attack work** — that proves nothing about the shipped code.
- No real credentials, ever. Not a copy, not a redacted one, not in a fixture.
- No network. QuotaBar makes no requests of its own, and neither does its test
  suite.
- Nothing outside this repository is a target.
- An attack that fails is a result. Record it so the next run does not repeat it,
  and so a later change that *would* have made it work has something to fail
  against.

## The attack surface, and what to actually try

**Binary discovery.** `CommandRunner.find(_:)` checks explicit known-good paths,
then `$PATH`, then asks an interactive login shell
(`$SHELL -lic 'command -v …'`).

- Feed executable names that break the `^[A-Za-z0-9._+-]+$` guard: `a b`,
  `a;id`, `$(id)`, `a'`, a name with a newline, an empty string, 4 KB of dots.
- Prove the ordering: a hostile `codex` earlier in `$PATH` must lose to the
  explicit known-good path. If a change reorders those, that is the finding.
- Note the scope line from `SECURITY.md`: an attacker who can already write your
  `$PATH` or home directory is out of scope. The **ordering guard itself** is in
  scope, because it is what makes that precondition necessary.

**Script construction.** The Gemini probe interpolates a path into a Tcl script
handed to `expect -c`.

- Push `\`, `"`, `$`, `[`, `]`, `{`, `}`, backtick, newline and `\r` through
  `tclQuoted` and assert the script still parses as one command.
- Any new interpolation that does not go through it is a command-execution bug,
  not a formatting bug.

**Untrusted CLI output.** Everything a probe reads.

- Terminal controls: CSI erase sequences, cursor moves, bracketed-paste markers,
  `\r` overwrites mid-line, and a title-set sequence carrying a payload.
- Numbers: `1e9%`, `NaN`, `Infinity`, `-5%`, `1e400`, `100.0000001%`, a percentage
  with a thousands separator. None may escape into layout arithmetic or the icon
  renderer — clamping is `0...100`.
- Volume: a megabyte on one line, ten thousand rows, no trailing newline, a stream
  that never closes.
- Regex: craft input aimed at catastrophic backtracking in every pattern the change
  touches, and time it.
- Error paths: make a probe fail and check the message. Raw output reaching the
  user is the finding, even when the parse was correct.

**Persistence.** `history.bin` and the state file.

- `history.bin`: truncated mid-record; a stride that does not divide the payload; a
  version from the future; a header that is not ours at all; a zero-length file; a
  file that is a directory; one where the path is a symlink. The rules are precise
  — a newer file is read as far as it can be and **never appended to or deleted**,
  a foreign file is **left alone rather than replaced**, and none of this may turn a
  working refresh into a failure.
- The state file: wrong types for every key, a null where an object is expected,
  a 50 MB blob, keys removed, keys from an older schema. An install must survive.

**Child processes.** A leaked process leaks what it holds.

- Kill the parent mid-probe and look for a surviving grandchild. Killing only the
  direct child has already been observed leaving one holding the output pipe for a
  further 52 seconds.
- Drive every early-exit branch, including the ones inside the expect script, and
  assert the group is gone.
- A provider CLI that hangs, that closes stdout immediately, or that exits 0 with
  no output.

**Supply chain.** Read `.github/workflows/` as an attacker.

- A floating `@main` action is remote code execution into CI.
- A job with `contents: write` that did not need it.
- Anything that weakens cosign signing, the provenance attestation or `SHA256SUMS`.
- A step that would run attacker-controlled text through a shell — a branch name, a
  pull-request title, an issue body.

## Reporting

For each attack: the exact input, what the code did, and whether that is a defect.
Rank by what an attacker gains — **critical** code execution or credential
disclosure, **high** a hijack or injection with a plausible precondition, **medium**
disclosure into logs or UI or an unbounded process, **low** hardening with no
concrete attack behind it.

Separate **landed** (attack works, here is the failing fixture) from **refuted**
(attack tried, defence held, here is the test that proves it). A red team that only
ever reports hits is not being believed twice.
