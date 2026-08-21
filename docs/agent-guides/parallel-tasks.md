# Running tasks in parallel

Several independent changes can be worked at once, each in its own git worktree,
so agents never touch each other's files. Both toolchains do the same thing:

| | Claude Code | Codex |
| --- | --- | --- |
| Entry point | `.claude/workflows/parallel-tasks.js` | `scripts/codex-parallel` |
| Isolation | `isolation: 'worktree'` per agent | `git worktree add` per task |
| Who runs the gate | the implementing agent, then a reviewer | the script itself |
| Worktrees | `.claude/worktrees/` | `../quotabar-worktrees/` |
| Who picks the category label | the publish agent | the implementing agent, on a `PR-LABEL:` line |
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
scripts/codex-parallel --label tooling "teach the runner to label its PRs"
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

Each agent is asked to end its report with two trailer lines, which the script
reads back — `PR-TITLE:` for the changelog line and `PR-LABEL:` for the category.
`--label <category>` supplies the label for a task whose agent named none.

`QUOTABAR_CODEX_APPROVE=1` adds `--approve-for-me` so Codex does not stop for
approval. It is off by default — unattended auto-approval should be a choice.

`scripts/test-codex-parallel` is the script's own suite. `swift test` never sees
shell, so it runs in the `Repository policy` CI job instead; it sources the
runner without side effects, stubs `gh`, and checks the label handling below.

## Reading the result

The two runners report in their own vocabularies, but the distinction that
matters is the same one: work that is finished and pushed is not a failure, even
when no pull request exists for it.

`parallel-tasks.js` returns four states:

| State | Meaning |
| --- | --- |
| `opened` | gate and review passed, pull request is open |
| `awaitingPublish` | **the work is finished and pushed** — only opening the PR failed, e.g. an expired token. Do not re-run it; open the PR by hand |
| `reviewBlocked` | the branch exists but review found something that must be fixed first |
| `failed` | the gate did not pass, or the agent did not finish |

`awaitingPublish` exists because an earlier run conflated it with failure: a token
expired mid-run and three complete branches were reported the same way as broken
ones.

`scripts/codex-parallel` prints one line per task, `state branch reason`, and
exits non-zero unless every task reached `opened`. It runs no review stage, so it
has no `reviewBlocked`; it splits the failures instead:

| State | Meaning |
| --- | --- |
| `opened` | gate passed, pull request is open, and the label it carries is named in the reason |
| `label-missing` | **finished and pushed**, but no category label was chosen, so no PR was opened. The reason has the `gh pr create` line to run |
| `pr-failed` | **finished and pushed**; `gh pr create` itself failed. Same treatment |
| `gate-failed` | build, tests or `git diff --check` failed. The worktree is kept |
| `push-failed`, `codex-failed`, `worktree-failed` | never got that far; the log is named in the reason |
| `no-changes` | Codex finished and edited nothing |

`label-missing` and `pr-failed` are that runner's `awaitingPublish`: the branch
is on the remote and re-running the task would duplicate the work.

## Labels are not optional

Every pull request either runner opens carries exactly one category label,
because the `Labels` CI job fails a pull request without one and the label
decides which section of the release notes the change appears in. Both also
treat the PR title as a changelog line rather than a diff summary — squash-merge
means that title is what a reader sees.

They get there differently, and the difference shows up when something is
missing:

- **`parallel-tasks.js`** picks the label in its publish step, which is an agent
  told to choose by what the change is and to run `gh pr create … --label
  "<category>"`.
- **`scripts/codex-parallel`** asks each implementing agent to end its report
  with `PR-TITLE:` and `PR-LABEL:` lines, then reads them back. The label is
  matched against the same allowlist the `Labels` job enforces and the matched
  literal is what reaches `gh` — agent text is untrusted, and an unrecognised
  one is no label at all. `--label <category>` on the command line covers a task
  whose agent named none. If nothing valid is found the branch is still pushed,
  but the pull request is **not** opened: it would arrive red. That is the
  `label-missing` state above, and the reason line carries the command to
  finish it by hand.

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
