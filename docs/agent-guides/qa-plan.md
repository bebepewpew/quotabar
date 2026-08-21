# QA for a QuotaBar change

QA is not the correctness reviewer. The reviewer asks whether the code is right;
QA asks whether the tests would *notice* if it were not. Both have caught things
the other waved through.

`AGENTS.md` is the canonical policy and wins over anything here.

## A test that cannot fail is worse than no test

It costs the same to run and it buys a false sense of coverage. Real examples from
this repository:

- A barrier that released on the third **arrival**, regardless of whether the
  earlier waiters had already left — so a serial implementation satisfied it.
- A path assertion that passed only because `/bin` is a symlink to `/usr/bin` in
  the container, and would have gone red on macOS.
- `TrayIconTests.swift:180`, where the reader sliced a chunk payload *using* the
  declared length and then asserted the two were equal.

And one that was **refuted**, which matters just as much: the file's adler32
assertions were called tautological, and are not — the encoder's copy is `private`
and so file-scoped, `@testable` cannot reach it, and mutating the encoder does make
the test fail. Before calling a test tautological, prove it: mutate the code it
covers and show the test stays green.

## What a change owes in tests

| Change | Required |
| --- | --- |
| Parser | fixtures for boundaries, malformed data, terminal redraws, and every supported row form |
| Process | timeout, authentication and cleanup paths where practical |
| Threshold | exact boundaries — 79.9 / 80 / 94.9 / 95 |
| Persistence | an older payload still decodes; a newer file is not damaged |
| Formatting | `0%` and `100%` both render, and they are not the same case |

`docs/agent-guides/probe-fixture.md` has the fixture detail and the parsing traps
this repository has already hit — the screen-reader one-character-per-line shape,
the non-raw `expectScript` literal, `NSNumber` not bridging on Linux, and a Gemini
screen that means two different things.

## Determinism

- Never call a real provider CLI from a test. Parsers stay pure static functions
  taking the raw text plus `now:`, so a test passes its own clock.
- No dependence on wall-clock time, ambient `$PATH`, an installed binary, or the
  filesystem layout of the container. The `/bin` symlink above is what that failure
  looks like.
- A test that needs a temporary directory cleans it up, and does not assume it is
  the only test running.

## Coverage

```sh
./quotabar coverage                       # report on stdout
./quotabar coverage --lcov coverage.lcov  # also write lcov
./quotabar coverage --filter QuotaCore    # anything else is forwarded to swift test
```

- The Linux CI job **fails below 90% region**. It reads the `TOTAL` row of the
  `llvm-cov` report, fourth column.
- Only `QuotaCore` and `QuotaTray` are measured — the libraries the test binary
  links. A percentage here says nothing about the CLI or the macOS app.
- Raise the threshold when the code genuinely supports a higher number. **Never
  exclude a file to reach one**, and never delete a hard test to protect an average.
- Coverage is a map of what was executed, not of what was asserted. A line touched
  by a test with no assertion is still untested; treat a jump in coverage with no
  new assertions as a smell.

## What to report

The plan and the result, separately:

1. What you tested and what you deliberately did not.
2. What you actually ran, on which platform, and the outcome — never claim a suite
   that did not execute.
3. Tests you judged unfalsifiable, with the mutation that proves it.
4. Gaps you are leaving open, and why they are acceptable.
