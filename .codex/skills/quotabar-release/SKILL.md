---
name: quotabar-release
description: Prepare and verify a QuotaBar release — readiness of main, labels and changelog-shaped titles, the dispatch, the artifact and signature set, the Homebrew formula PR, and what to do when a release goes wrong. Use before or after running the release workflow.
---

# Cutting a QuotaBar release

`AGENTS.md` is the canonical policy and wins over anything here.

A release is a deliberate act: `release.yml` is `workflow_dispatch` only and
refuses any ref but `main`. It pushes exactly two kinds of ref — the annotated tag
and a `release/formula-*` branch — and never pushes to `main`.

Before dispatching: `main` green on all three checks, every merged pull request
since the last tag carrying exactly one category label, titles that read as
changelog lines, and a newest tag that is a plain `vMAJOR.MINOR.PATCH` — a `-rc`
suffix sorts above it and stops the run.

**Never re-tag and never force-push a tag.** A failure at or after the tag push
is resumed with "Re-run failed jobs", never re-dispatched.

**The full guide — the run in order, the artifact and signature set, why the
formula builds from source, and the recovery paths — is
`docs/agent-guides/release.md`.**
