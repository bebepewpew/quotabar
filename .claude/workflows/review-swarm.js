export const meta = {
  name: 'review-swarm',
  description: 'Review a branch from several independent angles at once — correctness, security, tests, portability, compatibility, documentation — adversarially verify each finding, then synthesise one ranked report.',
  whenToUse: 'Before merging anything substantial, and any time a single reviewer would plausibly have a blind spot. Pass {target: "<branch or PR number>"} as args, or omit it to review the current branch against main.',
  phases: [
    { title: 'Review', detail: 'one reviewer per angle, in parallel' },
    { title: 'Verify', detail: 'each finding is attacked before it is believed' },
    { title: 'Synthesise', detail: 'dedupe and rank what survived' },
  ],
}

const target = (args && args.target) || 'HEAD'
const diff = target.match(/^\d+$/)
  ? `gh pr diff ${target}`
  : `git fetch origin main ${target === 'HEAD' ? '' : target} && git diff origin/main...${target}`

// Six mandates, deliberately narrow. A generalist reviewer waves through a
// tautological test because it is not a correctness bug; the tests lens exists
// precisely to catch what the correctness lens is not looking for.
const LENSES = [
  { key: 'correctness', agentType: 'quotabar-reviewer', brief:
    'Logic errors, unhandled edge cases, wrong error paths, off-by-one, incorrect state transitions. Follow docs/agent-guides/review-checklist.md.' },
  { key: 'security', agentType: 'quotabar-security-reviewer', brief:
    'Follow docs/agent-guides/security-review.md exactly. Binary discovery and PATH, Tcl/shell construction and quoting, untrusted CLI output, credential handling, child-process lifetime, XDG state, supply chain.' },
  { key: 'tests', brief:
    'Do the tests prove what they claim? Hunt tautologies: a test asserting a function against a copy of its own algorithm, a test that passes whatever the code does, an assertion on a value the test itself computed the same way. Check boundaries are exact, not approximate, and that a comment claiming independent verification is actually true.' },
  { key: 'portability', brief:
    'Platform assumptions. Darwin-only or Glibc-only calls without a guard, POSIX process or filesystem semantics assumed on Windows, hardcoded paths, anything treating "not macOS" as "Linux". QuotaCore must carry no UI framework.' },
  { key: 'compatibility', brief:
    'Persistence and public API. Storage keys, backward-compatible decoding of older payloads, quota-window keys as stable identity rather than labels, and whether an existing install keeps its cache, settings and notification dedup state.' },
  { key: 'docs', brief:
    'Do README.md, AGENTS.md and docs/ still describe what the code does after this change? Flag a claim that is now false, a documented command that no longer exists, and a behaviour change with no documentation.' },
]

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

log(`reviewing ${target} through ${LENSES.length} lenses`)

const perLens = await pipeline(
  LENSES,
  (lens) => agent(`
You are reviewing one angle of a change to QuotaBar, and only that angle.

ANGLE — ${lens.key}: ${lens.brief}

Get the diff with:
  ${diff}

AGENTS.md is the canonical policy. Report only what you can point at in the diff.
Other reviewers cover the other angles, so do not pad your report with theirs —
if you find nothing in your angle, return an empty list and say so. An empty,
honest report is worth more than a padded one.

CI may not have run this branch, and a workflow that triggers on pull_request
cannot have executed before its pull request exists. That is expected and is not
a finding.`, {
      label: `review:${lens.key}`,
      phase: 'Review',
      agentType: lens.agentType,
      schema: FINDINGS,
    })
      .then(r => ({ lens: lens.key, findings: (r && r.findings) || [], ran: true }))
      // A lens that errors must not be indistinguishable from a lens that looked
      // and found nothing. Reporting a five-lens review as six is how a gap in
      // coverage gets read as a clean bill of health.
      .catch(e => ({ lens: lens.key, findings: [], ran: false, error: String((e && e.message) || e) })),

  // Every finding is attacked before it is believed. A reviewer that is wrong
  // costs more than one that is silent, because someone acts on it.
  //
  // This stage forwards the run, not a bare array of verdicts. A lens that
  // errored has nothing to attack, so it would arrive here as an empty array —
  // the same empty array a lens that looked and found nothing produces. Dropping
  // the flag here is what made the distinction above unobservable downstream.
  (run) =>
    parallel(run.findings.map(f => () =>
      agent(`
Try to REFUTE this review finding about QuotaBar. Default to refuted when you are
uncertain — the cost of a false finding is a person changing working code.

  severity: ${f.severity}
  file:     ${f.file}:${f.line}
  claim:    ${f.claim}
  failure:  ${f.failure}

Read the actual code and the surrounding context. Run something if it settles it.
It survives only if the described failure genuinely occurs. Correct the severity
if it was overstated or understated.`, {
        label: `verify:${run.lens}`,
        phase: 'Verify',
        schema: VERDICT,
      })
        .then(v => ({ ...f, lens: run.lens, verdict: v }))
        // An unverifiable finding is surfaced, not silently dropped.
        .catch(e => ({ ...f, lens: run.lens, verdict: null, verifyError: String((e && e.message) || e) }))
    )).then(rows => ({ lens: run.lens, ran: run.ran, error: run.error, rows: rows.filter(Boolean) })),
)

const lensRuns = perLens.map((run, i) => (run && run.ran)
  ? { key: LENSES[i].key, ran: true, error: '' }
  // A stage that threw leaves nothing behind, so an absent entry is a failure too.
  : { key: LENSES[i].key, ran: false, error: (run && run.error) || 'the lens produced no result' })
const failedLenses = lensRuns.filter(l => !l.ran)

const all = perLens.flatMap(run => (run && run.rows) || []).filter(f => f && f.claim)
const survived = all.filter(f => f.verdict && f.verdict.survives)
const refuted = all.filter(f => f.verdict && !f.verdict.survives)
const unverified = all.filter(f => !f.verdict)

for (const l of failedLenses) log(`LENS DID NOT RUN — ${l.key}: ${l.error}. This review covered ${LENSES.length - failedLenses.length} of ${LENSES.length} angles.`)
for (const f of unverified) log(`unverified: [${f.lens}] ${f.file} — ${f.claim}`)

log(`${all.length} raised · ${survived.length} survived · ${refuted.length} refuted · ${unverified.length} unverified`)

const rank = { critical: 0, high: 1, medium: 2, low: 3 }
const severity = f => (f.verdict && f.verdict.severity) || f.severity
survived.sort((a, b) => (rank[severity(a)] ?? 9) - (rank[severity(b)] ?? 9))

for (const f of survived) log(`${severity(f)} [${f.lens}] ${f.file}:${f.line} — ${f.claim}`)

const blocking = survived.filter(f => ['critical', 'high'].includes(severity(f)))

return {
  target,
  // Not a clean bill of health if a lens never ran.
  complete: failedLenses.length === 0,
  lensesThatFailed: failedLenses,
  unverified: unverified.map(f => ({ lens: f.lens, file: f.file, claim: f.claim, why: f.verifyError })),
  blocking: blocking.length > 0,
  findings: survived.map(f => ({
    severity: severity(f), lens: f.lens, file: f.file, line: f.line,
    claim: f.claim, failure: f.failure, fix: f.fix, why: f.verdict.reason,
  })),
  // Kept so a refuted finding is not raised again by the next run.
  refuted: refuted.map(f => ({ lens: f.lens, file: f.file, claim: f.claim, why: f.verdict.reason })),
  lensesWithNothing: lensRuns.filter(l => l.ran).map(l => l.key).filter(k => !all.some(f => f.lens === k)),
}
