# Cutting a QuotaBar release

A release is a deliberate act. `release.yml` is `workflow_dispatch` only — nothing
about it is triggered by a push or a pull request — and it refuses to run from any
ref but `main`.

`AGENTS.md` is the canonical policy and wins over anything here.

## Before dispatching

- `main` is green on CI, CodeQL and the security scan.
- Every merged pull request since the last tag carries exactly one category label.
  The label chooses the release-notes section; an unlabelled merge is invisible in
  the changelog.
- Pull-request titles read as changelog lines. Squash-and-merge means the title
  *is* the commit subject on `main` and the line a user reads in the notes.
- `README.md` still describes what the binary about to be built actually does.
- The newest tag is a plain `vMAJOR.MINOR.PATCH`. The run sorts `-v:refname`, which
  puts a `-rc` suffix **above** the plain version, so a prerelease tag on top stops
  the run with an error rather than being bumped from silently.
- `TAP_TOKEN` is still set on the `tap` environment. `release` waits on `tap` now,
  so a missing token stops the whole release at the first step of that job rather
  than leaving the formula behind a published release.

Then choose `patch`, `minor` or `major`. There is no other input.

## What the run does, in order

1. **version** — refuses a non-`main` ref, derives the next version from the newest
   v-tag, and fails if that tag already exists.
2. **build-linux** and **build-macos** — stamp the version into
   `Sources/QuotaBarCLI/Arguments.swift` and `Resources/Info.plist`
   **without committing it**, so the tag still points at the untouched commit the
   run started from. Linux builds `--static-swift-stdlib` (release only; a debug
   static link dies on missing ICU symbols) and asserts no `libswift` remains in
   `ldd`. macOS builds `--arch arm64 --arch x86_64` and asserts both slices.
   Both assert `quotabar --version` equals the computed version.
3. **tag** — **refuses to tag a dirty checkout**, then pushes only
   `refs/tags/<tag>`, pointing at the commit the run started from. Its own job,
   because the two jobs after it both need the tag to already exist.
4. **tap** — renders the formula from `packaging/homebrew/quotabar.rb` against the
   tagged source archive, then `brew audit`s, `brew install --build-from-source`s
   and `brew test`s it before pushing it to `bebepewpew/homebrew-tap`. The formula
   does **not** live in this repository.
5. **release** — checks the full artifact set is present, writes `SHA256SUMS`,
   signs every artifact *and* `SHA256SUMS` keylessly with cosign against the
   GitHub OIDC identity, attests build provenance, and publishes the GitHub
   release with `gh release create --verify-tag`.
6. **container** — downloads the released Linux tarball and pushes
   `ghcr.io/<repo>:<version>` and `:latest`. The build context is `dist/` only,
   because `.dockerignore` excludes the repository root where an executable zsh
   dev wrapper shares the name `quotabar`.

**`tap` runs before `release`, and that order is the point.** While it ran after,
every `brew` check happened once `gh release create` had already published notes
telling people to `brew install quotabar`, so a formula failure left a live
release whose install instructions did not work — and a release is not retracted.
Now the worst a formula failure costs is a tag nobody used.
`scripts/check-release-order` asserts the shape (`tap` needs `tag`, `release`
needs `tap`, only `tag` pushes the tag, only `release` publishes) and the CI
policy job runs it on every pull request. Run it yourself after editing
`release.yml`; it takes a workflow path as an optional argument.

The workflow pushes exactly one ref here: the annotated tag. **It never pushes to
`main`.**

## The tap job, and why it is shaped that way

Every constraint on it was paid for:

- It runs on **macOS** because it `brew install`s the formula before publishing
  it. A Linux runner could push the commit but could not prove it works, which is
  how a placeholder checksum once reached users.
- It re-resolves `refs/tags/<tag>^{}` and **refuses to continue unless it equals
  the run's `GITHUB_SHA`**. `concurrency` stops a second run, not a force-moved
  tag between the tag job and this one, and everything after that point would
  happily certify substituted source.
- `TAP_TOKEN` lives on a GitHub **environment**, not as a plain repository secret.
  `secrets.*` ignores `permissions:` and is readable by a `workflow_dispatch` run
  on *any* branch — and the "release from main only" guard is in this same file,
  which such a branch would control. An environment's deployment branch policy is
  evaluated by GitHub against the ref, so a modified workflow on a side branch
  cannot reach the token at all. Do not move it to a repository secret.
- `timeout-minutes: 45`, because `concurrency: release` has
  `cancel-in-progress: false` and this is the first job running a third-party
  build of unbounded duration. Without it a hung `brew install` holds the group
  for the default 360 minutes and blocks every later release.
- `HOMEBREW_GITHUB_API_TOKEN` is set because `brew audit --online` calls the
  GitHub API and would otherwise share the runner's IP rate limit. Rate-limited
  there now fails the run *before* anything is published, which costs a version
  number rather than users' install instructions — still worth avoiding.
- It pushes the formula **before the GitHub release exists**, and that is safe:
  the formula builds from `archive/refs/tags/<tag>.tar.gz`, which GitHub
  materializes from the ref, not from the release. That is also why the job
  retries the download — the archive appears a moment after the ref does.

## The artifact set

Four files, and a missing one fails the run:

    quotabar-<version>-linux-x86_64.tar.gz
    quotabar-<version>-macos-universal.tar.gz
    quotabar_<version>_amd64.deb
    quotabar-<version>.x86_64.rpm

plus `SHA256SUMS`, and a `.sig` and `.pem` for each of the five.

The Homebrew formula **builds from source on purpose**: a downloaded Mach-O that
Apple has not notarized picks up `com.apple.quarantine` and Gatekeeper blocks it on
first run, while a binary compiled on the installing machine never carries that
attribute. The trade-off is Xcode 16 as a build dependency, and that trade is
already decided.

## When a release goes wrong

- **Never re-tag, never force-push a tag, and never delete one.** A published tag
  is what signatures and provenance are bound to, and the Homebrew formula may
  already point at its source archive.
- A failed run before the **tag** job: nothing happened. Fix forward on `main` and
  dispatch again; the version number is still free.
- A failed run after the tag exists is the case worth knowing, because the tag is
  pushed two jobs before anything is published:
  - **Nothing is published yet.** No GitHub release, no container image. What
    exists is an annotated tag, its automatic source archive, and possibly a tap
    commit. Users see none of it unless they were already looking at tags.
  - **Transient failure** — a rate-limited `brew audit --online`, a network
    timeout, a `brew install` that hit the 45-minute limit: use **Re-run failed
    jobs** on the same run. The successful jobs keep their outputs, the artifacts
    are still there, and `tag` is skipped rather than repeated. `tap` is written
    to be re-runnable: it re-resolves the tag against `GITHUB_SHA` and treats an
    unchanged formula as a proven no-op.
  - **A real defect in the formula or the workflow** — re-running cannot help,
    because every job checks out the commit the run started from. Fix it on
    `main` and cut the **next patch**; the broken version number is spent. Leave
    the orphan tag alone.
- A `tap` job that pushed and a `release` job that then failed leaves the tap
  serving a version with no GitHub release. `brew install` still works — the
  formula builds from the tag's source archive — so fix forward rather than
  reaching for the tag.

## Verification is part of the release

The notes tell users to check `SHA256SUMS`, `cosign verify-blob` against the
workflow's certificate identity and the GitHub OIDC issuer, and
`gh attestation verify`. Run at least one of those against a published artifact
before calling the release done — the instructions are only worth publishing if
they work.
