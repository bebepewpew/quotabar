---
name: quotabar-devops
description: Review or change QuotaBar's CI and delivery — the four workflows, job permissions, action pinning, the coverage gate, the repository-policy step, hooks and branch protection. Use for anything under .github/, scripts/ or .githooks/, and to name which job would catch a regression.
---

# CI and delivery for QuotaBar

`AGENTS.md` is the canonical policy and wins over anything here. Never weaken CI,
hooks or branch protection to make a change pass.

Four workflows, each authoritative for something different: `ci.yml` (build, test,
CLI smoke, the 90% region coverage gate, the repository-policy step), `codeql.yml`
(Swift analysis, macOS only), `security-scan.yml` (leaked secrets fail; everything
else is informational), `release.yml` (manual dispatch only).

Traps already paid for: a container job defaults to `sh -e` with no `pipefail`;
`swift:6.3-noble` has no `curl`; a fork's PR token is read-only so SARIF upload is
skipped rather than failed; a PR opened with `GITHUB_TOKEN` starts no workflow
runs; a new script needs `chmod +x` **and** a line in the policy step.

**The full guide — the workflow table, the pinning exceptions and why they exist,
permissions, the coverage gate and what local hooks are and are not — is
`docs/agent-guides/ci-and-delivery.md`.**

Always name the job that would catch a regression in what changed. "None would" is
a finding, not a formality.
