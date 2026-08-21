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
3. **release** — checks the full artifact set is present, writes `SHA256SUMS`,
   signs every artifact *and* `SHA256SUMS` keylessly with cosign against the
   GitHub OIDC identity, attests build provenance, **refuses to tag a dirty
   checkout**, pushes only `refs/tags/<tag>`, and publishes the GitHub release.
4. **container** — downloads the released Linux tarball and pushes
   `ghcr.io/<repo>:<version>` and `:latest`. The build context is `dist/` only,
   because `.dockerignore` excludes the repository root where an executable zsh
   dev wrapper shares the name `quotabar`.
5. **tap** — renders `packaging/homebrew/quotabar.rb`, the formula source held in
   this repository, into `bebepewpew/homebrew-tap` as `Formula/quotabar.rb`. The
   tap is generated output; an edit made there is overwritten by the next release.

The workflow pushes exactly one ref here: the annotated tag. **It never pushes to
`main`.**

## The tap job, and why it is shaped that way

Every constraint on it was paid for:

- It runs on **macOS** because it `brew install`s the formula before publishing
  it. A Linux runner could push the commit but could not prove it works, which is
  how a placeholder checksum once reached users.
- It re-resolves `refs/tags/<tag>^{}` and **refuses to continue unless it equals
  the released `GITHUB_SHA`**. `concurrency` stops a second run, not a force-moved
  tag between the release job and this one, and everything after that point would
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
  GitHub API *after* `gh release create` has already published. Rate-limited
  there means a live release whose notes point at a formula the tap does not have.

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

- **Never re-tag and never force-push a tag.** A published tag is what signatures
  and provenance are bound to.
- A failed run before the tag step: fix forward on `main` and dispatch again.
- A failed run after the tag exists: cut the **next patch**. The broken version
  number is spent.
- The tap job runs **after** the release is published, so a failure there leaves a
  live release whose install instructions do not work yet. Fix the tap, do not
  re-cut the release.

## Verification is part of the release

The notes tell users to check `SHA256SUMS`, `cosign verify-blob` against the
workflow's certificate identity and the GitHub OIDC issuer, and
`gh attestation verify`. Run at least one of those against a published artifact
before calling the release done — the instructions are only worth publishing if
they work.
