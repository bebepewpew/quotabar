---
name: quotabar-dev
description: Build, test and pre-PR validation for QuotaBar, including the Linux/docker path when no Swift toolchain is installed. Use before committing or opening a pull request, or whenever a change needs compiling or testing.
---

# Building and validating QuotaBar

Always go through `./quotabar`. It picks the right toolchain per platform and,
on Linux with no Swift installed, builds inside the upstream Swift container —
invoking `swift` or `docker` directly bypasses that.

```sh
./quotabar build
./quotabar test
git diff --check
```

`AGENTS.md` requires all three before a pull request.

**Full guide — the pre-PR checklist and the platform traps that are easy to get
wrong — is `docs/agent-guides/quotabar-dev.md`. Read it before building.**
