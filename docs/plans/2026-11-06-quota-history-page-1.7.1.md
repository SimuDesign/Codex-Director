# Quota History Navigation Page — 1.7.1 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Use the installed local workflow where applicable; unavailable superpowers tools are not required. The user explicitly requested this navigation change; no additional implementation confirmation is needed.

**Goal:** 将额度历史作为左侧独立页面，取消弹窗呈现，同时保留 1.7.0 的数据真实性、周期记忆和隐私边界。

**Architecture:** 复用现有 SwiftUI 主导航、窗口级 `QuotaHistoryController`、60 日只读结果和独立周期偏好。仅调整导航、呈现和页面会话接入，不修改 DirectorCore、SQLite、额度算法、账户接口、刷新调度或能力包。

**Tech Stack:** 现有 SwiftUI/AppKit、Swift Charts、Scheme A、XCTest；无新增依赖。

## Authority and scope

- User request on 2026-11-06 supersedes the seven-destination/Quota-history-Sheet rules for this surface only.
- Work in the existing public checkout and `codex/quota-history-1.7.0` branch. Preserve all accepted, uncommitted 1.6.3/1.7.0 work and the private archive. A recoverable tracked/untracked source snapshot was captured before this change.
- Deliver **1.7.1 (47)** through local verification and recoverable installation. No commit, push, PR, Tag or Release is authorized.
- Actual VoiceOver/OS accessibility variants and physical-input 100 ms feedback retain their previously accepted unverified status. Do not change system settings or claim these checks passed.

## Approved behavior — Product Designer handoff

1. Eight primary destinations: Home, Quota history, Capability Folders, Custom Agents, Custom Skills, Installed Skills, Installed Plugins, Settings. Do not revive the legacy Token Usage route.
2. Home's existing history action navigates to the same page. No quota-history Sheet, Close control or Escape-to-Home behavior remains.
3. Page order: Hero → explicit Source/help → Current allowance → History status → Period and coverage/times → Chart/transition band → Daily records and inline explanation.
4. Source uses the existing list and explicit `setQuotaSourceID` action. The page read key must use the stable raw selection/controller source, not `QuotaOverviewModel.selectedSource`'s automatic first-source fallback. Removal retains unavailable meaning and same-source evidence until explicit selection; it must not mix another source's current values/history. No-source pages remain navigable and do not read an invented source.
5. Retain one controller per window. Activation starts one captured-session read; deactivation closes only that session and cancels unfinished work. Late outgoing callbacks/results cannot affect a new page session. Closed controllers must not reread on index commits. No new persistent cache or suspension subsystem.
6. Preserve independent remembered 7/30/60 days, per-source selected date and window-local scroll state. Source change returns to top. Range/day changes reset inline transition pagination. All summaries use the selected range and deduplicated transition IDs. Range and pagination changes remain in memory.
7. Current-only updates do not reread or refresh history timestamps. Loading, stale failure, successful empty, observed zero, unknown reasons, expired current, source removal and index deletion stay distinct. Preserve all existing privacy constraints.

## Approved visual contract — UI Designer handoff

- `DirectorEditorialFrame` → one full-workspace `ScrollView` → `DirectorPageContentFrame`; trailing workspace scrollbar, 24pt vertical padding, existing 40/16pt horizontal gutters, centered 1440pt cap.
- Standard `DirectorEditorialHero`: no eyebrow/subtitle, solid-primary localized title, existing `DirectorSymbol.usage` (`chart.bar`), existing blue tone and 52/36pt responsive title. No modal navigation chrome.
- Source field/help precedes current values. Reuse `DirectorOutlinedMenuField`; full compact width and the existing 360pt readable measure when space permits. Current selection remains visible. It is not paired with the period field.
- Current weekly/five-hour blocks use equal columns at inner width ≥760pt and stack below; existing `space6` column gap / `space3` stacked gap, 16pt horizontal/12pt vertical padding, existing 30pt metric role and supporting/caption metadata. One separating boundary, no individual cards or fixed section height.
- Independent outlined 7/30/60 control below current/status, minimum 36pt fitting height. Preserve coverage and historical timestamps separately.
- Chart keeps the existing 190pt minimum, full width, gradient, dynamic axis and sparse labels. Preserve transition interval band and virtualized continuous date rows (16/12pt padding, 52pt minimum), inline selection/details and 20-item in-memory pagination.
- Section spacing `space6`; internal spacing `space3`. Existing semantic tokens, focus, Light/Dark and AX conventions. No new content glass, colors, shadows, custom icons, Home-only typography or assets. Escape handles menus normally and does not leave the page.

## Execution and ownership

### 1. Presentation implementation — Frontend Developer

Own the navigation enum/symbol, Root routing and page session glue, history view/model presentation, Home entry, bilingual resources, validation/performance diagnostic adapters and relevant UI tests. Update `DirectorSchemeATests` navigation/version assertions to eight destinations and 1.7.1 (47). Preserve source/query/controller contracts; route any unavoidable backend/concurrency change to Software Engineer before expanding scope.

Test actual first entry, no-source/removed-source, explicit source switching, rapid page switching, old-session callbacks, range/day/scroll memory and absence of hidden reads. Prefer existing controller/session APIs and synthetic fixtures. Do not mutate production data or global settings during tests.

### 2. Metadata and documents — root

Own project.yml/pbxproj version, Settings fallback, current README/CHANGELOG/privacy/architecture, AGENTS navigation contract, design system and validation documents. Preserve dated historical plans as historical evidence; mark superseded modal rules explicitly.

### 3. Independent acceptance — Quality Engineer

Read-only verification of final code and focused/full test results. Live synthetic zh/en, Light/Dark, 720×480, 1280×800 and wide page checks; ensure no Sheet, narrow clipping, mismatched counts or stale-close regression. AX and real VoiceOver remain separate evidence.

### 4. Local delivery — root

Freeze inputs; run focused tests, `./scripts/verify.sh`, temporary-index public tree/history audit and normal universal Release build. No repeated million-row benchmark is required when Core/query inputs are unchanged. After independent acceptance, quit normally, recoverably preserve the installed 1.7.0, verify/install 1.7.1, compare retained-data hashes before relaunch, then check sidebar navigation and page in the installed runtime. Record accepted evidence limits and delivery result without publishing private data.
