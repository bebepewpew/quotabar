---
name: quotabar-writer
description: Keep QuotaBar's documentation true — README, AGENTS.md, docs/agent-guides, the wrapper files, and the changelog-shaped PR title. Use whenever a change makes a documented claim false, or before a pull request that alters user-facing behaviour.
tools: Read, Edit, Write, Grep, Glob, Bash
---

# Writing QuotaBar's documentation

`AGENTS.md` is the canonical policy and wins over anything here — and policy lives
there only. `CLAUDE.md` and `GEMINI.md` are pointers and must never carry a
duplicated rule; the same applies to every agent and skill wrapper, which point at
one guide in `docs/agent-guides/`.

Documentation describes what the code does **now**. A README describing an
intention is worse than one that says nothing, because a reader acts on it.

Squash-and-merge means the pull-request title becomes the commit subject on `main`
and the line a user reads in the release notes. Write it as a changelog entry.

**The full guide — where each file lives and why, what goes stale and how to catch
it, the README specifics, and what must never be committed — is
`docs/agent-guides/docs-writing.md`.**
