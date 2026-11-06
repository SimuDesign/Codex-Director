# Daily quota cycle drift repair — 2026-11-04

## Goal and boundaries

Repair false daily weekly-allowance accumulation caused by reset-time report
drift. Target **1.6.2 (44)** on local `codex/quota-cycle-repair-1.6.2`.
Source sessions, capabilities, project membership, evaluations, database schema
v6, parser 1.4.2 and capability-package manifest v1 remain unchanged. No Git
publication, tag or Release is included in this repair authorization.

Product Architect supplies the bounded cycle/cache contract; Software Engineer
owns production implementation and regression tests. Independent Quality
Engineer owns acceptance. Root integrates version/docs, final verification,
Release build and recoverable local installation.

## Confirmed fault and RED evidence

The existing algorithm treats any reset timestamp advancing by more than five
minutes as a new cycle. A synthetic `20 → 23 → 23 → 35` sequence with an
unchanged future cycle and twelve minutes of report drift yields 38 rather
than the observed increase of 15. The added regression fails in three
assertions while the twelve pre-existing domain tests pass.

## Implementation steps

1. Keep a fixed accepted cycle anchor for each source in the existing bounded
   seven-day sequence plus predecessor. Same-cycle drift must not move the
   anchor. Daily values and cycle-change markers use the same classification.
2. Retain five minutes as reporting tolerance, not as independent reset proof.
   A natural reset requires crossing the accepted old end plus supporting new
   window evidence. An early reset additionally requires a reported usage
   decrease. The inferred start (`resetAt − window duration`) can support a
   transition only when it lies within the adjacent accepted observation
   interval, allowing reporting tolerance.
3. Ignore replays only when they match a previously accepted retired cycle;
   unrelated backwards timestamps are not sufficient. Contradictions,
   unproven transitions, missing reset evidence and missing-day baselines
   remain unknown. Legitimately proved multiple resets may exceed 100 daily
   percentage points; do not clamp the result.
4. Add an optional quota-calculation version inside schema-v1 presentation
   data. Legacy hydration retains current allowance, Home and capability
   content but suppresses invalid daily values/markers. Remove compact-model
   adjacent-day fallback so an intentional unknown remains unknown.
5. A legacy quota projection requests one coalesced `.quota` projection through
   the existing refresh coordinator, even within the source TTL. Reusing its
   bounded startup projection (including Home/directory reads) is acceptable;
   no source scan, new scheduler or source-success timestamp update is allowed.
   Preserve identity, cancellation, deletion, failure/backoff and cache-copy
   rules. Persist the new marker only with a successfully computed projection.
6. Update bilingual notes/current version sources, run final gates and replace
   the installed App only after independent acceptance. Keep the previous App
   recoverable and verify preferences/data preservation before relaunch.

## Verification

- Drift with flat/increasing usage, repeated drift, across-day drift and
  deterministic ties; prove the synthetic 38-to-15 repair.
- Genuine natural/early resets, multiple resets, retired-cycle interleaving,
  recovered/unrecovered decreases, missing resets, mixed sources and gaps.
- Database daily values and cycle markers agree; live account allowance is
  separate from indexed daily history.
- Legacy cache hydration hides incorrect values immediately; current unknown
  values stay unknown. TTL repair is coalesced and performs zero source scans.
- Failure/retry, multiple windows, generation replacement, deletion and cache
  schedule/Home-upgrade copying cannot restore legacy values or lose the marker.
- Focused suites, complete `verify.sh`, current/history public audit, universal
  Release/signature/version checks and independent review. Runtime verification
  uses only approved read-only data/normal refresh, without changing OS settings.

## Evidence limits

Snapshots have no platform cycle ID. Reset time, window duration and usage
provide bounded evidence, not proof of every possible account-side adjustment.
Unsupported ambiguity remains unavailable rather than being guessed into a
precise daily total. No provider behavior or filesystem cause is inferred from
this local calculation repair.

## Final review refinement — 2026-11-05

A one-point decrease immediately after a newly inferred cycle starts can be
a replay rather than another early reset. The final bounded classifier defers
that narrow case for up to fifteen minutes of observed history: the accepted
anchor must reappear with usage strictly higher than the pre-drop observation
before treating it as drift. Equal-value replay or absent supporting evidence
remains unknown. This is not an expanded reset-time tolerance. Genuine retired
cycles and independently supported multiple resets retain their own semantics.

Legacy-cache repair must also wait for completed initial loading and restored
persistent retry state. A real StartupController ordering regression covers
cache restoration, service installation, a gated initial database read and a
future retry deadline before the repair is allowed to run.
