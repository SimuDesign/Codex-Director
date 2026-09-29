# Codex Director Four-Library Navigation Latency Implementation Plan

> **For Codex:** Execute this with the installed `executing-plans` workflow in reviewable checkpoints. Preserve the current uncommitted 1.4.0 work; do not treat automation or accessibility-tree retrieval time as application latency.

**Goal:** Make switching among Custom Agent, Custom Skill, Installed Skill, and Installed Plugins visibly responsive, including a representative-sized inventory, without changing their data or interaction semantics.

**Architecture:** Keep the existing native `NavigationSplitView` and four `List(selection:)` destinations for the first optimization pass. Separate selection feedback, cached-model work, the one freshness query, SwiftUI/AppKit layout, and first visible content before changing code. Optimize only attributed costs in the shared library path; an alternative list implementation is a gated prototype, not an assumed production migration.

**Tech stack:** Swift 6, SwiftUI/AppKit, `DirectorUI`, the existing `DirectorCore` read store, XCTest, the isolated Release interaction harness, Instruments Time Profiler/Animation Hitches, and synthetic visual/AX fixtures.

---

## Scope and current evidence

This is a focused continuation of [the 1.4.0 interaction plan](2026-09-24-interaction-latency.md), not a repeat of its folder, segmented-control, evaluation-cache, or query-aggregation tasks. Work on the public `codex/home-ranking-periods-1.4.0` branch only after protecting its existing uncommitted changes. This plan alone authorizes no code change, version bump, installation, GitHub push, tag, or Release.

The current Release-optimized, synthetic `interactionRepresentative` harness has 66 Agents and 217 Skills across global/project scopes. It selects the four destinations in the exact order above. Each warm destination visit records one SQLite presentation-identity read, no source-index request. For 19 warm repeats, its 1280×800 app-marker-to-layout-settlement medians / p95 values are:

| Destination | Median | p95 (observed maximum) |
| --- | ---: | ---: |
| Custom Agent | 557 ms | 571 ms |
| Custom Skill | 729 ms | 737 ms |
| Installed Skill | 184 ms | 191 ms |
| Installed Plugins | 95 ms | 104 ms |

The 720×480 results follow the same order. A hot-process sample contains substantial SwiftUI/AppKit `List` and row-layout work. This is evidence of a shared view/layout bottleneck, **not** proof that the identity query is negligible or that the numbers equal actual click-to-painted-frame latency. The test build has a dedicated diagnostic identity and a dirty source tree; it is exploratory, not release acceptance. The currently installed application is not a safe synthetic test target.

### Invariants

- Preserve category ownership, plugin attribution, project grouping, stable IDs, all four summary-card meanings, the 7/30-day sort semantics, unknown versus explicit zero, and the selected closed-menu value.
- Keep the single scrollable `List(selection:)` page, visible keyboard/VoiceOver selection, Scheme A gutters/borders, 20 pt project-group spacing, detail Sheet, and per-category search/scope/sort/selection state unless a separately approved design-system decision changes them.
- Keep valid cached rows visible through background refresh/failure. A newer database generation, classification change, cancellation, or derived-data deletion must invalidate stale results correctly. Do not improve timing by hiding loading or presenting old category content as new.
- No source scan, account read, new indexer/database, cache-schema migration, source-file write, network call, or sensitive performance label. Reports and screenshots use synthetic data only.

## Proposed performance gates

On one frozen optimized build, record the Mac model, macOS/Xcode, source commit, fixture counts, viewport, display scale, appearance, and tool version. Measure first entry separately from at least 30 warm destination changes at 720×480 and 1280×800; report p50, p95, maximum, query count, row-projection builds, and longest main-run-loop turn for **each** of the four destinations.

- Native input acknowledgement/selected-sidebar feedback: p95 ≤ 100 ms.
- Representative fixture, selection to first correct visible content: p95 ≤ 250 ms for each destination.
- 1,000-resource stress fixture, selection to first correct visible content: p95 ≤ 500 ms for each destination.
- No data-loading-caused main-actor block ≥ 100 ms; separately identify OS/layout stalls rather than calling them a SQLite block.
- Warm navigation: zero source-index/account requests and no full library-presentation query; at most the existing one bounded identity read unless a separately tested invalidation mechanism safely removes it.

The prior layout-settlement numbers are a comparison baseline, **not** painted-frame results. If measured first-paint timing cannot be established reliably, report the missing evidence and leave the gate open. Do not lower a gate after implementation merely to declare success.

## ADR — Preserve native List for the first pass

**Status:** Proposed for this optimization plan.

**Context:** The four pages share `CapabilityLibraryView` and the design system requires native `List(selection:)` semantics. Replacing it could change selection, row accessibility, scrolling, visual grouping, and detail behavior. Existing evidence shows substantial layout cost but does not isolate a single expensive modifier or prove a substitute is faster.

**Decision:** Instrument the existing path, remove attributable repeat work, and remeasure before considering a renderer change. If any representative page still exceeds the 250 ms p95 first-content gate after a verified focused pass, build an isolated, synthetic AppKit-list prototype for comparison. Production adoption requires a separate Product Designer/UI Designer ruling, design-system update, and independent keyboard/VoiceOver review.

**Alternatives:** Keeping all four destination trees permanently alive is rejected as an initial fix because it can multiply retained views/memory and complicate state invalidation. An immediate `NSTableView` rewrite is deferred because it has no measured benefit yet and conflicts with the approved `List(selection:)` contract. A loading overlay is not a performance fix.

**Consequences:** The first pass is reversible and low-risk. It may not meet the gate; if not, the prototype supplies a measured decision rather than an unbounded rewrite.

## Task 1 — Freeze and attribute the four-page baseline

**Files:** `Sources/CodexDirectorApp/InteractionPerformanceHost.swift`, `Sources/DirectorUI/Validation/InteractionPerformanceDriver.swift`, `Tests/DirectorUITests/InteractionPerformanceTests.swift`, `scripts/run-interaction-performance.sh`, `docs/PERFORMANCE.md`.

1. Add a failing harness-contract test asserting four separately named destination events in sidebar order, one first-entry versus warm-repeat label, and privacy-safe aggregate fields. Run `swift test --filter InteractionPerformanceTests`; expect the new assertion to fail.
2. Add diagnostic-only, non-content signposts around selection mutation, row-projection lookup, identity read, list-body preparation, and layout settlement. Record query *duration* as well as count. Keep signposts out of the ordinary production build and use no resource names, IDs, paths, or account text.
3. Make the harness report each category separately; keep its UUID-scoped synthetic database, in-memory preferences, dedicated bundle identity, and runtime gate. Rerun the focused test; expect it to pass.
4. Reuse one verified synthetic Release bundle for both viewport runs with 1 first-entry and at least 30 warm repeats. Attach Time Profiler/Animation Hitches only after verifying the live PID belongs to that temporary bundle; never use `xctrace --launch` here, because a prior attempt resolved to the installed app.
5. Separately record actual native input-to-first-correct-content frames with a documented, synthetic screen-capture procedure. Report capture/automation overhead independently. Repeat paced human-like switches as well as rapid scripted switches to test whether the earlier `NSTableView` reentrancy warnings are harness-only.

**Gate:** A phase breakdown for all four pages identifies whether the dominant cost is view projection, identity read, row construction, native layout, or presentation. No implementation shortcut is approved from aggregate duration alone.

## Task 2 — Protect warm-cache and state correctness

**Files:** `Sources/DirectorUI/AppShell/DirectorAppModel.swift`, `Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift`, `Tests/DirectorUITests/CapabilityLibraryStateTests.swift`, `Tests/DirectorUITests/PresentationPublicationTests.swift`.

1. Write failing state tests for repeated warm A→B→A switches, a changed read-store identity, classification revision, scope/search/sort restoration, a failed query retaining old data, and a late query after deletion/cancellation. Verify no transient loading publication on a valid warm key.
2. Confirm from Task 1 whether the existing identity read materially contributes to latency. If it does not, leave the read unchanged. If it does, design a store-owned generation/invalidation proof that catches every Director database writer and external replacement before removing the per-entry query; do not infer freshness from a timer or UI state.
3. Make only the smallest change supported by the trace, rerun the focused tests, and verify a stale cache cannot be shown as current.

**Gate:** Correctness and at most one identity read on a warm visit; no full presentation query or source scan. A faster but stale navigation fails.

## Task 3 — Reduce measured shared List construction cost

**Files:** `Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift`, `Sources/DirectorUI/AppShell/DirectorRootView.swift` only if root invalidation is measured, `Tests/DirectorUITests/CapabilityLibraryStateTests.swift`, `Tests/DirectorUITests/UIValidationTests.swift`.

1. Add a focused test proving a warm destination switch does not rebuild the cached `CapabilityLibraryViewModel` row projection, and that a sort/search/data revision does rebuild it exactly once. Add synthetic state/AX coverage for all four page types.
2. With Task 1 attribution, remove proven repeat work from the shared page: for example, avoid temporary full-row enumeration in the `ForEach`, precompute stable group-row boundary metadata once per model revision, or isolate row-only updates from unrelated app-model publications. Keep stable resource IDs and the native List selection source of truth.
3. If row construction dominates, split the complex row into a small stable render input and a reusable row view without changing text, Menu actions, focus/selection bridges, or the outlined group grammar. Do not add offscreen precomputation that merely moves a large stall to page entry.
4. Rerun the four-destination synthetic measurement after each isolated change. Retain a change only when it improves its targeted phase without worsening another destination, memory, scroll position, or first-entry latency.

**Gate:** The four pages retain their current content and interaction contract; representative first-content p95 reaches the target or the remaining native-layout cost is isolated for Task 4.

## Task 4 — Gated renderer experiment, only if needed

**Files if triggered:** A disposable prototype under `Sources/DirectorUI/Validation/`, focused `Tests/DirectorUITests/` coverage, and a proposed amendment to `.design/codex-director/DESIGN_SYSTEM_V1.md`; no production replacement in this task.

1. If a measured page remains above 250 ms p95 because native `List` layout is dominant, prototype a virtualized native AppKit table using the same immutable row DTOs and synthetic fixture. Compare input/paint, first entry, memory, scrolling, and 1,000-row stress behavior on the same hardware.
2. Inspect keyboard selection, Shift/arrow behavior, contextual folder menu, row AX labels, VoiceOver reading order, focus, the side Sheet, Light/Dark, Increase Contrast, and Reduce Motion. A faster view that fails one of these is not acceptable.
3. Present the before/after numbers and design-contract changes for explicit approval before changing the four production destinations. If the prototype does not clearly beat the optimized SwiftUI List, discard it.

**Gate:** No silent renderer migration. The approved native List remains production behavior until a separate design/system decision says otherwise.

## Task 5 — Independent acceptance and delivery

**Files:** `docs/PERFORMANCE.md`; test/validation documents only when their contract actually changes.

1. Run focused tests after each task, then `swift test`, `./scripts/verify.sh`, `./scripts/audit-public-release.sh --all`, the opt-in Release query suite, and a dual-architecture Release build on a frozen candidate. Do not merge unrelated dirty changes into the performance commit.
2. Have an independent Quality Engineer review the four timing distributions, native trace attribution, zero-index/query observers, and functional regressions. Validate zh/en × Light/Dark at 720×480 and 1280×800 with synthetic empty/representative/stress data, keyboard, VoiceOver, Increase Contrast, Reduce Motion, and a background refresh holding prior content.
3. Record current versus optimized values, including unresolved first-paint or accessibility evidence. A passing build alone is not acceptance. Install to `/Applications/Codex Director.app` only after the applicable project installation gates pass when implementation is later authorized; preserve the old bundle recoverably. GitHub push/PR/tag/Release require their own instruction.

## Ownership and checkpoints

- **Product Architect (root, plan only):** keep the List-versus-AppKit decision and gates explicit.
- **Software Engineer:** diagnostic harness, read-store freshness path, generation/cancellation tests if those are measured hotspots.
- **Frontend Developer:** attributed shared List/row rendering improvements and native visual/interaction evidence.
- **Quality Engineer:** independent, read-only performance, privacy, state, keyboard, and VoiceOver acceptance.

Use the project-required roles sequentially unless the user explicitly requests real subagents. Pause after Task 1 attribution, after each Task 3 change, and before any Task 4 production decision. No part of this plan asks the user to supply another Mac or real capability data.
