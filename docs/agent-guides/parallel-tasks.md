# Running tasks in parallel

Several independent changes can be worked at once, each in its own git worktree,
so agents never touch each other's files. Both toolchains do the same thing:

| | Claude Code | Codex |
| --- | --- | --- |
| Entry point | `.claude/workflows/parallel-tasks.js` | `scripts/codex-parallel` |
| Isolation | `isolation: 'worktree'` per agent | `git worktree add` per task |
| Who runs the gate | the implementing agent, then a reviewer | the script itself |
| Worktrees | `.claude/worktrees/` | `../quotabar-worktrees/` |
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

**Resolving it by name only works in a session that started after the file
existed** — the workflow registry is built at startup. In the session that adds or
moves it, pass the path instead:

```
Workflow: {scriptPath: ".claude/workflows/parallel-tasks.js", args: [...]}
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

## Reading the result

Four outcomes, and the difference matters:

| State | Meaning |
| --- | --- |
| `opened` | gate and review passed, pull request is open |
| `awaitingPublish` | **the work is finished and pushed** — only opening the PR failed, e.g. an expired token. Do not re-run it; open the PR by hand |
| `reviewBlocked` | the branch exists but review found something that must be fixed first |
| `failed` | the gate did not pass, or the agent did not finish |

`awaitingPublish` exists because an earlier run conflated it with failure: a token
expired mid-run and three complete branches were reported the same way as broken
ones.

## Labels are not optional

Every pull request the runner opens carries exactly one category label, because a
label check fails the PR without one and the label decides which section of the
release notes the change appears in. The publish step passes `--label`, and the
PR title is written as a changelog line rather than a diff summary — squash-merge
means that title is what a reader sees.

If a PR ever arrives unlabelled, the check is doing its job: fix the label rather
than the check.

## What it leaves behind

The two runners keep worktrees in different places:

- **Claude Code:** `.claude/worktrees/<run-id>-<n>`, created and named by the
  workflow engine.
- **Codex:** `../quotabar-worktrees/<slug>`, beside the repository.

Both **keep** a worktree when a task fails so the failure can be inspected.
`scripts/codex-parallel --clean` removes the Codex ones; it deletes a task branch
only if git considers it merged, and reports any branch it kept. Claude worktrees
are removed with `git worktree remove` once their branch is merged or pushed.

A task that fails the gate never gets a pull request. That is the point: parallel
work multiplies the cost of a bad branch reaching review.
