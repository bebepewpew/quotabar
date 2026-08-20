# Running tasks in parallel

Several independent changes can be worked at once, each in its own git worktree,
so agents never touch each other's files. Both toolchains do the same thing:

| | Claude Code | Codex |
| --- | --- | --- |
| Entry point | `.claude/workflows/parallel-tasks.js` | `scripts/codex-parallel` |
| Isolation | `isolation: 'worktree'` per agent | `git worktree add` per task |
| Who runs the gate | the implementing agent, then a reviewer | the script itself |
| Result | a pull request per task that passes | the same |

## When this is the right tool

Two or more changes that **do not touch the same code**. One task is faster done
directly. Tasks that depend on each other must not be run this way — they will
conflict, and the second one will be reviewing a base that no longer exists.

## Claude Code

```
Workflow: parallel-tasks
args: ["add a KDE tray icon", "cache provider discovery between refreshes"]
```

One agent owns each task from first edit to pushed branch — implement, gate,
commit, push. It is deliberately not split across stages, because a later agent
gets a *different* worktree and would not see the work. `quotabar-reviewer` then
reads each pushed branch, and a PR is opened only for tasks that passed both the
gate and the review. Anything held back is reported with the reason.

## Codex

```sh
scripts/codex-parallel "add a KDE tray icon" "cache provider discovery"
scripts/codex-parallel --clean
```

Codex has no workflow engine, so this is a shell fan-out over `codex exec -C
<worktree>`. Two deliberate differences:

- Codex runs under the **`workspace-write` sandbox**, so it can edit inside its
  worktree and nowhere else. It therefore cannot run the docker build, which is
  why the script runs `./quotabar build`, `./quotabar test` and `git diff --check`
  itself. The gate is enforced, not self-reported.
- Codex is told **not** to commit, push or open a PR. The script does that, only
  after the gate passes.

`QUOTABAR_CODEX_APPROVE=1` adds `--approve-for-me` so Codex does not stop for
approval. It is off by default — unattended auto-approval should be a choice.

## What it leaves behind

Worktrees live in `../quotabar-worktrees/<slug>`, beside the repository rather
than inside it, and are **kept** when a task fails so the failure can be
inspected. `--clean` removes them; it deletes a task branch only if git considers
it merged, and reports any branch it kept.

A task that fails the gate never gets a pull request. That is the point: parallel
work multiplies the cost of a bad branch reaching review.
