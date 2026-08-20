---
name: quotabar-fixtures
description: Add or update test fixtures for QuotaBar's quota parsers (Codex, Claude Code, Gemini). Use whenever probe parsing, the expect script, or provider output handling changes, which AGENTS.md requires fixtures for.
---

# Fixtures for the quota parsers

`AGENTS.md`: *"Parser changes require fixtures for boundaries, malformed data,
terminal redraws, and every supported row form."* Tests live in
`Tests/QuotaCoreTests/QuotaCoreTests.swift` behind `@testable import QuotaCore`.
Never call a real provider CLI from a test.

**Full guide — the required cases, and the parsing traps this repository has
already hit — is `docs/agent-guides/probe-fixture.md`. Read it before writing
or changing a fixture.**
