# Codex Director 1.4.0 Home Dual-Period Ranking Implementation Plan

> Execute this plan with the `executing-plans` workflow, in reviewable batches.

## Goal

Add a persisted seven-day/thirty-day selector to Home usage rankings. A fresh or
invalid preference resolves to seven days; subsequent launches restore the last
valid selection. Switching periods must be an in-memory projection over cached
results and must not start source indexing, SQLite reads, account usage reads, or
refresh work.

## Architecture

- Keep the presentation snapshot's canonical window as the existing recent-seven
  natural-day window so quota and existing library contracts do not change.
- Read the recent-thirty interval once and use conditional SQL aggregates to
  derive both seven-day and thirty-day capability statistics in the same read
  snapshot.
- Keep existing Home ranking fields as the seven-day compatibility payload. Add
  one optional thirty-day ranking set so legacy schema-v1 caches decode as
  `unavailable`, while a computed empty set remains distinct from unavailable.
- Persist only the selected period in the app-owned UserDefaults domain. The
  validation host and tests use memory or injected stores.
- Reuse `DirectorOutlinedSegmentedControl`; do not add content glass, a new
  palette, or a second refresh/index path.

## Task 1 — Dual-window query contract

- Add `CapabilityUsagePeriodSnapshot` in DirectorCore.
- Add a bounded DatabaseStore query that scans the thirty-day interval once and
  computes independent seven-day/thirty-day count, inferred count, last-used,
  and coverage projections.
- Update Home startup and Home-ranking-only reads to return both periods.
- Preserve the current seven-day library/detail APIs outside Home.
- Tests: natural-day boundaries, future exclusion, independent coverage,
  project filtering, cancellation, and deterministic ordering.

## Task 2 — Cache and Home projection

- Add `PresentationHomeRankingSet` and optional thirty-day rankings to
  `PresentationHomeSummary`.
- Decode old schema-v1 caches with `thirtyDayRankings == nil`; encode a computed
  empty set as non-nil.
- Extend cache validation to cover both ranking sets and the Top10 capacity.
- Build both period rankings off-main-actor and publish atomically.
- Generalize the existing Home Top10 upgrade path to also fill missing
  thirty-day rankings without a source scan or quota rebuild.
- Tests: legacy decoding, new round trip, nil-versus-empty, corrupt capacity,
  stale ticket rejection, failure retention, and no upgrade read for a complete
  cache.

## Task 3 — Preference and app state

- Add `HomeUsageRankingPeriod` and `HomeUsageRankingPreferences` using
  `com.peiweitang.CodexDirector.homeUsageRanking.period`.
- Missing/invalid values resolve to `.sevenDays`; valid changes persist.
- Provide production, memory, and closure-backed constructors.
- Share the store at app scope and expose the current period and setter through
  `DirectorAppModel`.
- Keep the current period across windows and relaunches without triggering any
  refresh domain.
- Tests: default, invalid fallback, persistence, memory isolation, shared model
  update, and zero query/index/read side effects.

## Task 4 — Home and detail UI

- Extend `HomeOutlineModule` with a source-compatible optional header accessory.
- Place a two-choice outlined segmented control in the Usage Ranking header;
  keep it inline at wide widths and wrap it below the title at compact widths.
- Render the selected period's counts, proportional bars, inferred labels, and
  period-specific empty/pending text.
- When a saved thirty-day selection meets a legacy cache, retain that selection
  and show a preparing state until the bounded cache upgrade completes.
- Pass both seven-day and thirty-day counts into capability detail reached from
  Home; preserve the rest of the library's current seven-day behavior.
- Tests: localized visible labels, selected state, narrow/wide layout contract,
  period-specific empty/pending semantics, VoiceOver text, and no system-blue
  selection fill.

## Task 5 — Performance, documentation, and release identity

- Add a 160,000-call synthetic dual-window Release performance case. Target the
  aggregate at p95 <= 500 ms while retaining cached startup p95 <= 700 ms and
  uncached indexed startup p95 <= 1.8 s.
- Do not add a database index unless this gate fails; if it fails, measure a
  time-first index independently before retaining it.
- Update bilingual localization, README, CHANGELOG, architecture, performance,
  design-system, and validation documents.
- Set the app version to `1.4.0 (27)` in every authoritative source.
- Run focused tests, full `swift test`, `./scripts/verify.sh`, public audit,
  Release build, synthetic visual/AX checks, then install the verified app under
  the repository deployment contract.

## Ownership and checkpoints

1. Software Engineer: Tasks 1–3 and backend portions of Task 5.
2. Frontend Developer: Task 4 and visual/documentation portions of Task 5.
3. Quality Engineer: independent read-only review and acceptance.

No GitHub push, tag, or Release is authorized by this plan.

## Approved follow-up — capability list and folder sorting

- Extend all four library menus and all three folder tabs with thirty-day descending usage sorting.
- Library row counts must match the selected sort window; preserve the existing fixed seven-day summary card and detail semantics.
- Keep unknown counts distinct from zero and after known counts. Do not fall back to seven-day numbers when thirty-day data is unavailable.
- Library pages reuse existing thirty-day aggregates. Folders reuse the startup dual-window projection or load one shared bounded batch after cached startup; sort, tab, search and membership actions do not query or index.
- Preserve the current per-page/per-folder-tab browsing state and current 1.4.0 identity. Verify both period orderings, warm-cache folder loading, empty/unknown plugin attribution, and derived-data deletion before reinstalling.
