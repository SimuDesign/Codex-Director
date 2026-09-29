# Codex Director 1.4.0 Interaction Latency Implementation Plan

> Execute with the installed `executing-plans` workflow in reviewable batches. Do not treat desktop-automation or accessibility-tree retrieval time as app input latency.

**Goal:** Make navigation, folder tabs, sorting, membership actions, and detail opening feel immediate on the current capability inventory without changing their meaning or starting extra indexing.

**Architecture:** First measure a Release build with synthetic data and separate input handling, main-thread work, rendering, accessibility inspection, and SQLite work. Then remove redundant folder/list projection and eager row construction; make warm-cache navigation publish no transient loading state; optimize query or detail initialization only where the trace proves it matters. Keep the current app-scoped refresh coordinator, stable IDs, schema-v1 cache, and source-data boundaries.

**Tech stack:** Swift 6, SwiftUI/AppKit, `DirectorCore` actors and SQLite, XCTest, the existing Debug UI Validation Host, Instruments Hangs/Time Profiler, and privacy-safe signposts.

---

## Context and scope

The active public worktree is `codex/home-ranking-periods-1.4.0`. Its 1.4.0 work is not yet committed; preserve all existing changes. The private `ui-optimization` archive is out of scope. This plan is a performance completion of `1.4.0 (27)`, not a new feature or an automatic version bump, push, tag, Release, or installation request.

The preceding inspection found concrete repeat-work paths, but did **not** prove a single dominant bottleneck:

- `CapabilityFoldersView.swift` rebuilds filtered/sorted members on each body evaluation. Its member panel uses `VStack` for all rows inside the outer lazy scroll container. Companion row rendering repeatedly resolves relationships, folder membership sets, and initial expansion state.
- `CapabilityFolderProjection.companionSkills`/`relatedAgents` linearly scan relations and resources and rebuild folder member-ID sets for each request.
- `CapabilityLibraryView.swift` obtains both `displayedRows` and `groupedRows` from fresh row/group construction; its `.task` requests a library reload when the destination appears.
- `DirectorAppModel.reloadLibrary` publishes `.loading` before checking whether the presentation key is already cached. On a cache miss, `DatabaseStore.fetchLibraryPresentation` reads seven-day, thirty-day, history, and project-use projections within one snapshot.
- `DirectorOutlinedSegmentedControl` updates labels and invalidates AppKit intrinsic size/layout/display on every SwiftUI update, including unchanged values.
- `CapabilityDetailViewModel` synchronously reads all saved evaluations when constructed. Treat this as a conditional hotspot until measured with a nonempty synthetic evaluation store.

The previous live `sample` trace showed no sustained main-thread hang. Automated clicks were contaminated by accessibility-tool waiting; long AX-tree reads, especially on large capability lists, are not evidence of rendered-frame latency. The first implementation task must produce a reproducible baseline before selecting the expensive-path fixes.

### Non-goals and invariants

- No new navigation, visual language, cache schema, database, indexer, source scan, network call, or persistent preference.
- Do not change the seven-/thirty-day definitions, unknown-versus-zero semantics, project ownership, plugin attribution, folder membership, companion declarations, detail evidence, or `.codexpack.zip` manifest v1.
- Preserve the native folder ScrollView contract, the four library `List(selection:)` controls, selected/keyboard/VoiceOver semantics, tab-specific browsing state and scroll restoration.
- Keep source Agent/Skill files, Codex sessions, plugin packages, and private archive untouched. Use synthetic fixtures and static diagnostic labels; never log resource names, paths, prompts, account data, or evaluation content.

## Acceptance targets

Record the Mac model, macOS, build identity, data shape, display scale, measurement method, and 20 samples per scenario. Report median, p95, maximum, query count, and MainActor longest block separately for cold first entry and warm repeats. Use the existing project gate of ordinary input feedback p95 ≤100 ms and no data-loading-caused MainActor block ≥100 ms. Propose cached content-settled p95 ≤250 ms for representative data and ≤500 ms for the stress fixture; if a baseline proves these unrealistic, record the evidence and approve a revised gate **before** accepting implementation. Do not compare against CUA/AX retrieval wall time.

Representative synthetic folders should cover roughly 47 Agents/44 Skills and 19 Agents/173 Skills, plus a stress folder with at least 1,000 eligible resources and many-to-many companion relations. Include empty, unknown, explicit zero, plugin-provided, project-preview, and thirty-day data. Warm folder tab/sort/member actions must issue zero SQLite queries and zero source-index requests. Warm library navigation must not flash a loading row when its identity/key is valid.

## Task 1 — Build a trustworthy baseline

**Files:** Add `Tests/DirectorUITests/InteractionPerformanceTests.swift`; extend `Sources/DirectorUI/Validation/UIValidationHost.swift` only for functional/visual synthetic fixtures; add a Release-equivalent synthetic interaction harness under `scripts/` with any required target configuration in `project.yml`; document aggregate results in `docs/PERFORMANCE.md`. Keep raw Instruments traces outside Git.

1. Add deterministic small, representative, and stress fixtures with opposite seven-/thirty-day sort order, relations, memberships, and nonempty evaluations. Verify the host never reads production preferences, source roots, or installed app data.
2. Add static signposts gated by a dedicated performance-validation build flag, not `DEBUG`, so the optimized harness can emit them without shipping diagnostic data. Cover sidebar selection, folder-tab selection, sort selection, render-projection calculation, library cache hit/miss, and first settled content. Use query observers for SQLite/index counts; do not include resource IDs or text in signposts.
3. Build a local optimized harness from the real root view and injected UUID-scoped synthetic database/in-memory preferences; the Debug UI Validation Host is visual evidence, not a Release timing surrogate. On one frozen optimized build, exercise Home → every library → folder entry → Global/custom folder → each of the three tabs → sort → detail → Settings. Repeat both warm and first-entry paths 20 times at 720×480 and 1280×800. Separate app signpost durations from screenshot/AX inspection time.
4. Use Instruments Hangs and Time Profiler to attribute ≥100 ms samples to `DirectorUI`, AppKit/SwiftUI layout, SQLite actor waits, or OS rendering. Record whether an actual painted-state delay is visible. Do not infer pixels from a model timestamp alone.
5. Write a short before table and rank hotspots by measured contribution. Stop speculative query/detail refactors if those paths are below the input budget.

**Gate:** The baseline contains reproducible Release identity and privacy-safe aggregate measurements. `swift test --filter UIValidationTests` remains green.

## Task 2 — Compute folder relationships and expansion once per projection

**Files:** `Sources/DirectorCore/Grouping/CapabilityFolders.swift`, `Sources/DirectorUI/Capabilities/CapabilityFoldersView.swift`, `Tests/DirectorCoreTests/Grouping/CapabilityFolderTests.swift`, and a focused UI state test.

1. Write failing tests showing that multi-folder membership, preview status, relation ordering, reverse links, and ambiguous/absent relations are unchanged when queried repeatedly.
2. During immutable `CapabilityFolderProjection` construction, derive private `resourceByID`, `memberIDsByFolder`, `relationsByAgentID`, and `relationsBySkillID` indexes. `companionSkills` and `relatedAgents` should use the relevant indexed slice, not a full relation/resource scan or rebuilt member set per row. Rebuild these indexes only with a new projection after directory/membership changes; persist none of them.
3. In the folder view, calculate the initial collapsed-Agent set once for the selected folder and preserve user toggles in existing per-folder/per-tab session state. Do not call the initial-set algorithm from each row render. Build one member render projection per folder/tab/search/sort change rather than resolving counts and relationships independently for every row.
4. Rerun scope and membership tests; compare before/after projection timing on the synthetic stress fixture. Confirm previews never change member counts.

**Gate:** Identical folder contents, counts, relation source labels, reverse links, and expansion behavior; no query/index event on tab, search, sort, expand, or membership-menu open.

## Task 3 — Make long folder lists lazy without losing native behavior

**Files:** `Sources/DirectorUI/Capabilities/CapabilityFoldersView.swift`, `Tests/DirectorUITests/UIValidationTests.swift`.

1. Add a synthetic stress test for 1,000 rows, selected detail, scroll restoration, offscreen item discovery, and keyboard/VoiceOver navigation.
2. Replace eager row construction inside `memberListPanel` and companion groups with lazy row containers under the existing single native ScrollView. Keep stable `.id` targets, header/filter/result co-scrolling, the fixed side-sheet overlay, separators, and only one search editor.
3. Check that changing tabs does not instantiate every offscreen row or its membership menu, and that scrolling back keeps the selected row and per-tab position.
4. Inspect zh/en, Light/Dark, 720×480/1280×800 and Increase Contrast/Reduce Motion. Do not add glass, new colors, or a second scrolling region.

**Gate:** The full accessibility/keyboard contract survives; representative and stress tab p95 improve without a scroll or selection regression.

## Task 4 — Stop unnecessary AppKit segmented-control relayout

**Files:** `Sources/DirectorUI/DesignSystem/DirectorSchemeA.swift`, `Tests/DirectorUITests/DirectorSchemeATests.swift`, `Tests/DirectorUITests/UIValidationTests.swift`.

1. Add a failing bridge test for an unchanged SwiftUI update: no label rewrite, intrinsic-size invalidation, width reset, or layout/display request should occur. A changed selection should repaint/AX-update without recalculating intrinsic size; changed localized labels or accessibility settings should recalculate it.
2. Compare the incoming title/selection/enabled/contrast/transparency values with the native control's last applied values in `updateNSView`; update only the changed properties. In `layout`, call `setWidth` only when the calculated width actually differs.
3. Verify three individual AX radio choices, selected trait, native left/right/Return interaction, focus ring, wrapped English labels, and Settings Light/Dark selector. Check that selected-state visuals and no-system-blue behavior remain unchanged.

**Gate:** No repeated intrinsic-size invalidation for identical props and no native-control interaction/appearance regression.

## Task 5 — Keep cached library navigation immediate

**Files:** `Sources/DirectorUI/AppShell/DirectorAppModel.swift`, `Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift`, `Tests/DirectorUITests/CapabilityLibraryStateTests.swift`, `Tests/DirectorUITests/PresentationPublicationTests.swift`.

1. Test a warm presentation key, a changed database identity, changed scope, classification revision, failed read with old content, and late/cancelled request. Assert that warm navigation emits no `.loading` state or full query; a real miss retains old rows with a compact updating state.
2. Move `reloadLibrary`'s loading publication after the cache/identity decision. Reuse an in-memory identity only while the app's generation guards prove it current; do not trade responsiveness for stale data or bypass the actor on an uncertain identity.
3. Materialize flat rows, groups, and selected-row lookup once per relevant catalog/stats/context revision in the library view model. The SwiftUI body must not call both `rows(for:)` and `groupedRows(for:)` as independent full builds. Preserve the current `List(selection:)`, grouping order, plugin unknown values, seven-/thirty-day sort text, and project scope.
4. Measure warm navigation and sort again. If the trace still attributes a first-entry delay to `fetchLibraryPresentation`, benchmark its existing seven-/thirty-day aggregates and history reads separately; only then consider reusing the single bounded dual-period aggregate already used by Home. Do not add an index or parallel calls to the same database actor merely on intuition.

**Gate:** Warm category changes and sort are in-memory/no-index paths; cold misses are cancellable, retain the last valid content, and cannot publish late results. Four category and plugin-attribution tests remain green.

## Task 6 — Optimize detail initialization only if measured

**Files if triggered:** `Sources/DirectorUI/Capabilities/CapabilityDetailModel.swift`, `Sources/DirectorCore/Domain/InvocationEvaluation.swift`, `Tests/DirectorUITests/CapabilityLibraryStateTests.swift`, and the relevant Core evaluation tests.

1. With a synthetic nonempty evaluation store, measure detail-open latency and the contribution from `InvocationEvaluationStore.all()` JSON decoding. If the measured contribution is below the accepted budget, leave this path unchanged.
2. Otherwise add one app-scoped decoded evaluation snapshot with an explicit write-generation/invalidation rule, or an equivalent store-owned cache. Keep cross-window edits, clear, relaunch, and external store construction behavior correct; never cache a failed write as successful.
3. Ensure folder detail and library detail do not create a fresh model and re-decode all evaluations on an unrelated body update. Evidence paging remains user-demanded and asynchronous.

**Gate:** Detail opening is within the input budget with many synthetic evaluations; evaluation persistence and source-read-only behavior are unchanged.

## Task 7 — Independent acceptance and handoff

**Files:** Update `docs/PERFORMANCE.md` with methodology and aggregate before/after numbers; update `.design/codex-director/VALIDATION_PLAN.md` only if the accepted interaction matrix changes. No release media or private trace files enter Git.

1. Run focused tests after each task, then `swift test`, `./scripts/verify.sh`, the opt-in Release query performance suite, the public privacy audit, and the Release app build. Run the 20-sample startup scenarios on a clean candidate commit, since this dirty worktree is not release evidence.
2. An independent Quality Engineer reviews interaction signposts, Hangs/Time Profiler traces, query/index observer counts, folder/library/detail regression tests, and actual native UI/AX/VoiceOver behavior. Include background-refresh-in-progress and multi-window cases.
3. Compare representative and stress p50/p95/max against the Task 1 baseline. Reject a change that merely hides loading while making data stale, conflates unknown with zero, loses folder state, or moves work to a blocking main-actor callback.
4. Only after all gates pass, use the repository's recoverable `/Applications/Codex Director.app` replacement procedure if implementation is requested. GitHub push/PR/tag/Release remain separately authorized actions.

## Ownership and review checkpoints

- **Software Engineer:** folder projection indexes, library cache/query generation, conditional evaluation cache, Core tests.
- **Frontend Developer:** lazy folder rows, segmented bridge, library view projection consumption and native interaction evidence.
- **Quality Engineer:** independent read-only performance, privacy, state, and accessibility acceptance.

Work sequentially by default under the project Agent routing rules. Checkpoint after baseline, after folder/segmented fixes, and after library/detail fixes; do not start a broad database refactor if the prior checkpoint already meets the interaction gate.
