# Capability Folder Usage — 1.5.0 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Use the available local executing-plans workflow; unavailable tools are not required.

**Goal:** Show honest, period-labelled usage on all three capability-folder tabs without adding indexing or per-row queries.

**Architecture:** Reuse the existing app-scoped seven/thirty-day batch dictionary and normalized usage view. Add one dedicated, app-shared period preference storing only `7d` or `30d`; keep window/folder/tab browsing state and membership unchanged. Separate the period from usage/name sort direction, and keep companion co-observation evidence seven-day and noncausal.

**Tech Stack:** Swift 6, Foundation/Combine, native SwiftUI/AppKit controls, existing SQLite projection and XCTest. No dependencies, migrations or parser changes.

## Approved scope and decisions

- Version **1.5.0 (33)**. Preserve all existing uncommitted menu-bar and observation repairs in the public checkout. No staging, commit, push, tag or Release; no private-archive writes.
- All folder types and all three tabs show the same resource-ID-based observed count, including related-preview Skills. Agent counts never include child Skill counts; repeating a shared Skill under Agents never creates extra usage or folder membership.
- Counts cover all indexed usage projects, not the configuration owner/current folder. A visible localized scope label and help explain this.
- One app-scoped **Last 7 days / Last 30 days** outlined segmented selector. Missing/invalid preference defaults to seven days; remember across relaunch and synchronize windows. Tests/validation hosts use memory stores.
- Sort becomes **Usage descending / Usage ascending / Name A–Z**. Usage sorting uses the independently selected period; changing to name sort leaves the count and period visible. Existing per-window browsing state is session-only, so no persisted sort migration is necessary.
- Pending statistics show `—`. A successfully computed projection without an observation shows `0` with an observed-calls caption, not “never used”. Positive partial/inferred evidence remains labelled in help/AX and detailed evidence, not presented as successful executions or effectiveness.
- Wide rows place a fixed nonwrapping count/caption before the membership action; compact rows place it below ownership metadata. Companion-preview rows show the Skill's own count, never a pair/Agent-caused count.
- Reuse named typography/color/spacing and outlined controls. No content glass, charts, cards, new source access or row tasks. Search/tab/period/sort/member operations perform zero indexing, account reads or SQLite queries once the shared batch is available.
- Keep manifest v1, member preferences, evaluations, source files and global Codex configuration unchanged.

## Task 1 — Period preference and model projection

**Files:**
- Create `Sources/DirectorCore/Domain/CapabilityFolderUsagePreferences.swift`
- Modify `Sources/DirectorUI/AppShell/DirectorAppModel.swift`
- Modify `Sources/CodexDirectorApp/CodexDirectorApp.swift`
- Create `Tests/DirectorCoreTests/Domain/CapabilityFolderUsagePreferencesTests.swift`
- Create `Tests/DirectorUITests/CapabilityFolderUsageTests.swift`

1. Add failing tests for seven-day default, invalid fallback, dedicated key, memory/injected storage, cross-store restore and idempotent writes.
2. Implement period enum and preference following `HomeUsageRankingPreferences`, with key `com.peiweitang.CodexDirector.capabilityFolders.usagePeriod`.
3. Inject memory by default into models/tests and production storage at AppLaunchState; expose period setter and existing cached statistics without new queries.
4. Verify shared-store models synchronize and that period changes leave folders, refresh/index/query counters and Home period untouched.

## Task 2 — Three-tab row presentation and independent sorting

**Files:**
- Modify `Sources/DirectorUI/Capabilities/CapabilityFoldersView.swift`
- Create `Sources/DirectorUI/Capabilities/CapabilityFolderUsageDisplay.swift`
- Modify `Sources/DirectorUI/DesignSystem/DirectorSpacing.swift` (folder-local layout namespace)
- Modify both `Sources/DirectorUI/Resources/*/Localizable.strings`
- Modify `Tests/DirectorUITests/DirectorSchemeATests.swift`
- Test `Tests/DirectorUITests/CapabilityFolderUsageTests.swift`

1. Add failing tests for pending/observed-zero/partial/inferred display, opposite seven/thirty-day ordering, deterministic ties and unknown-last sorting.
2. Add pure display/sort projection, period selector and explicit all-project scope label; keep one responsive native search editor.
3. Show the same resource count in Agent, Skill and companion rows, including previews; keep ownership, actions and declaration labels intact.
4. Add native AX period/scope/count semantics and help explaining evidence limits. Reuse count roles and neutral/no-motion treatments.
5. Verify view contract and localized key coverage, companion counts stay separate, compact numbers do not wrap, and sort/period are independent.

## Task 3 — Documentation and version

**Files:** `README.md`, `README.zh-CN.md`, `CHANGELOG.md`, `CHANGELOG.zh-CN.md`, `PRIVACY.md`, `docs/ARCHITECTURE.md`, `docs/RELEASE.md`, `.design/codex-director/DESIGN_SYSTEM_V1.md`, `.design/codex-director/VALIDATION_PLAN.md`, `project.yml`, `CodexDirector.xcodeproj/project.pbxproj`, Settings fallback/version tests.

1. Supersede the folder-row omission rule only for observed usage and independent periods; preserve seven-day companion shared-session evidence.
2. Record privacy-only period preference and update current version to 1.5.0/33, retaining historical entries.
3. Run `git diff --check` and public audit, including checks for new untracked files.

## Task 4 — Verification and local delivery

1. Focused tests: `swift test --disable-sandbox --scratch-path /tmp/codex-director/build --filter CapabilityFolderUsage` (plus neighboring folder/integration/scheme contracts).
2. Full `./scripts/verify.sh`, `./scripts/audit-public-release.sh --all`, Release `./scripts/build-local-app.sh`.
3. Isolated synthetic runtime: zh/en, Light/Dark, 720×480 and 1280×800; period/name sorting, three tabs, previews, zero/pending, membership unchanged, keyboard/AX and appearance accessibility variants. Record actual VoiceOver separately; do not infer speech from AX.
4. Read-only final review using Quality Engineer criteria; author verification is not independent acceptance unless separately authorized.
5. After relevant build/test verification, quit installed app, use `./scripts/install-local-app.sh`, keep previous app in recoverable Trash, compare version/signature/hash and proportionately verify installed runtime. No destructive reindex/backfill is required.

## Deferred

No project-only usage toggle, evidence-type dashboard, folder totals/ranking charts, performance renderer migration, GitHub publication or source writes. Independent QA and any unmeasured release accessibility gate are reported explicitly rather than claimed.

## Execution record — 2026-10-04

- Tasks 1–3 implemented: dedicated period preference, production/memory injection, all three tab rows and companion previews, independent sort, localized scope/help/AX, documentation and version 1.5.0/33. One display projection is reused per row; no row tasks or new data access were added.
- Focused tests: 11 new preference/display/integration tests passed. The synthetic batch fixture gives opposite seven/thirty-day orders, a shared Skill linked to two Agents and usage outside configuration ownership. Twenty repeated period pairs preserve the loaded dictionary, memberships and database query count; shared stores synchronize without changing Home period.
- Full `./scripts/verify.sh`: 1014 Swift tests, 0 failures, 3 existing opt-in large performance benchmarks skipped; source/license/media contracts, script fixtures and Debug build passed. Public tree/history audit (`--all`), a separate untracked-file sensitive-pattern check and `git diff --check` passed.
- Release and isolated Debug validation builds passed. Release is 1.5.0 (33), macOS 26+, arm64 + x86_64, ad-hoc signed. Installed executable SHA-256: `b1d36fb591ee338b1e80ba842e2f4adcf901c857b5c3647199e499fb0f1180fa`.
- Native runtime sampling used synthetic data: Chinese Dark at narrow 720×480 and a wide host; English Light at 720×480 and exact capture-mode 1280×800. Three tabs, period-specific values, zero, usage sort, all-project scope and project/global-preview separation were inspected. Narrow rows put counts below metadata; wide rows retain a trailing column. Native AX includes period/count/scope and evidence qualifiers. Native sort-menu keyboard activation succeeded; the period-control keyboard path was not conclusively verified in the live host.
- Author review only: no independent Quality Engineer was dispatched. Actual VoiceOver speech, the complete language×appearance×viewport cross-product, Increase Contrast/Reduce Motion runtime variants and opt-in large performance runs are not claimed. These remain formal-release accessibility/performance gates, not evidence inferred from source tests or AX.
- Local cover-install followed the verified-build, quit, recoverable-Trash, copy and strict verification steps. UI quit/relaunch used native automation rather than shell UI commands. Installed bundle matches the build byte-for-byte; the old app is recoverable. The folder membership preference checksum is unchanged. No index reset, migration, capability source write, Git commit/push, Tag or Release was performed for this iteration.
- Installed runtime verification confirmed period-labelled counts and all-project scope. Selecting thirty days, quitting and relaunching retains the thirty-day selector. Folder member preferences still match their pre-install checksum; no real capability content or screenshot was added to public documentation.
