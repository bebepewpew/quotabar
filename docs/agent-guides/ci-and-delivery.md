# CI and delivery for QuotaBar

Four workflows, and each is authoritative for something different. Changing one
without knowing which is how a gate quietly stops gating.

`AGENTS.md` is the canonical policy and wins over anything here.

| Workflow | Triggers | Authoritative for |
| --- | --- | --- |
| `ci.yml` | push to `main`, every pull request, and `labeled`/`unlabeled` | the **Gate** every merge waits on: the **Labels** check, the repository-policy check, build and test on macOS and Linux, the CLI smoke test, and the 90% region coverage gate |
| `codeql.yml` | called by `ci.yml`, plus weekly | Swift static analysis. macOS only, because that is the one host where a single build covers all four targets |
| `security-scan.yml` | push, pull request, Mondays 06:17 UTC | leaked secrets (the only failing result), plus informational working-tree and toolchain-image findings |
| `release.yml` | `workflow_dispatch` only | building, signing, tagging and publishing a release, and pushing the Homebrew tap |

## The Labels gate

Release notes are generated from merged pull requests and grouped by label
(`.github/release.yml`), so the `labels` job requires **exactly one** of:

    feature | fix | security | performance | tooling | ci | documentation | docs
    dependencies | skip changelog

It counts only labels in that set: a label it does not recognise is ignored
rather than failing the pull request, which is what lets the triage labels
`needs-info` and `provider-limited` exist without colliding with the gate.

`documentation` and `docs` are both allowed on purpose — GitHub creates the first
with a new repository — and both map to the same section. The allowed set is
written out in six places that must change together: this job (the copy that
actually fails a pull request), `.github/release.yml`, the tables in
`.github/CONTRIBUTING.md` and `README.md`, the list in
`docs/agent-guides/product-shaping.md`, and — since issues carry the same label
the closing pull request will — `docs/agent-guides/backlog.md` and the dropdown
in `.github/ISSUE_TEMPLATE/task.yml`.

The policy job also runs `scripts/wrapper-tests`, which checks which toolchain
`./quotabar` selects per platform against a stubbed `uname` and `docker`. It
compiles nothing and starts no container, so it belongs beside the structural
checks rather than in the build jobs — and it is the only check that covers the
wrapper at all, since the wrapper is what starts the suite the other jobs run.

The issue forms have a check of their own, in the policy job: the three forms and
`config.yml` must exist, be non-empty and keep their top-level keys. Nothing
parses them, so **no job would catch a form that is valid YAML in the wrong
shape, or one whose `id`s collide** — GitHub reports that in its own UI when
somebody tries to file. `blank_issues_enabled` flipping to `true` is likewise
uncaught beyond the key still being present.

Two details in `ci.yml` exist only for this job. `pull_request` lists `labeled`
and `unlabeled` in its `types`, or a pull request held back for a missing label
would stay red until its next push, long after someone applied the label. And the
`concurrency` group cancels superseded pull-request runs, because a label usually
lands moments after `opened` and each correction would otherwise leave a full
macOS and Linux build running beside the one replacing it.

## The Gate, and why the required check is not a build

`ci.yml` has six jobs, and only one of them is a required status check.

`changes` diffs the pull request against its base and decides whether anything
compiled was touched. If not — documentation, `.claude/`, `.codex/`, the issue
forms, a root `*.md` — then `build-and-test` and `build-and-test-linux` are
skipped, and a documentation change stops holding a macOS runner. `policy` has no
such guard and runs for everything, which matters precisely *because* it is the
documentation-shaped change that can break an issue form or unset an executable
bit. A push to `main` always runs the full suite.

`changes` sorts every changed path into three buckets, and the third is the
point. **Builds:** `Sources/`, `Tests/`, `Package.swift`, `Package.resolved`, the
`quotabar` wrapper, `scripts/coverage` — and `.github/workflows/`, because a
pipeline change is only ever proven by running it. **Skips:** `docs/`,
`.claude/`, `.codex/`, `.githooks/`, the issue forms, any `*.md`, `LICENSE`,
`.gitignore`, `.gitattributes`, the two Codex scripts, and the `.github` files
that configure GitHub rather than the build. **Unclassified:** anything else — it
builds, *and the job prints it by name*, which is the signal that the case
statement needs a line rather than a silent guess in either direction.

Both lists are explicit on purpose. An include-only list fails towards skipping,
which is how a real change stops being tested; an exclude-only list fails towards
building, which is how the whole mechanism quietly stops saving anything. Naming
both leaves a bucket that can complain.

`gate` is the required check. Two GitHub behaviours force that shape:

- a workflow stopped by `paths-ignore` never reports at all, so a check required
  by branch protection stays **pending** and the pull request is unmergeable
  rather than fast — which is why the filtering is a job, not a path filter;
- `if: success()` on an aggregating job makes that job skip as soon as anything
  it needs is skipped, and a skipped required check satisfies nothing. `gate`
  inspects `needs.*.result` itself instead, counting `skipped` as a pass and
  everything that is not `success` as a failure.

CodeQL is a called workflow rather than one with its own `pull_request` trigger,
for the same reason. `gate` can only `needs:` jobs in its own workflow, so
`ci.yml` invokes `codeql.yml` with `uses:` and gates the call — which puts Swift
analysis behind the same `changes` filter and under the same required check. The
alternative, a `paths-ignore` in `codeql.yml`, works only while nothing requires
that check and becomes a permanent block the moment somebody does. Its weekly
cron still fires standalone: a scheduled run has no base to diff against.

Branch protection on `main` therefore requires **`Gate`** and **`Labels`**, not
the two build jobs and not `CodeQL`. Renaming a job in this file without renaming it there is how
a merge blocks on a check that no longer exists; adding a job means adding it to
`gate`'s `needs`, or it cannot fail a merge.

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
  job, along with `test ! -e REVIEW.md`. A new script needs `chmod +x` *and* a
  line in that job.
- **A job added without a line in `gate`'s `needs`** runs, goes red, and blocks
  nothing: the only required check never learns it failed.
- **`always()` on the gate reports a red check for a cancelled run.** The
  `concurrency` group cancels a superseded run every time a label lands just
  after `opened`, and `always()` runs even then — so the gate failed on a run
  nobody was waiting on, next to a live run that was still building. `gate` uses
  `if: ${{ !cancelled() }}`, which keeps skip-is-a-pass and lets a cancelled run
  stay cancelled. This one was caught by the pull request that introduced it.

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
