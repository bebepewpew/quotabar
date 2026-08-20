export const meta = {
  name: 'parallel-tasks',
  description: 'Run several independent QuotaBar tasks at once, each in its own git worktree, and open a pull request for every one that passes the AGENTS.md gate and a review.',
  whenToUse: 'When you have two or more changes that do not touch the same code and would otherwise be done one after another. Pass the task descriptions as args: ["add X", "fix Y"]. Not for a single task, and not for tasks that depend on each other.',
  phases: [
    { title: 'Implement', detail: 'one agent per task, each in its own worktree' },
    { title: 'Review', detail: 'quotabar-reviewer reads each pushed branch' },
    { title: 'Publish', detail: 'open a PR per task that passed both' },
  ],
}

const tasks = (Array.isArray(args) ? args : args ? [args] : []).filter(Boolean)
if (tasks.length === 0) {
  log('No tasks given. Pass an array of task descriptions as args, e.g. ["add a KDE tray icon", "cache provider discovery"].')
  return { error: 'no tasks supplied' }
}
log(`${tasks.length} task(s), each in its own worktree`)

const IMPLEMENTED = {
  type: 'object',
  properties: {
    branch: { type: 'string', description: 'branch that was pushed, empty if nothing was pushed' },
    validated: { type: 'boolean', description: 'true only if build, tests and git diff --check all passed' },
    summary: { type: 'string', description: 'one sentence on what changed' },
    details: { type: 'string', description: 'what was done, what failed, what was left out' },
  },
  required: ['branch', 'validated', 'summary', 'details'],
}

const REVIEWED = {
  type: 'object',
  properties: {
    blocking: { type: 'boolean', description: 'true if something must be fixed before this can be merged' },
    findings: { type: 'string', description: 'the findings, or "none"' },
  },
  required: ['blocking', 'findings'],
}

const PUBLISHED = {
  type: 'object',
  properties: {
    url: { type: 'string', description: 'pull request URL, empty if none was opened' },
    reason: { type: 'string', description: 'why no PR was opened, empty if one was' },
  },
  required: ['url', 'reason'],
}

// Each task is owned by one agent from start to push. A later agent would get a
// different worktree and so would not see the work, which is why implement,
// validate and commit are not split across stages.
const implementPrompt = (task, index) => `
You are implementing ONE task in QuotaBar, working in your own git worktree.

TASK ${index + 1}: ${task}

Read AGENTS.md first — it is the canonical policy and it binds you. In particular:
never push to main, treat CLI output as untrusted, keep external processes bounded
and terminate their complete process groups, keep persisted decoding backward
compatible, and add fixtures for any parser change.

Do this, in order:
1. Create a focused branch named feature/<short-kebab-summary> or fix/<short-kebab-summary>.
2. Make the change. Keep it to this task only — do not fix unrelated things you notice.
   Mention them in details instead.
3. Add or update tests. AGENTS.md requires fixtures for parser changes and
   timeout/authentication/cleanup coverage for process changes.
4. Run the gate and do not proceed past a failure:
     ./quotabar build
     ./quotabar test
     git diff --check
   On macOS the test suite needs full Xcode; if it cannot run, say so in details
   and set validated to false rather than claiming it passed.
5. Commit with an imperative subject. Stage files by name, never git add -A.
6. Push the branch: git push -u origin <branch>. Do NOT open a pull request —
   a later step does that.

Return branch, validated, summary and details. Set validated to true only if the
build, the tests and git diff --check all actually ran and passed. If you could
not complete the task, set validated false and explain in details — a truthful
failure is worth more than a broken branch.`

const reviewPrompt = (task, impl) => `
Review the branch ${impl.branch}, which was written to do: ${task}

Fetch and diff it against main:
  git fetch origin ${impl.branch} main
  git diff origin/main...origin/${impl.branch}

Review it against docs/agent-guides/review-checklist.md and AGENTS.md. Report only
what you can point at in the diff. Set blocking true only for something that must
be fixed before merge — a correctness bug, a policy violation, a leaked process, a
missing fixture for a parser change. Style preferences are not blocking.`

const publishPrompt = (task, impl, review) => `
Open a pull request for the branch ${impl.branch}.

Use the repository template at .github/pull_request_template.md. Squash-and-merge
is the only merge method here, so the title must be concise and imperative — it
becomes the commit subject on main.

Task: ${task}
What the implementer reported: ${impl.summary}
Details: ${impl.details}
Review findings: ${review ? review.findings : 'review did not run'}

Fill in the Validation and Safety checklists honestly from what the implementer
reported — do not tick a box for something that was not actually run, and state
any limitation (for example the macOS suite not running locally) in Notes. Put the
review findings in Notes too.

Run: gh pr create --base main --title "..." --body "..."
Return the URL. If it fails, return an empty url and the reason.`

const results = await pipeline(
  tasks,
  (task, _item, index) =>
    agent(implementPrompt(task, index), {
      label: `implement ${index + 1}`,
      phase: 'Implement',
      isolation: 'worktree',
      schema: IMPLEMENTED,
    }),

  (impl, task, index) => {
    if (!impl || !impl.validated || !impl.branch) return { impl, review: null }
    return agent(reviewPrompt(task, impl), {
      label: `review ${index + 1}`,
      phase: 'Review',
      agentType: 'quotabar-reviewer',
      schema: REVIEWED,
    }).then(review => ({ impl, review }))
  },

  ({ impl, review }, task, index) => {
    if (!impl) return { task, published: null, impl: null, review }
    if (!impl.validated) return { task, published: null, impl, review }
    if (review && review.blocking) return { task, published: null, impl, review }
    return agent(publishPrompt(task, impl, review), {
      label: `publish ${index + 1}`,
      phase: 'Publish',
      schema: PUBLISHED,
    }).then(published => ({ task, published, impl, review }))
  },
)

const rows = results.filter(Boolean)
const opened = rows.filter(r => r.published && r.published.url)
const held = rows.filter(r => !r.published || !r.published.url)

log(`${opened.length} pull request(s) opened, ${held.length} held back`)
for (const row of held) {
  const why = !row.impl ? 'the agent did not finish'
    : !row.impl.validated ? 'the gate did not pass'
    : row.review && row.review.blocking ? 'review found something blocking'
    : row.published ? row.published.reason
    : 'unknown'
  log(`held: ${row.task} — ${why}`)
}

return {
  opened: opened.map(r => ({ task: r.task, branch: r.impl.branch, url: r.published.url })),
  held: held.map(r => ({
    task: r.task,
    branch: r.impl ? r.impl.branch : '',
    validated: r.impl ? r.impl.validated : false,
    review: r.review ? r.review.findings : '',
    details: r.impl ? r.impl.details : '',
  })),
}
