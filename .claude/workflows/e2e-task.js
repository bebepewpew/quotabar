export const meta = {
  name: 'e2e-task',
  description: 'Take one QuotaBar request from scope to an open pull request: shape it, design it, build it, assure it from every angle, remediate what survives refutation, sign it off, then publish.',
  whenToUse: 'When a change should go end to end without a person relaying between roles. Pass {request: "..."} as args, or just the request string. Not for a trivial edit, and not for two unrelated changes — parallel-tasks is for those.',
  phases: [
    { title: 'Shape', detail: 'product scopes it, or refuses it' },
    { title: 'Design', detail: 'architect picks the seam and the compatibility story' },
    { title: 'Build', detail: 'one developer owns it to a pushed branch' },
    { title: 'Assure', detail: 'every angle reads the branch at once' },
    { title: 'Verify', detail: 'each finding is attacked before it is believed' },
    { title: 'Remediate', detail: 'the developer fixes what survived, then it is re-checked' },
    { title: 'Sign-off', detail: 'ship, ship with conditions, or hold' },
    { title: 'Ship', detail: 'open the labelled pull request' },
  ],
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

const input = typeof args === 'string' ? { request: args } : (args || {})
const request = String(input.request || input.task || '').trim()
const maxRounds = Number.isInteger(input.maxRemediation) ? input.maxRemediation : 2
const publish = input.publish !== false

if (!request) {
  log('No request given. Pass {request: "add a projected-exhaustion badge"} as args.')
  return { state: 'noRequest', error: 'no request supplied' }
}

const POLICY = `AGENTS.md is the canonical policy for this repository and it binds you.
Read it before anything else. The rules that most often decide an answer here:
never push to main; treat provider CLI output as untrusted; keep every external
process bounded by a deadline and terminate its complete process group; never read,
log or store provider credentials; keep persisted decoding backward compatible and
storage keys stable; match quota windows on the window key, never the label.`

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------

const SPEC = {
  type: 'object',
  properties: {
    buildable: { type: 'boolean', description: 'false if no provider CLI can supply this, or policy forbids it' },
    reason: { type: 'string', description: 'if not buildable, why — otherwise empty' },
    problem: { type: 'string', description: 'one sentence from the user side' },
    surfaces: { type: 'string', description: 'which of QuotaCore, the macOS menu bar and the CLI are in, and which are deliberately out' },
    criteria: { type: 'array', items: { type: 'string' }, description: 'acceptance criteria, each assertable as a test' },
    outOfScope: { type: 'array', items: { type: 'string' } },
    label: { type: 'string', description: 'exactly one of: feature fix security performance tooling ci documentation docs dependencies "skip changelog"' },
    title: { type: 'string', description: 'pull request title, written as a changelog line' },
    risks: { type: 'string' },
  },
  required: ['buildable', 'reason', 'problem', 'surfaces', 'criteria', 'outOfScope', 'label', 'title', 'risks'],
}

const DESIGN = {
  type: 'object',
  properties: {
    viable: { type: 'boolean', description: 'false if this should not be built in QuotaBar as scoped' },
    reason: { type: 'string', description: 'if not viable, why — otherwise empty' },
    plan: { type: 'string', description: 'what changes in which target, in order' },
    seam: { type: 'string', description: 'StateStore, HistoryStore, neither or both — and why not the other one' },
    compatibility: { type: 'string', description: 'storage keys, decoding, history header, --json and waybar keys' },
    testSurface: { type: 'string', description: 'what becomes a fixture, a boundary assertion, or is only coverable on one platform' },
    risks: { type: 'string', description: 'the one or two decisions a reviewer should push back on' },
  },
  required: ['viable', 'reason', 'plan', 'seam', 'compatibility', 'testSurface', 'risks'],
}

const IMPLEMENTED = {
  type: 'object',
  properties: {
    branch: { type: 'string', description: 'branch that was pushed, empty if nothing was pushed' },
    validated: { type: 'boolean', description: 'true only if build, tests and git diff --check all actually ran and passed' },
    summary: { type: 'string', description: 'one sentence on what changed' },
    details: { type: 'string', description: 'what was done, what failed, what was left out, what could not be run here' },
  },
  required: ['branch', 'validated', 'summary', 'details'],
}

const FINDINGS = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          severity: { type: 'string', description: 'critical | high | medium | low' },
          file: { type: 'string' },
          line: { type: 'string', description: 'line or range, empty if not line-specific' },
          claim: { type: 'string', description: 'one sentence: the defect' },
          failure: { type: 'string', description: 'concrete inputs or conditions -> wrong outcome' },
          fix: { type: 'string', description: 'the smallest change that resolves it' },
        },
        required: ['severity', 'file', 'line', 'claim', 'failure', 'fix'],
      },
    },
  },
  required: ['findings'],
}

const VERDICT = {
  type: 'object',
  properties: {
    survives: { type: 'boolean', description: 'true only if the finding withstands an honest attempt to refute it' },
    reason: { type: 'string' },
    severity: { type: 'string', description: 'corrected severity if the reviewer over- or under-stated it' },
  },
  required: ['survives', 'reason', 'severity'],
}

const REMEDIATED = {
  type: 'object',
  properties: {
    fixed: { type: 'array', items: { type: 'string' }, description: 'the findings addressed, one line each' },
    notFixed: { type: 'array', items: { type: 'string' }, description: 'findings left alone, each with the reason' },
    validated: { type: 'boolean', description: 'true only if the gate ran and passed again' },
    pushed: { type: 'boolean', description: 'true only if the fixes reached origin' },
    details: { type: 'string' },
  },
  required: ['fixed', 'notFixed', 'validated', 'pushed', 'details'],
}

const DECISION = {
  type: 'object',
  properties: {
    decision: { type: 'string', description: 'exactly one of: ship | conditions | hold' },
    rationale: { type: 'string' },
    conditions: { type: 'array', items: { type: 'string' }, description: 'named, checkable conditions when the decision is conditions' },
    acceptedRisks: { type: 'array', items: { type: 'string' }, description: 'each: what it is, why acceptable here, and what would change the answer' },
  },
  required: ['decision', 'rationale', 'conditions', 'acceptedRisks'],
}

const PUBLISHED = {
  type: 'object',
  properties: {
    url: { type: 'string', description: 'pull request URL, empty if none was opened' },
    reason: { type: 'string', description: 'why no PR was opened, empty if one was' },
  },
  required: ['url', 'reason'],
}

// ---------------------------------------------------------------------------
// The angles. Deliberately narrow, for the same reason review-swarm's are: a
// generalist waves through a tautological test because it is not a correctness
// bug, and waves through an unreadable icon because it is not a bug at all.
//
// `worktree` is set only for the two angles that have to *run* something they
// wrote. The rest read the diff, which needs no isolation.
//
// The harness angle is unconditional rather than gated on the paths the diff
// touches: this runner has no shell of its own to compute a diff with, and an
// angle that decides for itself whether to look is the very failure it exists to
// catch. On a change that touches no guide, wrapper, workflow or template it
// reads the diff, finds nothing in its scope, and lands in `anglesWithNothing`.
// ---------------------------------------------------------------------------

const LENSES = [
  { key: 'correctness', agentType: 'quotabar-reviewer', brief:
    'Logic errors, unhandled edge cases, wrong error paths, off-by-one, incorrect state transitions, leaked processes, credentials. Follow docs/agent-guides/review-checklist.md.' },
  { key: 'security', agentType: 'quotabar-security-reviewer', brief:
    'Follow docs/agent-guides/security-review.md exactly. Binary discovery and PATH ordering, Tcl and shell construction, untrusted CLI output, credential handling, child-process lifetime, XDG state, supply chain.' },
  { key: 'tests', agentType: 'quotabar-qa', worktree: true, brief:
    'Do the tests prove what they claim? Hunt tests that cannot fail, and prove it by mutating the code they cover. Check boundaries are exact (79.9/80/94.9/95, 0% and 100%), that parser changes carry the fixtures AGENTS.md requires, and that nothing depends on wall-clock time, ambient PATH or an installed binary.' },
  { key: 'attack', agentType: 'quotabar-red-team', worktree: true, brief:
    'Follow docs/agent-guides/red-team.md. Build the hostile inputs and run them: names that break the executable guard, Tcl metacharacters, terminal control sequences, NaN and 1e9 percentages, catastrophic backtracking, a truncated or foreign history.bin, a state file with wrong types, and a probe killed mid-run. Report landed and refuted separately.' },
  { key: 'ux', agentType: 'quotabar-ux', brief:
    'Follow docs/agent-guides/ux-review.md. Legibility at 16pt and in a 16x16 tray bitmap, a non-colour signal for every state, what renders when a value is missing or nonsense, error and empty states, notification volume, and whether a --json or waybar key changed.' },
  { key: 'performance', agentType: 'quotabar-performance', brief:
    'Follow docs/agent-guides/performance-review.md. Extra process spawns, deadlines and process-group cleanup, anything blocking that reaches the main actor, history.bin growth arithmetic, hot paths through StateStore, and regex backtracking over provider output.' },
  { key: 'delivery', agentType: 'quotabar-devops', brief:
    'Follow docs/agent-guides/ci-and-delivery.md. Workflow and script changes, job permissions, action pinning, the coverage gate, the repository-policy step and executable bits. Name the CI job that would catch a regression in this change, or say plainly that none would.' },
  { key: 'docs', agentType: 'quotabar-writer', brief:
    'Follow docs/agent-guides/docs-writing.md. Does README.md, AGENTS.md, .github/SECURITY.md and docs/ still describe what the code does? Flag a claim this change made false, a documented command that no longer exists, and a behaviour change with no documentation. Policy duplicated outside AGENTS.md is a finding.' },
  { key: 'harness', agentType: 'quotabar-harness-reviewer', brief:
    'Follow docs/agent-guides/harness-review.md. You review the instructions an agent reads before it acts, not the code they describe: docs/agent-guides/, the .claude and .codex wrappers, .claude/workflows/, .claude/settings.json, scripts/codex-parallel, scripts/install-codex-skills, AGENTS.md, CLAUDE.md, GEMINI.md and the issue and pull-request templates. Guidance duplicated instead of pointed at, a role missing on one toolchain or missing its Codex manifest, a description that routes to the wrong role, tools or an allowlist entry beyond least authority, text somebody else wrote treated as instructions, a step with no failure branch so a number gets invented, and a report that turns "did not check" into "nothing found". If this diff touches none of those paths, say so and return an empty list.' },
]

const diffCommands = (branch) => `  git fetch origin main ${branch}
  git diff origin/main...origin/${branch}`

const noCIYet = `CI has not necessarily run this branch, and a workflow that triggers on
pull_request cannot have executed before its pull request exists. That is expected
and is NOT a finding — judge the diff itself.`

// One round of the assurance angles over a pushed branch, each finding attacked
// as soon as its own angle finishes rather than after all of them have.
async function assure(lenses, branch, round) {
  const roundTag = round > 0 ? ` (round ${round + 1})` : ''
  return pipeline(
    lenses,
    (lens) => agent(`
You are reviewing ONE angle of a QuotaBar change, and only that angle.

${POLICY}

ANGLE — ${lens.key}: ${lens.brief}

The work is on branch ${branch}. Read it with:
${diffCommands(branch)}

${lens.worktree ? `You are in your own git worktree, so you may check the branch out and run
things: git checkout -B ${branch} origin/${branch}. Write throwaway tests under
Tests/ to prove a point if you need to, but do NOT commit or push anything — a
later step applies fixes. Never edit Sources/ to make a test pass.` : 'Read the diff and the surrounding code. Do not modify the working tree.'}

${noCIYet}

Other angles cover the other ground, so do not pad your report with theirs. An
empty, honest report is worth more than a padded one — if you find nothing in your
angle, return an empty list.`, {
        label: `assure:${lens.key}${roundTag}`,
        phase: round > 0 ? 'Remediate' : 'Assure',
        agentType: lens.agentType,
        isolation: lens.worktree ? 'worktree' : undefined,
        schema: FINDINGS,
      })
      .then(r => ({ lens: lens.key, findings: (r && r.findings) || [], ran: true }))
      // An angle that errored must never be indistinguishable from one that
      // looked and found nothing. Reporting eight angles as nine is how a gap
      // in coverage gets read as a clean bill of health.
      .catch(e => ({ lens: lens.key, findings: [], ran: false, error: String((e && e.message) || e) })),

    // This stage forwards the run, not a bare array of verdicts. An angle that
    // errored has nothing to attack, so it would arrive here as an empty array —
    // the same empty array an angle that looked and found nothing produces.
    // Dropping the flag here is what made the distinction above unobservable.
    (run) =>
      parallel(run.findings.map(f => () =>
        agent(`
Try to REFUTE this review finding about QuotaBar. Default to refuted when you are
uncertain — the cost of a false finding is a person changing working code.

  severity: ${f.severity}
  file:     ${f.file}:${f.line}
  claim:    ${f.claim}
  failure:  ${f.failure}

Read the actual code on branch ${branch} and the surrounding context. Run something
if it settles it. It survives only if the described failure genuinely occurs.
Correct the severity if it was overstated or understated. ${noCIYet}`, {
          label: `verify:${run.lens}${roundTag}`,
          phase: 'Verify',
          schema: VERDICT,
        })
          .then(v => ({ ...f, lens: run.lens, verdict: v }))
          // An unverifiable finding is surfaced, not silently dropped.
          .catch(e => ({ ...f, lens: run.lens, verdict: null, verifyError: String((e && e.message) || e) }))
      )).then(rows => ({ lens: run.lens, ran: run.ran, error: run.error, rows: rows.filter(Boolean) })),
  ).then(perLens => ({
    rows: perLens.flatMap(run => (run && run.rows) || []).filter(f => f && f.claim),
    runs: perLens.map((run, i) => (run && run.ran)
      ? { key: lenses[i].key, ran: true, error: '' }
      // A stage that threw leaves nothing behind, so an absent entry is a failure too.
      : { key: lenses[i].key, ran: false, error: (run && run.error) || 'the angle produced no result' }),
  }))
}

const RANK = { critical: 0, high: 1, medium: 2, low: 3 }
const severityOf = f => (f.verdict && f.verdict.severity) || f.severity
const isBlocking = f => ['critical', 'high'].includes(severityOf(f))
const describe = f => `${severityOf(f)} [${f.lens}] ${f.file}:${f.line} — ${f.claim} (fix: ${f.fix})`
const firstLine = text => String(text || '').split('\n').find(Boolean) || '(no detail)'

// ---------------------------------------------------------------------------
// Shape
// ---------------------------------------------------------------------------

phase('Shape')
log(`shaping: ${request.slice(0, 90)}`)

const spec = await agent(`
Scope this request for QuotaBar. You write no code.

REQUEST: ${request}

${POLICY}

Follow docs/agent-guides/product-shaping.md. QuotaBar can only show what the local
codex, claude and gemini CLIs are willing to print, and four things are policy
rather than preference: no credentials read or logins completed, no network
requests of its own, Gemini stays terminal-only, and Codex and Claude Code stay on
plain pipes.

Set buildable to false — with the reason — if no provider CLI can supply the data,
or if policy forbids it. Refusing early is worth more than a scope nobody can
close.

Write each acceptance criterion so it could become a test. "Warns when usage is
high" is not one; "warning at 80.0, none at 79.9" is. Choose exactly one category
label, and write the title as a changelog line, because squash-and-merge makes it
the commit subject on main.`, { label: 'shape', phase: 'Shape', agentType: 'quotabar-product', schema: SPEC })

if (!spec || !spec.buildable) {
  const reason = spec ? spec.reason : 'the shaping step did not finish'
  log(`NOT BUILDABLE: ${firstLine(reason)}`)
  return { state: 'specRejected', request, spec: spec || null, reason }
}

log(`scoped as "${spec.title}" [${spec.label}] · ${spec.criteria.length} acceptance criteria`)

// ---------------------------------------------------------------------------
// Design
// ---------------------------------------------------------------------------

phase('Design')

const design = await agent(`
Design this QuotaBar change. You write no production code.

SCOPE
  problem:  ${spec.problem}
  surfaces: ${spec.surfaces}
  criteria: ${spec.criteria.map(c => `\n    - ${c}`).join('')}
  out:      ${spec.outOfScope.map(c => `\n    - ${c}`).join('') || ' (nothing stated)'}
  risks:    ${spec.risks}

${POLICY}

Follow docs/agent-guides/architecture-review.md. Decide the target for each piece,
and the persistence seam if any is touched: StateStore rewrites its whole file on
every write and is wrong for anything that grows; HistoryStore is the append-only
fixed-stride log and is a second seam, not a bypass. State the compatibility story
explicitly — storage keys, backward decoding, the history header, and the --json
and waybar keys, which are a public interface.

Set viable to false, with the reason, if this should not be built in QuotaBar as
scoped. That is a legitimate design output.`, { label: 'design', phase: 'Design', agentType: 'quotabar-architect', schema: DESIGN })

if (!design || !design.viable) {
  const reason = design ? design.reason : 'the design step did not finish'
  log(`DESIGN REJECTED: ${firstLine(reason)}`)
  return { state: 'designRejected', request, spec, design: design || null, reason }
}

log(`design: ${firstLine(design.plan)}`)

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

phase('Build')

// One agent owns the change from first edit to pushed branch. It is deliberately
// not split: a later agent gets a different worktree and would not see work that
// was never pushed.
const impl = await agent(`
Implement this QuotaBar change in your own git worktree.

${POLICY}

SCOPE
  problem:  ${spec.problem}
  surfaces: ${spec.surfaces}
  criteria: ${spec.criteria.map(c => `\n    - ${c}`).join('')}
  out:      ${spec.outOfScope.map(c => `\n    - ${c}`).join('') || ' (nothing stated)'}

DESIGN
  plan:          ${design.plan}
  seam:          ${design.seam}
  compatibility: ${design.compatibility}
  test surface:  ${design.testSurface}

Follow docs/agent-guides/implementing.md. In order:

1. Create a focused branch: feature/<short-kebab-summary> or fix/<short-kebab-summary>.
2. Make the change, and only this change. Something else you notice goes in
   details, not in the diff. Preserve unrelated working-tree changes.
3. Add the tests the design calls for. Parser changes need the fixtures in
   docs/agent-guides/probe-fixture.md; process changes need timeout,
   authentication and cleanup coverage; threshold changes need exact boundaries.
4. Run the gate and stop at the first failure:
     ./quotabar build
     ./quotabar test
     git diff --check
   On macOS the suite needs full Xcode, or docker for the container path that
   skips the app target. If it cannot run, say so in details and set validated
   false rather than claiming it passed.
5. Commit with an imperative subject. Stage files by name, never git add -A.
6. git push -u origin <branch>. Do NOT open a pull request — a later step does.

Set validated true only if all three gate commands actually ran and passed.`, {
  label: 'build', phase: 'Build', agentType: 'quotabar-developer', isolation: 'worktree', schema: IMPLEMENTED,
})

if (!impl || !impl.branch) {
  log(`NOTHING PUSHED: ${impl ? firstLine(impl.details) : 'the build step did not finish'}`)
  return { state: 'buildFailed', request, spec, design, impl: impl || null }
}
if (!impl.validated) {
  log(`GATE FAILED on ${impl.branch}: ${firstLine(impl.details)}`)
  return { state: 'gateFailed', request, spec, design, impl, branch: impl.branch }
}

const branch = impl.branch
log(`built on ${branch}: ${impl.summary}`)

// ---------------------------------------------------------------------------
// Assure, verify, remediate
// ---------------------------------------------------------------------------

phase('Assure')

let lensesToRun = LENSES
let all = []
const runsByLens = new Map()
const remediations = []
let round = 0

while (true) {
  const { rows, runs } = await assure(lensesToRun, branch, round)
  for (const r of runs) runsByLens.set(r.key, r)
  // A re-checked angle replaces its previous result rather than doubling it.
  const rechecked = new Set(lensesToRun.map(l => l.key))
  all = all.filter(f => !rechecked.has(f.lens)).concat(rows)

  const surviving = all.filter(f => f.verdict && f.verdict.survives)
  const blocking = surviving.filter(isBlocking)
  log(`round ${round + 1}: ${rows.length} raised · ${surviving.length} survived · ${blocking.length} blocking`)

  if (blocking.length === 0 || round >= maxRounds) break

  phase('Remediate')
  const fix = await agent(`
Fix what survived review on branch ${branch}. Nothing else.

${POLICY}

You are in a fresh worktree, so check the branch out first:
  git fetch origin ${branch} main
  git checkout -B ${branch} origin/${branch}

BLOCKING FINDINGS
${blocking.map(f => `  - ${describe(f)}`).join('\n')}

Also worth fixing if it is cheap and safe (not blocking):
${surviving.filter(f => !isBlocking(f)).map(f => `  - ${describe(f)}`).join('\n') || '  (none)'}

Apply the smallest change that resolves each blocking finding, and add a test that
would have caught it. Do not refactor around it, and do not fix anything nobody
raised. If you believe a finding is wrong, leave it and say why in notFixed — a
reasoned refusal is a valid outcome and better than a change that breaks something.

Re-run the whole gate and stop at the first failure:
  ./quotabar build
  ./quotabar test
  git diff --check

Commit with an imperative subject, stage files by name, and push to the same
branch. Set validated and pushed only for what actually happened.`, {
    label: `remediate ${round + 1}`, phase: 'Remediate', agentType: 'quotabar-developer', isolation: 'worktree', schema: REMEDIATED,
  })

  remediations.push(fix || { fixed: [], notFixed: [], validated: false, pushed: false, details: 'the remediation step did not finish' })

  if (!fix || !fix.pushed || !fix.validated) {
    log(`remediation ${round + 1} did not land: ${fix ? firstLine(fix.details) : 'the step did not finish'}`)
    break
  }

  log(`remediation ${round + 1}: fixed ${fix.fixed.length}, left ${fix.notFixed.length}`)
  // Re-check only the angles that raised something blocking. The others read a
  // diff that has not changed in the way they care about.
  const touched = new Set(blocking.map(f => f.lens))
  lensesToRun = LENSES.filter(l => touched.has(l.key))
  round += 1
}

const lensRuns = LENSES.map(l => runsByLens.get(l.key) || { key: l.key, ran: false, error: 'the angle never ran' })
const failedLenses = lensRuns.filter(l => !l.ran)
const survived = all.filter(f => f.verdict && f.verdict.survives)
const refuted = all.filter(f => f.verdict && !f.verdict.survives)
const unverified = all.filter(f => !f.verdict)
const blocking = survived.filter(isBlocking)

survived.sort((a, b) => (RANK[severityOf(a)] ?? 9) - (RANK[severityOf(b)] ?? 9))

for (const l of failedLenses) log(`ANGLE DID NOT RUN — ${l.key}: ${l.error}. This covered ${LENSES.length - failedLenses.length} of ${LENSES.length} angles.`)
for (const f of unverified) log(`unverified: [${f.lens}] ${f.file} — ${f.claim}`)
for (const f of survived) log(describe(f))

// ---------------------------------------------------------------------------
// Sign-off
// ---------------------------------------------------------------------------

phase('Sign-off')

const signoff = await agent(`
Decide whether this QuotaBar change is acceptable to ship. You find nothing
yourself; you decide about what is already known, and record what is accepted.

${POLICY}

CHANGE: ${spec.title} — ${impl.summary}
BRANCH: ${branch}

ANGLES COVERED: ${lensRuns.filter(l => l.ran).map(l => l.key).join(', ') || 'none'}
ANGLES THAT DID NOT RUN: ${failedLenses.map(l => `${l.key} (${firstLine(l.error)})`).join('; ') || 'none'}

SURVIVED REFUTATION
${survived.map(f => `  - ${describe(f)}`).join('\n') || '  (nothing)'}

REFUTED, do not re-raise
${refuted.map(f => `  - [${f.lens}] ${f.claim} — ${firstLine(f.verdict.reason)}`).join('\n') || '  (nothing)'}

UNVERIFIED — the refutation step itself failed
${unverified.map(f => `  - [${f.lens}] ${f.file} — ${f.claim}`).join('\n') || '  (nothing)'}

REMEDIATION
${remediations.map((r, i) => `  round ${i + 1}: fixed ${r.fixed.length}, left ${r.notFixed.length}${r.notFixed.length ? ' — ' + r.notFixed.join('; ') : ''}`).join('\n') || '  (none needed)'}

Follow docs/agent-guides/risk-signoff.md. "Nothing found" and "nobody looked" are
different results: an angle that did not run is a reason to hold, not a silent
pass. Some things cannot be risk-accepted at any severity — credentials read,
logged or stored, a login automated, injection through discovery or an expect
script, weakened signing or provenance, a floating action ref, or a gate disabled
to make this pass.

Return exactly one of ship, conditions or hold. Write each condition so someone
else can check it without asking you, and each accepted risk with why it is
acceptable here and what would change the answer.`, {
  label: 'sign-off', phase: 'Sign-off', agentType: 'quotabar-ciso', schema: DECISION,
})

const decision = signoff && signoff.decision ? String(signoff.decision).toLowerCase() : 'hold'
log(`sign-off: ${decision}${signoff ? ' — ' + firstLine(signoff.rationale) : ' (the sign-off step did not finish)'}`)

const shape = () => ({
  state: '',
  request,
  branch,
  title: spec.title,
  label: spec.label,
  spec,
  design,
  impl,
  remediations,
  // Not a clean bill of health if an angle never ran.
  complete: failedLenses.length === 0,
  anglesThatFailed: failedLenses,
  anglesWithNothing: lensRuns.filter(l => l.ran).map(l => l.key).filter(k => !all.some(f => f.lens === k)),
  blocking: blocking.length > 0,
  findings: survived.map(f => ({
    severity: severityOf(f), lens: f.lens, file: f.file, line: f.line,
    claim: f.claim, failure: f.failure, fix: f.fix, why: f.verdict.reason,
  })),
  refuted: refuted.map(f => ({ lens: f.lens, file: f.file, claim: f.claim, why: f.verdict.reason })),
  unverified: unverified.map(f => ({ lens: f.lens, file: f.file, claim: f.claim, why: f.verifyError })),
  signoff: signoff || null,
  url: '',
  reason: '',
})

if (decision === 'hold') {
  log(`HELD — the work is on ${branch} and no pull request was opened.`)
  return { ...shape(), state: 'held', reason: signoff ? signoff.rationale : 'the sign-off step did not finish' }
}

if (!publish) {
  log(`publish disabled — the work is on ${branch}, open the pull request by hand: gh pr create --base main --head ${branch} --label "${spec.label}"`)
  return { ...shape(), state: 'awaitingPublish', reason: 'publish was disabled for this run' }
}

// ---------------------------------------------------------------------------
// Ship
// ---------------------------------------------------------------------------

phase('Ship')

const published = await agent(`
Open a pull request for the branch ${branch}.

This step runs in the repository checkout, NOT in the worktree that holds
${branch}, so the branch checked out here is someone else's — very likely main. Do
not rely on the current branch and do not check anything out: the command below
names the head branch explicitly, which is the only reason it targets the right
work.

Use the repository template at .github/pull_request_template.md.

Title (already written as a changelog line, because squash-and-merge makes it the
commit subject on main):
  ${spec.title}

Label — exactly one, and CI fails without it:
  ${spec.label}

Fill in the Summary from the scope and the design:
  problem:       ${spec.problem}
  surfaces:      ${spec.surfaces}
  seam:          ${design.seam}
  compatibility: ${design.compatibility}

Fill in the Validation and Safety checklists **honestly from what was actually
reported**. Do not tick a box for something that was not run. What the implementer
reported: ${impl.details}
${remediations.length ? `Remediation: ${remediations.map((r, i) => `round ${i + 1} — ${r.details}`).join(' | ')}` : ''}

Put this in Notes:
  - review findings that survived refutation: ${survived.map(f => describe(f)).join('; ') || 'none'}
  - findings raised and refuted: ${refuted.length}
  - angles that did not run: ${failedLenses.map(l => l.key).join(', ') || 'none'}
  - sign-off: ${decision}${signoff && signoff.conditions.length ? ` — conditions: ${signoff.conditions.join('; ')}` : ''}
  - accepted risks: ${signoff && signoff.acceptedRisks.length ? signoff.acceptedRisks.join('; ') : 'none'}
  - any limitation, such as the macOS suite not running locally.

If the change adds or edits a GitHub Actions workflow, say plainly in Notes that
this pull request is that workflow's first execution, so a reviewer knows the run
on this PR is the evidence rather than something that already happened.

Run: gh pr create --base main --head ${branch} --title "..." --body "..." --label "${spec.label}"
Return the URL. If it fails, return an empty url and the reason. Do not merge.`, {
  label: 'ship', phase: 'Ship', schema: PUBLISHED,
})

if (!published || !published.url) {
  // The work is finished and pushed; only opening the pull request failed. An
  // earlier runner conflated this with failure and sent people looking in the
  // wrong place when a token expired mid-run.
  const reason = published ? published.reason : 'the publish step did not finish'
  log(`WORK IS COMPLETE, PULL REQUEST NOT OPENED: ${branch}`)
  log(`  reason: ${firstLine(reason)}`)
  log(`  do not re-run — open it with: gh pr create --base main --head ${branch} --label "${spec.label}"`)
  return { ...shape(), state: 'awaitingPublish', reason }
}

log(`opened ${published.url}`)
return { ...shape(), state: decision === 'conditions' ? 'openedWithConditions' : 'opened', url: published.url }
