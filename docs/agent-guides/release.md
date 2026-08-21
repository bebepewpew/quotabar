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
   v-tag, fails if that tag already exists, and refuses to bump from a tag that has
   no published GitHub release, because that is an unfinished release to resume
   rather than a version to bump from.
2. **build-linux** and **build-macos** — stamp the version into
   `Sources/QuotaBarCLI/Arguments.swift` and `Resources/Info.plist`
   **without committing it**, so the tag still points at the untouched commit the
   run started from. Linux builds `--static-swift-stdlib` (release only; a debug
   static link dies on missing ICU symbols) and asserts no `libswift` remains in
   `ldd`. macOS builds `--arch arm64 --arch x86_64` and asserts both slices.
   Both assert `quotabar --version` equals the computed version.
3. **tag** — **refuses to tag a dirty checkout**, then pushes only
   `refs/tags/<tag>`, pointing at the commit the run started from — leaving a tag
   that already resolves to this run's commit alone, so the job can be re-run, and
   refusing one that resolves to anything else. Its own job, because the two jobs
   after it both need the tag to already exist.
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

**Never re-tag, never force-push a tag, and never delete one.** A published tag is
what signatures and provenance are bound to, and the Homebrew formula may already
point at its source archive.

The **tag** job is the line that decides the recovery, because it runs two jobs
before anything is published:

- **A failure before it.** Nothing happened: no tag, no formula, no release. Fix
  forward on `main` and dispatch again; the version number is still free.
- **A failure at it or after it.** The version number is spent, but all that
  exists is an annotated tag, its automatic source archive, and possibly a tap
  commit. Users see none of that unless they were already looking at tags.

For a failure at or after the tag, **resume the run — open it and choose "Re-run
failed jobs" — rather than dispatching a new one.** A re-run reuses the outputs of
the jobs that succeeded, so it carries on against the tag that already exists
instead of cutting a version beside it, and the build artifacts are still on the
run. Two jobs are written for exactly that and say so in their comments: `tag`
re-resolves the tag and leaves one that already points at the released commit
alone — refusing one that points anywhere else — and `tap` treats an unchanged
formula as a proven no-op.

The `version` job enforces it. If the tag it would treat as `previous` has no
published GitHub release, it refuses to bump and names "Re-run failed jobs" as the
recovery, because dispatching again would cut a new version on top of a
half-released one and hand it an empty changelog — `--notes-start-tag` would then
span no merged pull requests. Re-running does not re-run `version` at all, so the
guard never stands in the way of resuming.

A re-run only rescues a **transient** failure: a rate-limited `brew audit
--online`, a network timeout, a `brew install` that hit the 45-minute bound. **A
real defect in the formula, the workflow or the sources cannot be re-run away**,
because every job checks out the commit the run started from. Fix it on `main`,
and then close the orphan tag out before cutting the next patch — the guard above
refuses the dispatch for as long as that tag has no release behind it. Publish a
GitHub release for the orphan tag, saying in one line that the run failed and the
version is spent, and leave the tag itself alone: the tap may already serve a
formula that builds from its source archive.

The one case a re-run cannot resolve on its own is a `gh release create` that
published the release and then failed part-way through its uploads: re-running the
job hits a release that already exists. Delete the **release**, never the tag, then
re-run the job.

A `tap` job that pushed and a `release` job that then failed leaves the tap serving
a version with no GitHub release. `brew install` still works — the formula builds
from the tag's source archive — so resume the run rather than reaching for the tag.

## Verification is part of the release

The notes tell users to check `SHA256SUMS`, `cosign verify-blob` against the
workflow's certificate identity and the GitHub OIDC issuer, and
`gh attestation verify`. Run at least one of those against a published artifact
before calling the release done — the instructions are only worth publishing if
they work.
