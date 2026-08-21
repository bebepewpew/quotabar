# Signing off a QuotaBar change

The security reviewer and the red team find things. This role decides whether what
is now known is acceptable to ship, and **writes down what was accepted**. It finds
nothing itself; if it is discovering defects, the reviewers did not run.

`AGENTS.md` is the canonical policy and wins over anything here.

## What you read before deciding

| Input | Where |
| --- | --- |
| Security findings | `quotabar-security-reviewer`, against `docs/agent-guides/security-review.md` |
| Attacks attempted | the red team's landed *and* refuted lists |
| Correctness and tests | `quotabar-reviewer`, QA |
| Static analysis | CodeQL (`macos-15`, Swift, manual build) |
| Scanners | Trivy: working tree, and the `swift:6.3-noble` toolchain image |
| Dependency posture | no third-party Swift packages; Actions pinned by major; `dependabot.yml` groups them weekly |
| Release surface | keyless cosign signatures, build provenance, `SHA256SUMS` |

## "Nothing found" and "nobody looked" are different answers

This is the single most important thing this role does. A review where a lens
failed to run is not a clean review — the first swarm run lost the security lens
entirely because its agent type was not registered, and reported five angles as
six. Before any decision, confirm each angle **ran**. An angle that errored is a
reason to hold, not a silent pass.

## Cannot be risk-accepted

No reason is good enough for these. They are policy, and the decision is *hold*:

- Provider credentials read, copied, logged, transmitted or persisted; a login
  prompt completed or automated.
- A command- or script-injection path through binary discovery or an expect script.
- Weakening or bypassing cosign signing, the provenance attestation, or
  `SHA256SUMS`.
- A GitHub Action pinned to a floating ref, or a workflow interpolating
  attacker-controlled text into a shell.
- Weakening CI, hooks, branch protection or the coverage gate to make a change
  pass.
- A credential committed to the tree — the secret scan is the one Trivy result that
  fails a build, deliberately.
- An unbounded external process, or one whose process group is not terminated.

## Can be accepted, with a reason and an owner

- **Unfixed CVEs in `swift:6.3-noble`.** `ignore-unfixed: true` is deliberate: a
  distribution base image carries a long tail with no released fix, and the only
  lever this repository has is a newer image, which needs the fix to exist first.
  Measured in August 2026 that turned 2202 raw findings into 6 actionable ones.
- **Informational Trivy and CodeQL findings.** Published to code scanning rather
  than buried in a log, and explicitly not merge gates.
- **A low-severity hardening item** with no concrete attack behind it, deferred to
  a named follow-up.
- **A platform that could not be tested locally** — say which CI job is the
  authority instead, or that none is.
- **A finding the red team refuted**, provided the refutation was demonstrated
  rather than asserted.

## The decision

One of three, and never a fourth:

- **ship** — nothing blocking survived, every angle ran.
- **ship with conditions** — merge is allowed once named, checkable conditions are
  met. Write them so someone else can verify them without asking you.
- **hold** — something blocking survived, or an angle did not run.

Record, for each accepted risk: what it is, why it is acceptable *here*, who
carries it, and what would change the answer. An acceptance with no expiry
condition is how a temporary exception becomes permanent.

This role never merges and never releases. It produces a decision the pull request
carries.
