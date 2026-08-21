# CI and delivery for QuotaBar

Four workflows, and each is authoritative for something different. Changing one
without knowing which is how a gate quietly stops gating.

`AGENTS.md` is the canonical policy and wins over anything here.

| Workflow | Triggers | Authoritative for |
| --- | --- | --- |
| `ci.yml` | push to `main`, every pull request, and `labeled`/`unlabeled` | the **Labels** gate, build and test on macOS and Linux, the CLI smoke test, the 90% region coverage gate, the repository-policy check |
| `codeql.yml` | push, pull request, weekly | Swift static analysis. macOS only, because that is the one host where a single build covers all four targets |
| `security-scan.yml` | push, pull request, Mondays 06:17 UTC | leaked secrets (the only failing result), plus informational working-tree and toolchain-image findings |
| `release.yml` | `workflow_dispatch` only | building, signing, tagging and publishing a release, and pushing the Homebrew tap |

## The Labels gate

Release notes are generated from merged pull requests and grouped by label
(`.github/release.yml`), so the `labels` job fails a pull request that carries
anything other than **exactly one** of:

    feature | fix | security | performance | tooling | ci | documentation | docs
    dependencies | skip changelog

`documentation` and `docs` are both allowed on purpose — GitHub creates the first
with a new repository — and both map to the same section. The allowed set appears
in three places that must change together: this job, `.github/release.yml` and the
table in `.github/CONTRIBUTING.md`.

Two details in `ci.yml` exist only for this job. `pull_request` lists `labeled`
and `unlabeled` in its `types`, or a pull request held back for a missing label
would stay red until its next push, long after someone applied the label. And the
`concurrency` group cancels superseded pull-request runs, because a label usually
lands moments after `opened` and each correction would otherwise leave a full
macOS and Linux build running beside the one replacing it.

## Traps this repository has already paid for

- **A container job defaults to `sh -e`, which has no `pipefail`.** Both container
  jobs set `defaults.run.shell: bash` for exactly that reason. A new step there
  without it silently swallows a failing command in a pipeline.
- **`swift:6.3-noble` purges `curl` and ships no `wget`.** Anything that downloads
  in that image installs `curl` first, or the job dies before it packages.
- **A fork's pull request gets a read-only token**, so `upload-sarif` would fail on
  something the contributor cannot fix. The scan still runs; only the upload is
  skipped, via `if: github.event.pull_request.head.repo.fork != true`.
- **A pull request opened with `GITHUB_TOKEN` does not start workflow runs.**
  Anything that opens a pull request from CI has to say so in its own body, or the
  absent checks read as failures.
- **A newly added workflow's first execution is the pull request that adds it.**
  A `pull_request`-triggered workflow cannot have run before its PR existed. Say
  that in the PR rather than letting a reviewer read the absence as a failure.
- **`scripts/` and `.githooks/` entries are asserted executable** by the policy
  step, along with `test ! -e REVIEW.md`. A new script needs `chmod +x` *and* a
  line in that step.

## Pinning

Actions are pinned by **major version**, so patches arrive without a commit.
Two deliberate exceptions:

- `aquasecurity/trivy-action` publishes no moving major tag — it is still 0.x, so
  a release tag is the closest equivalent and Dependabot keeps it current.
- `sigstore/cosign-installer` is pinned to a patch, and pins `cosign-release`
  itself, because the signing flags the release uses are deprecated in newer
  cosign. A floating default would change release behaviour with no commit behind
  it.

A floating `@main` is a remote-code-execution path into CI. It is never acceptable.

## Permissions and secrets

`permissions: contents: read` at the top of each workflow, escalated **per job**
and only where needed — `security-events: write` for SARIF upload,
`contents: write`/`id-token: write`/`attestations: write` for the release job,
`packages: write` for the container push.

The only credentials in play are `GITHUB_TOKEN` and the OIDC identity that keyless
signing derives from. There is no long-lived secret, and adding one is a
supply-chain decision that belongs in the pull request, not in repository settings.

## The coverage gate

The Linux job runs `scripts/coverage --lcov coverage.lcov`, appends the report to
the step summary, reads the `TOTAL` row's fourth column with `awk`, and fails below
`MINIMUM_REGION: '90'`. It measures `QuotaCore` and `QuotaTray` only — the
libraries the test binary links.

The threshold was switched on only once the suite cleared it: 95.18% region and
98.27% line at the time. Raise it when the code genuinely supports a higher number.
Do not exclude files to reach one, and do not lower it to land a change.

## Local hooks are not the gate

`scripts/install-hooks` wires up `.githooks`, and `.claude/settings.json` denies
pushes to `main`. Both are speed bumps for fast feedback. **Branch protection and
CI are the enforcement**, and neither may be weakened to make a change pass.

`.claude/settings.json` allows `./quotabar ...` rather than raw `docker run ...`
deliberately: the wrapper picks the toolchain and keeps `.build` owned by the
invoking user.

## What to report

Which job would catch a regression in what you changed — by name. If the honest
answer is that none would, say so; that is a finding, not a formality.
