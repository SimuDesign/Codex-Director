# Quota history validation — 2026-11-05

Target: **1.7.0 (46)**. Updated: **2026-11-06**. Status: independently accepted and locally installed, with the explicitly accepted evidence limits below. No Git publication was performed.

## Approved inputs and baseline

- [Plan](../plans/2026-11-05-quota-history-1.7.0.md) and [local UI contract](../design/2026-11-05-quota-history-ui-contract.md).
- Preserve accepted 1.6.3 quota/cache/package/runtime fixes and existing dirty work. A recoverable source snapshot and hash manifest were captured before implementation; no commit or push was made.
- Public branch: `codex/quota-history-1.7.0`. Private archive, source capabilities, sessions, account data and production preferences are outside test writes.

## Required evidence

1. Fixed 60-day context, source isolation, natural-day/DST boundaries, range slicing, reset proof/replay/drift, unknown recovery and unchanged seven-day wrapper output.
2. Bounded query, predecessor/tie handling, deadline/cancellation, late result/epoch/deletion safety, no extra scans/account reads.
3. Independent preference key, default/invalid 30 days, no initialization write, memory/injection isolation and cross-store recovery.
4. Labeled native Sheet entry, fixed source, current/history times, coverage, chart/date selection, inline explanation, pagination, zero/missing/error and focus return.
5. Synthetic one-million-row database with 100,000 selected-source rows in 60 days; Release cold/warm at least 20 samples, actual hardware/build/tools/data and median/p95/max. Plan targets are unmeasured until recorded.
6. Synthetic zh/en × Light/Dark, minimum/default/wide windows, keyboard/AX and accessibility variants. Real VoiceOver is separate; no permission to change OS accessibility settings is inferred.
7. Frozen complete verify/public audit/universal Release, independent QE before recoverable installation.

## Results

Independent review and local delivery are complete. Production screenshots and private retained data do not enter public evidence.

### Final technical gates

- Complete verification after the session-identity and selected-period summary repairs passed **1,371 tests, 4 expected opt-in skips, 0 failures**. The public audit fixtures, version/release/performance contracts and Swift build also passed.
- The normal Release build passed: **1.7.0 (46)**, macOS 26 minimum, **arm64 and x86_64**, ad-hoc signature. The diagnostic compilation flag is absent from the normal application.
- A separate temporary-index audit covered the current source tree, including new files, and the public Git history. It passed without staging the real index or making a commit.
- A 474-file source snapshot was unchanged across final verification and builds; this final evidence-document update is documentation only. The installed normal Release executable SHA-256 is `dfe68d908ef56922eb0b6d87b54465363b50d49da5edb89ba61293ab07c7a75a`.
- Independent Quality Engineer decision: **passed**, within the user-approved evidence limits. Final projection repair, lifecycle, query/controller/preference/localization contracts, technical gates and four-variant runtime review have no remaining P0/P1/P2 finding.

### Realistic history-query benchmark

The final Core-only Release benchmark used a hash-verified copy of the same Core and test sources. The fixture contained **1,000,000 total rows**, **100,000 selected-source rows in 60 natural days plus a predecessor**, multiple sources, 58 observed dates, two missing dates, proven weekly transitions and 16 legacy timestamp ties. Assertions required at least 50 calculable dates and a proven transition. Earlier all-unknown/reset-free fixtures are superseded.

| Measurement | Samples | Median | p95 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| New read-only connection | 20 | 0.254 s | 0.263 s | 0.426 s |
| Reused connection | 20 | 0.254 s | 0.277 s | 0.351 s |

Cancellation completed in **0.0035 s**. Hardware: 10 CPU cores, 16 GiB memory; macOS 26.5.1, SQLite 3.51.0. The OS page cache was not cleared: the first row means connection-cold, not disk-cold. No production database was used. This measures query plus aggregation, not native Sheet presentation or UI feedback.

### Runtime findings and evidence limits

- Actual CUA clicks exposed a blank first presentation that unit tests did not detect. Atomic `sheet(item:)` presentation fixed the first-open case; a fresh Release synthetic window then displayed its complete title, current values, source, coverage and history controls on the first click.
- Repeated close/reopen testing exposed a separate stale close callback that could clear the reused controller's new source and snapshot. Each opening now owns a UUID session; outgoing view callbacks and local tasks are identity guarded. The focused controller suite passed 10/10, including a late-close/new-source/read-result regression. Generic Sheet dismissal no longer closes a newer session.
- Actual synthetic-window AX and image review verified Chinese/Dark and English/Light, a 720×480 product viewport, fixed close/scroll behavior, distinct missing-baseline/cross-day-gap/ambiguous states, range counts, inline day details and Escape returning focus to the Home entry. A five-hour-only fixture showed a successful empty weekly history (0/30 observed, 0/30 calculable), not a read failure. This is partial coverage, not the complete appearance/accessibility matrix.
- The final synthetic driver completed 80 accepted commands: 20 openings and 60 period changes. Mid-run AX checks retained the selected source, 40% weekly/75% five-hour current values and 6/30 observed versus 3/30 calculable days. The draw probe captured only 9/20 entry paints and 10/20, 11/20, 11/20 period paints. This incomplete evidence does **not** establish a p95 or prove all 80 painted states. Missing samples are retained and must not be dropped. An AppKit draw marker is not a physical-click or native-button-pressed measurement. The 100 ms immediate-feedback target remains unverified.
- No OS accessibility settings were changed. Actual VoiceOver remains unverified, as requested by the user.
- On 2026-11-06 the user explicitly approved local installation with the **100 ms immediate-feedback criterion retained as unverified**, conditional on no other independent quality blockers. This is an accepted evidence limitation for local delivery, not a claim that the performance target passed. Git publication is still unauthorized.
- Independent live CUA review passed English/Light at 1280, English/Dark at 720, Chinese/Light at 720 and Chinese/Dark at 1600: fresh presentation, all periods, scrolling, localized AX content and clean dismissal. OS-level accessibility variants and actual VoiceOver remain outside the exercised matrix; no system settings were changed.
- Installed-data readback exposed a selected-period summary mismatch: one header counted the complete 60-day context. Both chart and daily-record summaries now share the selected period's deduplicated transitions. A full 60-day synthetic fixture verifies the 7/30/60-day boundaries and duplicate IDs; the six view tests pass. The final installed application was read back to confirm the two summaries agree. No private readback values or production screenshots are saved here.

### Local installation

- Quit normally, recoverably preserved the previous application in Trash, staged and verified the normal Release bundle, then installed to `/Applications/Codex Director.app`.
- The installed and build bundles matched; version, build number, both architectures, strict ad-hoc signature and executable SHA-256 were verified.
- Before relaunch, hashes of saved folder membership, evaluations, classification overrides, SQLite/WAL and capability-history data matched their pre-install values. Normal indexing after relaunch remains permitted.
- Relaunch and the new Home entry succeeded; current allowance, indexed history, coverage and selected-period summaries were readable. The application was left running. No commit, push, PR, Tag or Release was made.

### Focused checks and review corrections

- Version-contract checks passed 11/11 after metadata moved to 1.7.0 (46).
- The extracted Home daily wrapper passed its existing 24 regression cases.
  History corrections additionally cover per-day lookahead cutoff, unrecovered
  low-value baselines across midnight, confirmed-zero recovery and filtering
  future/foreign-source rows before public-projection lookahead.
- Independent review identified current-value binding and source-removal UI
  gaps, missing transition presentation, duplicate-day Home comparison traps
  and incomplete transition pagination. Remediation is being independently
  rechecked rather than inferred from author reports.
- Controller checks passed 10/10 after session identity, source-local in-memory
  expanded-day preservation and duplicate-day fail-closed handling; preferences
  passed 2/2.
- Earlier backend timing runs had an insufficient synthetic reset fixture and
  are superseded. The final benchmark must include proven weekly resets,
  missing dates, predecessor, source isolation and timestamp ties, with both
  valid calculable days and transition assertions.
- An earlier screenshot set did not show the intended application and was
  rejected as invalid evidence. Those images must not be published or counted
  as visual acceptance. Fresh synthetic target-window evidence is required.
- UI feedback timing needs a visible AppKit paint probe, separate from model
  execution or CUA round-trip time. Native Sheet presentation completion and
  immediate entry feedback are different measurements. No OS setting change
  or unverified actual VoiceOver claim is permitted.
