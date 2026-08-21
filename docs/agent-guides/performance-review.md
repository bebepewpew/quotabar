# Performance in QuotaBar

QuotaBar spends almost all of its time waiting for someone else's program. That
shapes what "performance" means here: it is about *bounds and blocking*, not about
shaving microseconds off a parser.

`AGENTS.md` is the canonical policy and wins over anything here.

## Where the time actually goes

| Cost | Scale | Notes |
| --- | --- | --- |
| Gemini probe | by far the largest | an interactive TUI driven through `expect`, needing a pseudo-terminal |
| Codex, Claude probes | process spawn plus I/O | plain pipes, no pty |
| Binary discovery | small, but can be large | falls back to `$SHELL -lic 'command -v …'`, which starts an **interactive login shell**; memoised per process by `DiscoveryMemo` |
| Refresh cadence | 5 minutes to 1 hour | multiplied by every enabled provider |
| `--watch` | user-chosen interval | the same probes, forever |
| History append | small and fixed | one fixed-stride record per sample per series |
| `StateStore` write | whole file, every time | fine for settings, wrong for anything hot |

The expensive thing is always "spawn another process". Anything that increases how
often that happens is the change worth arguing about; a tighter loop inside a
parser almost never is.

## Deadlines are correctness, not tuning

Every external process is bounded by a deadline and terminated as a **complete
process group**. Treat both as invariants:

- Raising a deadline to make a flaky probe pass hides the reason it was slow. Find
  the reason.
- Removing a deadline "because it never fires" turns a hung provider CLI into a
  hung refresh.
- Killing only the direct child is not cleanup. A grandchild has already been
  observed holding an output pipe for a further 52 seconds after the parent died.

## Never make the UI wait

UI and observable state live on the main actor; blocking CLI work runs off the
cooperative executor. A probe that reaches the main actor is not slow, it is a beach
ball. When reviewing, follow the actual call chain from the refresh trigger to the
`Process` — an `await` in the middle does not prove the blocking part moved.

Equally, do not starve the cooperative pool: a synchronous blocking read inside a
task occupies a thread that other tasks need. Concurrency here means bounded
concurrency.

## Caches earn their keep by avoiding processes

- The last successful snapshot is kept and stays visible when a refresh fails.
  That is a correctness rule, and it also means a failed probe costs nothing extra.
- Discovery searches explicit known-good paths first, `$PATH` second, the login
  shell last. Keep that order — it is a security property, and it happens to also
  be the cheap-to-expensive order.
- Only the last of those steps is memoised, by `DiscoveryMemo`: it is the one that
  spawns processes, and the cheap steps still running on every call are what keeps
  the memo honest when a binary is installed while QuotaBar runs. Its invalidation
  story is in the source: keyed on the executable name, `$PATH` and `$SHELL`, a hit
  re-checked with one `stat`, a miss expiring after `missLifetime`.
- Any cache you add needs an invalidation story and must not become a place where
  a stale value outlives a reset window.

## History has arithmetic, so do the arithmetic

`history.bin` is an append-only fixed-stride log; anything older than 120 days is
pruned, so it holds roughly three months of usable series. Its size is stride ×
samples per window × number of series. Adding a series, or shortening
the refresh interval, multiplies it — state that number in the pull request rather
than leaving it to be discovered.

Reading is best effort and must never block or fail a refresh: a damaged or
unwritable history file is reported by read paths and silently tolerated by write
paths, never escalated.

## Regexes over untrusted text are a denial-of-service surface

Provider output is attacker-influenced. Catastrophic backtracking in a parser is
not a performance nit, it is a hang triggered by a remote party's formatting
choice. Any new pattern over CLI output gets an adversarial input and a timing
check — see `docs/agent-guides/red-team.md`.

## Measuring

There is no benchmark harness in this repository, and inventing one is a change in
its own right. So:

- Say how you measured. Wall-clock around a probe, a count of spawned processes, a
  file size — all fine, if stated.
- If you did not measure, say that, and phrase the finding as a risk rather than a
  number.
- Never quote a figure without the platform: the Linux container and a macOS host
  are not comparable, and only one of them can run the menu-bar app at all.

## What to report

The cost that changed, in what units, and under what conditions. A finding here
should name the operation, how often it now happens, and what it displaces.
