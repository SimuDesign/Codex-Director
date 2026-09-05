# Daily Weekly-Quota Usage Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace Home's daily cumulative weekly-quota snapshots with the amount of weekly quota observed as used on each local calendar day.

**Architecture:** Keep account-reported `used_percent` as the only quota fact and derive a reset-aware daily percentage-point increase per canonical quota source. Compute the value in the bounded quota projection, persist it as an optional backward-compatible presentation-cache field, and render it through the existing Home chart without changing the current allowance ring or refresh scheduler.

**Tech Stack:** Swift 6, SwiftUI, Swift Charts, SQLite, XCTest

---

## Approved behavior contract

- A bar answers “How much of the weekly allowance was observed as used on this local calendar day?”
- The value is an observed percentage-point increase in the account-reported weekly `used_percent`; it is never derived from tokens, calls, or cost.
- Sources remain isolated by canonical `limit_id` / `limit_name` and the selected source continues to drive both the ring and chart.
- Within one reported reset cycle, use the observed high-water mark so a transient older snapshot that later recovers neither invalidates the day nor double-counts the recovery.
- Treat reset timestamps within five minutes as the same reported cycle because countdown-derived reset instants can drift by seconds; materially different reset times remain reset boundaries.
- When a reported reset boundary occurs during a day, retain the observed increase before reset and add the new cycle's reported use after reset.
- If a day has no observation, no predecessor, or an unexplained decrease that has not recovered by the end of its cycle segment, show “No record” rather than zero or an invented value.
- A confirmed flat day with valid observations displays 0%.
- The current-day bar is partial through the latest recorded observation.
- The current allowance ring remains the latest reported cumulative state; expired-state behavior remains unchanged.

## UI contract

- Chinese title: `每日周额度使用`; subtitle: `按同一来源的额度记录增量计算`.
- English title: `Daily weekly-quota use`; subtitle: `Observed increase from same-source quota records`.
- Keep seven local dates, gradient bars, horizontal grid lines, centered columns, missing-state labels, and existing Card Atlas geometry.
- Use a dynamic percentage axis appropriate to the largest daily value so normal daily usage is legible; retain annotation headroom.
- VoiceOver values describe the amount of weekly quota used that day and distinguish no record.

### Task 1: Add reset-aware daily usage projection

**Files:**

- Create: `Sources/DirectorCore/Domain/QuotaDailyUsage.swift`
- Test: `Tests/DirectorCoreTests/Domain/QuotaDailyUsageTests.swift`

**Steps:**

1. Add failing tests for a same-cycle increase, a confirmed flat day, a reset inside the day, no observations, no predecessor, and an ambiguous decrease.
2. Run the focused Core test and confirm the new type is missing.
3. Implement a pure projection over chronological same-source `QuotaSnapshot` values.
4. Run the focused Core test and confirm all cases pass.

### Task 2: Persist the derived value in the compact Home projection

**Files:**

- Modify: `Sources/DirectorCore/Domain/PresentationSnapshot.swift`
- Modify: `Sources/DirectorCore/Persistence/DatabaseStore.swift`
- Modify: `Tests/DirectorCoreTests/Persistence/QuotaOverviewQueryTests.swift`
- Modify: `Tests/DirectorCoreTests/Persistence/PresentationSnapshotStoreTests.swift`

**Steps:**

1. Add failing query tests that require each `QuotaOverviewDay` to expose the reset-aware daily value.
2. Add an optional `usedPercentDelta` field with custom decoding so schema-v1 caches written by the previous app remain readable.
3. Compute the field from the already bounded same-source rows in `fetchQuotaOverview`; do not add a database migration or a second query.
4. Add an old-cache decoding test and run the focused persistence tests.

### Task 3: Update the Home presentation model and chart

**Files:**

- Modify: `Sources/DirectorUI/Home/QuotaOverviewModel.swift`
- Modify: `Sources/DirectorUI/Home/QuotaOverviewView.swift`
- Modify: `Sources/DirectorUI/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Sources/DirectorUI/Resources/en.lproj/Localizable.strings`
- Modify: `Tests/DirectorUITests/QuotaOverviewTests.swift`
- Modify: `Tests/DirectorUITests/UIValidationTests.swift`

**Steps:**

1. Add failing UI-model tests for raw observations, compact projections, missing values, reset days, confirmed zero, and legacy-cache fallback.
2. Map the persisted delta into `DailySnapshot`; derive only safe neighboring-day fallbacks for legacy cache payloads.
3. Replace cumulative chart copy and values with daily usage values, add a dynamic percentage axis, and update accessibility labels.
4. Update the synthetic visual fixture assertions and run focused UI tests.

### Task 4: Update product and visual source-of-truth documents

**Files:**

- Modify: `AGENTS.md`
- Modify: `docs/plans/2026-08-28-capability-centered-redesign.md`
- Modify: `docs/plans/2026-08-28-home-visual-refresh.md`
- Modify: `.design/codex-director/DESIGN_SYSTEM_V1.md`
- Modify: `.design/codex-director/VALIDATION_PLAN.md`

**Steps:**

1. Replace the superseded snapshot-only contract with the approved observed-daily-usage definition.
2. Record reset, gap, source-isolation, cache-compatibility, accessibility, and chart-scale acceptance criteria.
3. Confirm no document claims that the value is token-derived or exact when source evidence is insufficient.

### Task 5: Verify, review, build, and install

**Files:**

- Review all changed files and preserve unrelated working-tree changes.

**Steps:**

1. Run focused Core and UI tests.
2. Run the full `swift test` suite.
3. Build the Debug validation app and inspect Home with synthetic data in Chinese/Dark at 1280×800 and 720×480; check English/Light copy and layout.
4. Run the Release build and validate the app bundle.
5. Following the project's authorized deployment contract, move the previous installed bundle to Trash, install the verified Release build, relaunch, refresh data, and verify the chart against production-derived daily values without exposing private content.
6. Perform an independent Quality Engineer review and return `passed` or `blocked` with any evidence gaps.

No Git commit, push, PR, or source-data mutation is authorized by this plan.

## Follow-up robustness correction — 2026-09-05

- Added regression coverage for interleaved stale same-cycle observations and reset-time drift.
- The production-shaped reset-day fixture progresses from 66% to 100%, resets, then progresses to 8%; the derived daily value is 42%.
- The original conservative behavior remains for an unrecovered same-cycle decrease, missing predecessor, missing observations, mixed sources, and incomplete reset evidence.
- Focused quota projection and UI-model suite: 30 tests passed, 0 failures.
- Full regression suite: 657 tests passed, 0 failures, 3 conditional performance skips.
- Final production refresh at 13:49 observed 66% → 100% before reset and 21% after reset, so 09/05 rendered 55% instead of “No record”.
- Release `0.3.1 (16)` was installed from the verified build; the immediately replaced bundle remained recoverable in `{{HOME}}/.Trash/` during local validation.
