# Implementing a QuotaBar change

The developer owns one change from the first edit to a pushed branch. Nobody else
can finish it: a later agent gets a different worktree and cannot see work that was
never pushed.

`AGENTS.md` is the canonical policy and wins over anything here. Read it first.

## The loop

1. **Branch.** `feature/<short-kebab-summary>` or `fix/<short-kebab-summary>`.
   Never commit or push to `main`.
2. **Change only this task.** Something else that is broken goes in the report, not
   in the diff. Preserve unrelated working-tree changes — do not rewrite, delete or
   stage them.
3. **Tests alongside.** Parser change → fixtures (`docs/agent-guides/probe-fixture.md`).
   Process change → timeout, authentication and cleanup coverage. Threshold change
   → exact boundaries.
4. **Gate.** Stop at the first failure:

   ```sh
   ./quotabar build
   ./quotabar test
   git diff --check
   ```

5. **Commit.** Imperative subject. Stage files by name — never `git add -A`, which
   is how `.build`, a terminal capture or someone else's work reaches a commit.
6. **Push.** `git push -u origin <branch>`.

Always go through `./quotabar`; it picks the toolchain and keeps `.build` owned by
you. `docs/agent-guides/quotabar-dev.md` has the build and coverage detail.

## Never claim a suite you did not run

On macOS `./quotabar test` needs full Xcode; with only Command Line Tools it
refuses. On Linux it runs natively or in `swift:6.3-noble` via docker. If a suite
could not execute, say so plainly and report the change as unvalidated. A branch
honestly marked "tests did not run here" is worth more than one that claims green.

## The rules that bite while you are typing

- **Untrusted output.** Everything a probe reads is hostile input that looks
  friendly. Normalise terminal controls, clamp percentages to `0...100`, and write
  errors that are concise and actionable — never a raw dump, which is how a token
  ends up in a screenshot.
- **Interpolation.** Anything reaching a Tcl or shell string goes through
  `CommandRunner.tclQuoted`. A missing escape is a command-execution bug.
- **Process cleanup.** Deadline plus termination of the *complete process group* —
  `Process.terminate()` alone orphans grandchildren. Cover every early exit,
  including the branches inside an expect script.
- **Credentials.** Never read, copy, log or store them; never complete a login.
- **Decoding.** New persisted fields use `decodeIfPresent` with a sensible
  fallback, so an older payload still loads. Storage keys do not change.
- **Identity.** Match windows on the window key, never on the label or the reset
  time.
- **Actors.** UI and observable state on the main actor; blocking CLI work off the
  cooperative executor.

## Things that have actually gone wrong here

- `expectScript` is a **non-raw** multiline literal, so `\t`, `\r` and `\n` in it
  are real control characters. A test asserting `contains("[ \\t]+")` looks right
  and always fails.
- `as? NSNumber` on `JSONSerialization` output **does not bridge on Linux**. Read
  numbers through `jsonNumber(_:)`.
- `--static-swift-stdlib` links only in release; a debug static link dies on
  missing ICU symbols.
- A container job defaults to `sh -e`, which has no `pipefail`. Any workflow step
  you add there needs `shell: bash`.
- Adding a script under `scripts/` means adding it to the CI policy step and
  making it executable, or the macOS job goes red on `test -x`.

## Report honestly

Say what changed, what you ran, what passed, what you could not run and why, and
anything you noticed but deliberately did not fix. A truthful failure is worth more
than a broken branch that claims success.
