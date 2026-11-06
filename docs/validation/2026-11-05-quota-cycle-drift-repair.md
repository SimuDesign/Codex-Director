# Daily quota cycle drift repair validation — 2026-11-05

Target: **1.6.2 (44)**. Status: final source/artifact gates passed and the verified
App was recoverably installed; runtime observations are recorded below.

## Confirmed defect

The original classifier interpreted a forward reset-time difference above five
minutes as a cycle reset. Actual read-only observations exhibited ten-to-fifteen
minute report drift while remaining in the same weekly cycle. The cached daily
totals therefore exceeded the observed same-cycle increase.

An independent source-compiled synthetic reproduction used reported usage
`20 → 23 → 23 → 35` and a future reset time drifting twelve minutes. The old
algorithm returned **38**, though the observed increase was **15**. The new
test-tree RED run executed 13 domain tests with three
failing assertions in that new regression; the twelve existing cases passed.
Real-data replay was read-only; no source paths, account identities or content
were persisted in this record.

## Independent first-candidate findings

Quality Engineer rejected the first implementation candidate before Release
or installation. A cross-day retired-cycle replay could become the next day's
baseline, hiding valid subsequent usage. Legacy-cache repair also needed to
recheck window visibility and release scheduling state after cancelled or
guarded-out work. Both findings return to Software Engineer for behavioral
regression and remediation; prior focused passes do not override them.

A later candidate passed 86 quota-related tests including two existing heavy
performance skips, with zero failures (84 non-skipped passes). Independent
review still found an actual bootstrap-order race: a legacy repair dispatched
from service installation could invalidate the initial-load ticket before
startup and persisted retry restoration completed. A real seven-day replay
also requires further investigation of accepted daily boundaries. The
candidate remains blocked and is not installed; focused green results do not
close these findings.

## Required final gates

- Stateful drift/reset/replay/gap/ambiguity regression and matching DB markers.
- Legacy cache immediate masking and shared, projection-only upgrade under
  visibility changes, cancellation, deletion, generation changes and failure.
- Current unknown values remain unknown through UI/cache composition.
- Complete Swift verification, public audit, universal Release, independent
  acceptance and recoverable installation with data/preference preservation.

No database/parser/schema migration, source write, Git publication or OS
accessibility-setting change is authorized by this record. Snapshot evidence
has no platform cycle ID; ambiguous account-side adjustments cannot be
promised a precise daily allocation.

## Final frozen candidate

The user explicitly authorized available `gpt-6-sol` with `xhigh` to follow the
Software Engineer Brief after the configured older escalation model was
unavailable. That production writer corrected the remaining actual bootstrap
ordering/backoff and near-cycle replay findings; the original implementer
remained frozen. Independent Product Architect and Quality Engineer rechecked
the actual final source rather than accepting earlier summaries.

- Narrow same-cycle drift RED is now green; strictly higher anchor reappearance
  and equal-only replay have separate synthetic expectations. The latter stays
  unknown. True stale replay returns 62, and proved multi-reset usage returns
  120 without a cap.
- Fresh source-compiled replay of the complete frozen seven-day numeric input
  returns **4 and 17**, replacing the earlier incorrect unknown/18 candidate.
  These are observed local-history increments; no provider billing-total claim
  follows from them. Later observed records changed the second day's endpoint
  from the first audit's 68 to 69, so its final increment is 17 rather than 16.
- Final focused suite: **122 tests, 2 existing opt-in performance skips,
  zero failures** (120 non-skipped passes).
- Fresh full `verify.sh`: **1,313 tests, 3 existing opt-in skips, zero failures**,
  followed by a successful Swift build.
- Universal Release: **1.6.2 (44)**, macOS 26+, arm64 and x86_64, ad-hoc signature.
  Executable SHA-256:
  `0f23bc5645a64adb92024eb621c0ea1879159273177331bec5204edd6c18725a`.
- All 335 frozen build-input hashes match. No Git commit, push, tag or Release
  was performed. Current/history public audit and installed runtime checks are
  recorded separately after they complete.

## Installation and observed runtime

- Untracked-inclusive public current/history audit passed. Independent Quality
  Engineer accepted the final source/artifact gate for installation.
- The previous App was normally quit and retained in a uniquely named user
  Trash location. Staged/installed full-bundle comparisons, deep/strict
  signatures and executable hashes matched the verified Release artifact.
- Before relaunch, folder/classification preferences, existing evaluation
  preference presence, capability-history, SQLite and existing WAL digests
  matched exactly. Normal indexing after relaunch may legitimately update the
  Director-owned database; this is not a claim of unchanged active DB bytes.
- Initial legacy hydration masked old incorrect daily values while retaining
  current allowance, rankings and inventory. The running App then recomputed
  daily values and persisted `dailyUsageAlgorithmVersion = 2`.
- An additional manual refresh finished at local 11:59 and returned the idle
  refresh button. Later source records completed the second day's endpoint at
  70 rather than the frozen fixture's 69: the final observed three daily values
  were **4, 18 and 2**, matching same-cycle reported usage **48 → 52 → 70 → 72**.
  The frozen-source regression remains 4/17 because its input is unchanged;
  this is evidence arrival, not another accumulation of the same interval.
- A separate current Codex account read and the displayed/cache weekly
  remaining allowance both reported **28%** at comparison. No five-hour window
  was reported. Plugin inventory reported 20, current project-source state
  remained 42 available and three configured missing roots, and Settings
  displayed 1.6.2 with parser 1.4.2.
- No OS accessibility setting was changed and no production screenshot or
  source content was added to the repository. No Git publication was performed.
