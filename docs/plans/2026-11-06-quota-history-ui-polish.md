# Quota History UI Polish Implementation Plan

> Execute in this chat in reviewable batches, following the installed executing-plans workflow where applicable. The user explicitly asked for both the plan and implementation. Use the current public checkout; no staging, commit, remote operation or new worktree is needed.

**Goal:** Make the quota trend visible on entry and keep source, current allowance and evidence status understandable in one calm, native page.

**Architecture:** Presentation-only change to QuotaHistoryView and its local copy. Keep the existing route, controller, same-source data, date/scroll targets, period preferences and database contract. Expanded timestamps are view-local disclosure state.

**Tech Stack:** Existing SwiftUI, AppKit control wrappers, Swift Charts and Director tokens.

## 1. Hierarchy and responsive contract

- Keep the native sidebar route, Home shortcut, existing hero, glyph and 40/16 pt page gutters; do not change navigation or show a Sheet. Use one vertical scroll container with the stable hero and day targets. Leave just 8 pt after the hero's existing rule.
- Compact source/current context: source first in reading/focus order, 36 pt menu height with a capped 280 pt measure, 4 pt label/menu/caveat gaps. Shorten the always-visible caveat while retaining the limitation that accounts sharing a source cannot be distinguished. At effective inner width 880 pt or above, place source and current context side by side with a 24 pt gap and cap the latter at 520 pt. Otherwise stack with 12 pt gap.
- Display weekly and five-hour remaining percentages with adjacent labels and their own reported resets. Use existing metric/text tokens, leading alignment, 8 pt label/value spacing and 4 pt detail spacing. Use two aligned columns from 420 pt when content fits, with a single existing boundary and 12/16 pt gap. At smaller effective widths or on real text overflow, stack with 8 pt gap. Allow natural wrapping; no clipped dates, reduced type or fixed heights. Keep expired, missing and removed-source states explicit.
- Trend begins 16/20 pt after context. Group heading, short chart-method caption, 7/30/60 period, selected-range coverage and read status/Retry in one place. Keep the native selector at least 36 pt tall and around 304–320 pt wide where it fits; never duplicate a live native control for width measurement. Use 12 pt between selector/coverage when fitted or stack at 4 pt. Keep a visible unambiguous read status and Retry when relevant, without repeating the same missing/failed/loading message in the chart and daily section.
- Give the chart 8 pt clearance and preserve its 190 pt minimum, axes, known zeros, selection and cycle-interval band. Keep history terms honest: source removal is not successful empty; successful empty is not read failure; known zero is not missing. Cached same-source evidence can remain with failure/updating status.
- Place one native default-collapsed Data details / 数据详情 disclosure after the plot/band with a full 32 pt or larger row and one subtle rule. Keep current capture times and History snapshot timestamps grouped separately (last observation, as-of, read time) and pair labels/values locally without a stretching spacer. Use 4 pt row gaps and 12 pt group gap, wrap when needed. Toggling changes only local view state, with no forced scroll or query. Remove duplicate collapsed AX timestamps.
- Daily evidence follows after 16 pt. Keep virtualized day IDs, inline details and 20-item transition pagination. Keep the content plane opaque; no new palette, assets, glass or shared component contract.

## 2. Implementation and checks

- Frontend Developer owns Sources/DirectorUI/Home/QuotaHistoryView.swift, en/zh Localizable.strings, and any narrow quota presentation contract test. Root owns documentation, application versions and version-only assertions in DirectorSchemeATests.swift; coordinate if any test must touch that file.
- Test focused QuotaHistory and DirectorSchemeATests, then scripts/verify.sh, public audit of the actual tree plus history through a disposable index, and normal universal Release. Keep Controller, DirectorCore, Root and other pages byte-identical to the approved 1.7.1 working tree except Settings' version fallback. No new benchmark needed for unchanged query code.
- Use the real synthetic Debug app to inspect 720×480 product width/height and 1280-class layouts, zh/en Light/Dark. For normal data, aim for plot top within 380 pt of content origin and a visible plot/grid on entry at compact size, with the full plot and axis at standard size. Verify source switch, range, disclosure, day detail and leave/return scroll plus visible AX names/states. Report measured viewport honestly; do not change OS accessibility settings. Real VoiceOver/physical keyboard and physical-input 100 ms timing remain separate evidence.
- Independent Quality Engineer reviews the frozen delta, source-state safety, checks and actual UI evidence. After acceptance, recoverably install 1.7.2 (48), verify the installed artifact and data hashes before launch, then confirm the page in the installed app. No GitHub publication.

Use existing visual authority and native disclosure guidance from [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls). The plan supersedes only the Quota history page composition in the 1.7.1 visual handoff.
