# Codex Director Visual System Validation Plan

Version: `0.3.1-annotated-ui-polish`  
Applies to: `DESIGN_SYSTEM_V1.md`, `director-visual-system`, and future native UI implementation  
Last updated: 2026-09-05

The approved [0.2 redesign](../../docs/plans/2026-08-28-capability-centered-redesign.md) replaces the earlier product journeys. Existing component, accessibility and privacy rules remain. Menu-bar, pet, topology and workflow examples are dormant guidance, not required new features for this release. No prior build/test result counts as proof of the new source snapshot.

The approved [0.2.1 startup repair](../../docs/plans/2026-08-28-startup-performance.md) additionally requires cached, nonblocking startup and delayed background statistics. The gates below are acceptance requirements, not a statement that implementation or measurements have passed.

## 1. Validation objectives

The approved Card Atlas Home contract supersedes the earlier numbered-module presentation. Home uses three outline modules with distinct quota, continuous-metric and comparison-ledger grammars, a compact illustration-free welcome hero and a window-level refresh action. The quota chart shows reset-aware observed daily use of the weekly allowance, not cumulative daily-end snapshots. The four capability pages use four independent metrics with visible hover states, a single flexible search field, narrow right-chevron menus, global-first project ledgers with item separators and closed bottom corners, plus a 380–420 pt dismissible right-side detail Sheet. Verify all four pages in zh/en x Light/Dark x 720×480, 1280×800 and wide windows, with long names, empty/confirmed-zero/pending/failure-with-old-data states, four-card filtering and 4/2/1 metric behavior. The whole capability surface must be one native `List(selection:)` scroll container; header, metrics, ribbon and groups must share the page grid without row-background spill. All six primary destinations share Home's 40/16pt horizontal gutters, 24pt vertical gutters, 1440pt maximum content measure and far-right scroll-indicator edge. Titles share the 52/36pt rounded semibold scale. Settings and capability titles keep the solid primary-text treatment and share the 24pt decorative symbol token, while Home remains illustration-free and applies the brand gradient only to the `Codex Director` fragment of its welcome title. The window toolbar product name retains the native title treatment. The selected sidebar destination uses the brand gradient with black content and native List selection semantics. Home's additional gate covers symmetric module-title spacing, removed summary/ranking subtitles, the 20pt Reduce Motion-aware centered ring with reset time below, a segmented source switch, dynamically scaled gradient daily-usage bars, horizontal grid only and centered dates. Capability project groups require visibly tinted icon-led headers and 16pt separation. Settings keeps its title icon, omits the eyebrow and hero subtitle, presents section 01 as Language & appearance, balances section top/bottom padding, top-aligns ordinals, and uses equal-width/height index actions. The shared toolbar refresh remains labeled but uses the 28pt compact size. Actual VoiceOver evidence and AX inspection must be recorded separately.

For Top5 cache upgrade verify immediate old-content display, at least5s foreground grace, a bounded read-only Home projection with zero quota/source scans, correct identity/classification/window/cancellation guards, old data retained on failure, existing retry semantics and no upgrade query on a fresh Top10 cache. Full tests and Release0.2.8(11) checks follow frozen-source visual acceptance; old results are not new evidence.

Prove that the design system is:

- discoverable for the correct tasks;
- silent for backend and unrelated tasks;
- consistent across the main window, menu bar, topology, timeline, workflow, health, and desktop-pet surfaces;
- native to macOS rather than an iPhone or generic web imitation;
- correct under accessibility and privacy settings;
- implementable without arbitrary visual constants;
- efficient enough for a local always-available utility.

## 2. Validation gates

### Gate 0 — Scope and source integrity

- Confirm source and design changes remain inside the Codex Director repository. Explicitly scoped disposable build/test/GUI artifacts may use isolated temporary directories; they must not overwrite installed apps or user data.
- Confirm no global Skill or Codex configuration changed.
- Confirm no third-party Skill folder, Apple PDF, UI kit, font, or proprietary asset was copied.
- Confirm third-party references are links only.
- Confirm original Codex resources and session logs remain unmodified.

### Gate 1 — Skill structure

- Run the system Skill `quick_validate.py` against `.agents/skills/director-visual-system`.
- Confirm directory name and frontmatter name are both `director-visual-system`.
- Confirm `agents/openai.yaml` matches the Skill description.
- Confirm no TODO or placeholder remains.
- Confirm all referenced project files exist.

### Gate 2 — Trigger behavior

Implicit positive prompts must not mention the Skill name and must automatically select the Skill:

1. `为 Codex Director 设计菜单栏运行状态。`
2. `实现主窗口的 Liquid Glass 工具栏。`
3. `审查拓扑节点和桌面宠物是否符合设计系统。`
4. `为 Invocation Timeline 定义错误、重试和 inferred 状态。`

Explicit invocation tests must independently verify:

1. `$director-visual-system 为菜单栏状态提出设计方案。`
2. `$director-visual-system 审查一份拓扑节点实现。`

Negative prompts must not trigger it:

1. `优化 session JSONL parser。`
2. `修复 SQLite 增量索引。`
3. `扫描全局 Skill 目录并规范化路径。`
4. `分析某次 tool call 为什么失败。`

Boundary prompts must remain outside project scope:

1. `为普通 iPhone App 实现 Liquid Glass。`
2. `设计另一个项目的营销网站。`
3. `把这个设计 Skill 安装到全局。`

Pass condition: implicit prompts select the Skill without naming it; explicit prompts resolve the Skill by name; both read project sources and follow the output contract. Negative and boundary prompts must not apply project-specific rules.

### Gate 3 — Token and component compliance

For each visual change:

- Identify every color, spacing, radius, typography, material, symbol, and motion token used.
- Reject unapproved fixed colors or arbitrary constants.
- Confirm native components were considered before a custom component.
- Confirm resource type, runtime status, and evidence confidence use separate visual channels.
- Confirm new reusable components have a platform invariant or at least two concrete consumers.

Future automated checks should flag:

- raw RGB/hex colors outside approved token definitions;
- repeated numeric spacing/radius values outside token definitions;
- direct glass use inside table rows, timeline rows, or repeated resource cards;
- screenshots or fixtures containing real absolute paths or conversation text.

### Gate 4 — Component previews

Create synthetic-data previews for:

- Sidebar destination: normal, hover, selected, badge.
- Toolbar: normal, compact width, disabled action, search active.
- Inspector: exact, inferred, unknown, redacted.
- Status badge: all runtime states.
- Topology node: every resource type plus selected/focused/failure states.
- Topology edge: exact, inferred, unknown, highlighted path.
- Timeline event: nested call, retry, error, unknown duration, compaction.
- Menu-bar popover: idle, running, approval, completed, failed, offline index.
- Desktop pet: idle, indexing, running, tool call, waiting approval, success, warning, failure, blocked, unknown/offline, visible, interactive, click-through, paused, hidden, and Reduce Motion.

Each preview must run through the appearance matrix in Section 3.

Before preview implementation, verify each required SF Symbol resolves through `NSImage(systemSymbolName:accessibilityDescription:)`. Missing symbols fail the contract and require an approved token update.

### Gate 5 — Interaction

Verify:

- mouse hover and click;
- trackpad scroll and zoom where applicable;
- right-click/context actions where useful, not indiscriminately;
- keyboard focus order;
- Tab, Shift-Tab, arrow keys, Escape, Return, and documented shortcuts;
- sidebar/inspector collapse;
- window resize and restoration;
- topology selection mirrored in an accessible inspector/list;
- pet does not steal focus or block underlying controls in click-through mode.

### Gate 6 — Accessibility

- Verify VoiceOver names, values, roles, and reading order.
- Verify keyboard-only completion of primary flows.
- Verify no state relies only on color, opacity, motion, or pet behavior.
- Verify Increase Contrast preserves boundaries and selection.
- Verify Reduce Transparency replaces fragile glass with legible system fallback.
- Verify Reduce Motion stops spatial/path playback while preserving state.
- Verify text and controls remain usable at supported window sizes.

### Gate 7 — Privacy

- Use only synthetic fixtures for previews, tests, screenshots, and documentation.
- Check menu-bar and pet surfaces for prompt text, task title, tool arguments, raw paths, or identifiers.
- Check inspector defaults for collapsed/redacted raw payloads.
- Check exported images and debug overlays.
- Check accessibility labels, which can leak content even when visual text is hidden.

### Gate 8 — Performance and energy

Establish a baseline Mac and dataset before assigning hard release thresholds. Record:

- launch to usable main window;
- memory with main window closed and menu bar active;
- memory with topology open;
- idle CPU with pet disabled, static, and animated;
- topology pan/zoom behavior at representative small, medium, and stress datasets;
- timeline scrolling with representative long sessions;
- indexing activity isolated from rendering measurements.

Provisional behavior requirements:

- Pause visualization rendering when its window is closed or occluded.
- Avoid loading the topology WebView/renderer for menu-bar-only use.
- Pause pet animation when hidden or screen-locked.
- Provide a low-motion/low-energy mode.
- Keep indexing and database work off the main actor.

Do not claim a numeric performance target has passed until the baseline hardware, build type, dataset, measurement tool, and sample duration are recorded.

### Gate 8b — Startup and delayed statistics (0.2.1 release gate)

- Record the baseline Mac, actual SQLite runtime version, optimized build identity, dataset and measurement method. Use isolated synthetic storage, never production preferences or source logs.
- Cover cache present/fresh, cache expired, cache absent with an existing index, and an empty installation. The native window, all six destinations and Settings remain usable; only unknown values show a pending state.
- With a fresh cache, ten launches inside the persisted 30-minute interval produce zero source scans and zero quota aggregation runs. Expired-cache background work starts no sooner than five seconds after the first usable window.
- For at least twenty samples, report median, p95 and maximum separately for process-to-interactive-window, cached Home visibility, quota projection and input response. Targets: p95 at most two seconds for a usable window, 500 ms for the 200,000-observation quota query/projection, and 100 ms for ordinary UI feedback. A microbenchmark is not a process-launch measurement.
- Use realistic-length String IDs, 200,000 quota observations with two sources and reset/missing-day cases, and 160,000 invocations across roughly 1,500 sessions including one 27,000-call session. A simplified integer-ID fixture does not replace this baseline.
- Record a sixty-second startup/background-update trace: no data-loading-caused MainActor block of 100 ms or more. Separately label OS/rendering overhead. Check idle CPU and the absence of the former two-minute full refresh.
- Verify query deadlines stop actual SQLite execution, release the connection and do not leave zombie tasks. Verify a separate read-only query connection remains independent of indexing writes and cannot migrate/checkpoint/write.
- Verify one app-scoped scheduler across windows, one active operation plus one coalesced latest request, persisted 5/15/30-minute failure backoff, clock rollback, sleep/wake, hidden-window pause and cancellation.
- Exercise epoch/generation invalidation: late success, late failure and late cache writes must not overwrite newer data or resurrect a deleted index. Persisted evaluations, classification overrides and source fixtures remain intact.
- Final frozen-source focused/full tests, optimized stress tests, GUI evidence and production Release identity/resources/signature checks are separate requirements. Clearly record unmeasured gates; never replace them with an earlier test count.

## 3. Appearance matrix

Test each core component and surface across:

| Dimension | Required cases |
| --- | --- |
| Appearance | Light, Dark |
| Contrast | Standard, Increase Contrast |
| Transparency | Standard, Reduce Transparency |
| Motion | Standard, Reduce Motion |
| Window | Minimum supported, default, wide/full-screen |
| Input | Pointer, keyboard, VoiceOver |
| Data | Empty, small, representative, stress, malformed/unknown |
| Privacy | Normal synthetic, redacted |

Pairwise coverage is acceptable during component development. Before a release candidate, cover every accessibility setting for every core surface and run targeted combinations that are likely to interact, such as Dark + Increase Contrast and Reduce Transparency + Reduce Motion.

The v1 system matrix covers macOS 26.x only. Earlier macOS versions are outside the supported deployment target. Any proposal to support them must add OS-version cases, API availability branches, material fallbacks, and a separate visual baseline before implementation.

## 4. Critical user journeys — 0.2

### Journey A — Understand current and daily quota use without inventing consumption

1. Open Home with synthetic data containing two quota sources, a missing day and reset boundary.
2. Read remaining percentage, reset time below the ring and “daily weekly-quota use”.
3. Change the visibly named source; both donut and bars switch together.
4. Switch to an expired current observation; show waiting, not 100%, while retaining history.

Expected: seven local dates; same-cycle increases become daily percentage-point use; a reset day retains observed use before and after the boundary; missing, cross-gap and ambiguous transitions remain unavailable; confirmed flat observations may show 0%. The named segmented source control switches ring and bars together. There is no Token conversion, recorded-time/evidence clutter, cross-source mixing or ambiguous reset label, and values remain readable without color/hover.

### Journey B — Inventory and project usage are distinct

1. Home's four totals open the matching category with All capabilities scope.
2. First independent category entry defaults to Global configuration.
3. Project configuration overview includes a never-used project-specific capability.
4. Project A usage includes a global Agent also used in Project B; each project has its own count/recency.
5. A historical-only member remains with zero recent calls; unassociated calls never enter either project.

Expected: category totals ignore search; same-name different IDs remain separate; visible scope/sort values; each page preserves its own state. Seven-day used count is distinct resources, not calls.

### Journey C — Read evidence and record usefulness

1. Open a capability from a Home ranking or list.
2. Inspect declared purpose, recent usage and projects; open paginated invocation evidence.
3. Distinguish exact/inferred/unknown, execution outcome and effective/ineffective/uncertain evaluation.
4. Set, modify and clear an evaluation. Apply a classification correction in disclosure.
5. Refresh, switch language and return to the page; reindex synthetic logs.

Expected: stable identity, no auto-effective label, no fabricated description, evaluations/corrections retained. Narrow detail has a textual Back to list and Escape.

### Journey D — Understand installed capabilities

1. Seed current enabled and disabled plugin packages, old cached versions and plugin-provided Skills.
2. Installed plugin count includes disabled but not old caches/children; installed Skill includes current plugin Skills exactly once.
3. Compare uniquely mapped namespace evidence, explicit child Skill evidence, ambiguous namespace and unsupported plugin.

Expected: wrapper/child event not double-counted, inferred attribution labeled, unsupported/ambiguous coverage never presented as a definite zero.

### Journey E — Settings and capability export

1. Access language, Light/Dark appearance, current indexing state, last index time, privacy and version from Settings.
2. Switch zh→en→zh and Dark→Light→Dark without recreating models or restarting indexing.
3. Reindex and observe progress; exercise failure/retry with synthetic data.
4. Confirm deletion of derived index; verify source fixtures, evaluations and classification overrides remain.
5. Export selected synthetic global capabilities and one opted-in project. Exercise preflight blocking, exclusion, cancellation, save and success states.
6. Reopen the ZIP, verify its fixed roots, every SHA-256, executable bits, path placeholders, incomplete-plugin semantics and bilingual `RESTORE.md`.

Expected: Chinese default, shared multiwindow language, default Dark theme, immediate shared multiwindow theme changes, current version 0.3.1 (16), no production preference/data access by validation host, and no writes to Apple's global appearance preference. Source fixtures receive zero writes; failed or cancelled export leaves no partial package.

### Journey F — Geometry, refresh and accessibility

Test all six pages and representative details in zh/en, Light/Dark, minimum720×480/default1280×800/wide. Verify actual-content breakpoints760/1000; compact numbers never split, selected controls keep readable values, chart text and native roles survive AX inspection. Verify the toolbar refresh button in idle, source/projection loading and failed-recovery states; its text never disappears, loading uses native `ProgressView`, and Settings uses the same state. Complete hover, keyboard focus/activation, back/Escape, evaluation and settings flows under standard and Increase Contrast/Reduce Motion conditions. Record VoiceOver reading separately from AX-tree inspection; untested cases must be listed, not inferred from unit tests.

### Journey G — Launch, continue working and refresh later

1. Launch an isolated app with a saved Home projection. Immediately navigate, search and open Settings while background services are still initializing.
2. Relaunch within thirty minutes. The prior view is readable with its real record/update times; no source scan or quota recomputation occurs.
3. Advance the injected clock past freshness. Keep old data visible during the five-second grace and background update, including when updating fails.
4. Repeat with no presentation cache but an existing derived index: show the directory before heavy statistics and pending values as “—”, without triggering source reindexing.
5. Repeat with no index: navigate all six destinations and manually start indexing; no synthetic inventory or fabricated zeros appear.
6. Open a second window, repeatedly update, switch language and cross midnight/a quota reset. Verify shared scheduling, retained selection/evaluation and correct independent time semantics.
7. Cancel a slow read and delete the synthetic derived index while work is pending; wait for late completions. No stale content may reappear.

Expected: failures are local, content does not vanish behind a full-page spinner, controls stay usable, the four timestamps retain their distinct meanings, and quota expiry never invents a full balance. The release-equivalent synthetic bootstrap must traverse the actual startup path, not only a preconstructed preview model.

### Automated invariants

- Seven-day start/end and midnight refresh in multiple timezones; language independence.
- Reset-aware daily weekly-quota deltas, confirmed zero, missing baseline, cross-day gap, ambiguous reset evidence, source isolation and backward-compatible presentation-cache decoding.
- Project path component boundary, longest registered root, unmatched, append preservation and parser-version reparse.
- Current package membership, cache deduplication, disabled state, plugin Skill identity and attribution deduplication/ambiguity.
- SQL summary time/project filtering, per-capability paging, nil-timestamp/unresolved exclusion and diagnostic counts.
- Persistent evaluation/classification IDs and separate language preferences across refresh/reindex.
- Theme default/invalid fallback, dedicated preference key, in-memory isolation, persistence across stores, Light/Dark mapping, multiwindow synchronization and zero refresh/index side effects.
- Refresh loading truth table: indexing/source/projection active; startup grace/waiting/idle/failed inactive. Verify manual/automatic updates, coalescing and failure recovery without altering scheduler semantics.
- Shared refresh button visible-label, native-progress, stable-width and standard/toolbar-size contracts; black foreground contrast is at least `4.5:1` against every Light/Dark gradient endpoint and every gradient action consumer uses the shared token.
- Capability package manifest v1 sorting, Agent config/Brief pairing, project opt-in, exclusions, path redaction, credential blocking, symlink containment, binary warnings, ZIP traversal rejection, cancellation cleanup and isolated round-trip restore.
- Localization callsite/key/placeholder/plural/terminology coverage and visible selector contract.
- Fresh full tests plus final Release identity/version/signature, packaged bilingual resource lookup and Debug validation exclusion.

## 5. Visual regression strategy

When the Xcode project exists:

1. Create deterministic SwiftUI previews with synthetic fixtures.
2. Capture reference images for core component states and surfaces.
3. Store baselines outside sensitive runtime-data directories.
4. Review diffs for layout, clipping, color semantics, material hierarchy, focus, and redaction.
5. Require human review for Liquid Glass, animation, pet behavior, and topology legibility; pixel equality alone is insufficient.

Update a baseline only with a linked design-system decision and review evidence.

## 6. Skill forward-test rubric

For each positive test, score `pass`, `partial`, or `fail`:

| Criterion | Pass behavior |
| --- | --- |
| Intake | Reads project routing and design sources before answering |
| Platform | Uses macOS patterns rather than iPhone or generic web patterns |
| Material | Keeps Liquid Glass in the functional layer |
| Semantics | Separates resource type, runtime status, and confidence |
| States | Covers relevant interaction and data states |
| Accessibility | Covers contrast, transparency, motion, keyboard, and VoiceOver |
| Privacy | Keeps compact surfaces and fixtures synthetic/redacted |
| Boundary | Avoids backend redesign and global Skill mutation |
| Validation | Names concrete evidence required before completion |

Acceptance: no `fail`; `partial` requires an explicit follow-up change and repeat test.

## 7. Release evidence

Before design-system v1 is marked stable, collect:

- successful Skill structural validation;
- positive, negative, and boundary trigger results;
- component inventory and token implementation;
- preview/screenshot matrix results;
- accessibility audit notes;
- privacy audit notes;
- representative topology and timeline performance measurements;
- unresolved exceptions with owners and rationale;
- user approval of the overall visual direction.

## 8. Rollback and revision

- Keep design tokens and components versioned with the application source.
- Revert a visual-system change by reverting its token/component change and associated baseline update; do not edit runtime data.
- If an Apple API or guideline changes, update the source record, review affected components, and rerun relevant matrices.
- If a third-party reference changes, do not adopt it automatically; repeat review and approval.
- If the Skill over-triggers or under-triggers, adjust frontmatter description first, then rerun the trigger suite.

## 10. Scheme A implementation matrix — 0.2.5

The approved Scheme A migration promotes Home's validated canvas, opaque
panel, inset, boundary and emphasis tokens to the shared Director design
system. Validate Home's `HomeCardAtlasFrame`, `HomeOutlineModule`,
`HomeMetricStrip`/`HomeMetricSegment`, `HomeRankingLedger`, ring and chart
states, and filled primary action. Validate `DirectorEditorialFrame`,
`DirectorEditorialHero`, `DirectorSectionBand`, `DirectorMetricSequence`,
`DirectorMetricCard(tone:)`, `DirectorGroupHeader`, the visible filter ribbon,
table stage, Inspector, primary action style and the 4/2/1 adaptive grid across
the four capability pages and Settings. Check the central Light/Dark accent
definitions, deep-teal environment light, blue/ice/mint ranking tones, native
focus/disabled/pressed states, restrained selected-row wash and Increase
Contrast boundaries. No content surface may introduce glass or heavy shadow.

The synthetic Debug `UIValidationHost` must provide representative, empty and
stress fixtures, language switching, an in-memory Light/Dark app theme plus the host appearance matrix, and selectable
720×480, 1280×800 and wide viewports. The host uses UUID-scoped temporary
databases and in-memory preferences only; it must not read production
preferences, logs, source roots or installed app data. The native sidebar
exposes the six approved pages for this matrix.

Focused source/tests cover shared component construction, breakpoints, Home
shared-component consumption, all four capability category tones and filters,
Settings ordering and primary-action binding, fixture isolation and host
control contracts. This record does not claim actual VoiceOver reading,
accessibility settings interaction, independent visual regression acceptance,
or Release build evidence; those gates remain for Root/independent acceptance.

## 11. Native recomposition screenshot gate — 2026-08-31

The final-matrix gate requires real Validation Host screenshots plus AX text,
not previews or source-only evidence. The minimum representative set is Home,
Custom Agent, Custom Skill, Installed Skill, Installed Plugin and Settings in
zh-Hans/Dark/1280; add Agent en/light/1280, zh-Hans/Dark/720 and stress/empty,
plus Settings/720. Record actual AX viewport values separately from image
dimensions because Host controls consume part of the captured image. Compare
each after state against its immutable baseline and `option-a.html` for
hierarchy, scan path, Hero scale, tone mapping, section rhythm, native
selection/focus, and compact staged-detail behavior. This gate is visual review
evidence only and does not replace keyboard, AX, privacy, focused-test or
Release checks.

## 12. Refresh and theme matrix — 0.3.1

For zh/en at 720×480 and 1280×800, capture Settings and a representative main
destination in both Light and Dark. Check the segmented theme selector, the
toolbar and Settings refresh controls in idle/loading/failure-recovery states,
stable control width, black gradient content, hover, focus, disabled state,
Increase Contrast and Reduce Motion. The Debug host must use only its injected
memory theme store. Release validation must confirm the dedicated preference
survives relaunch, applies to a second window and SwiftUI sheet, and does not
touch `AppleInterfaceStyle` or start indexing/refresh work.

In both languages, Settings section 06 must expose a localized Author label
whose value is exactly `七木 Simu`, followed by the version row. Verify the
combined label/value is available to accessibility without a duplicate
container announcement.

## 9. Initial validation record — 2026-08-15

Environment:

- macOS `26.5.1` (`25F80`)
- Xcode `26.6` (`17F113`)
- Deployment decision: macOS `26.0+`

Completed evidence:

- Confirmed every created asset is under the Codex Director repository.
- Confirmed no global Skill, global Codex configuration, or third-party Skill folder was added.
- Confirmed `SKILL.md` contains 113 lines and no initializer placeholder.
- Parsed `SKILL.md` frontmatter with Ruby YAML and mirrored every check in the system `quick_validate.py`, plus the project-specific three-word naming rule: pass.
- Confirmed the folder name and frontmatter name both equal `director-visual-system`.
- Compiled a representative probe of 20 unique AppKit color APIs used by the foundation, status, and resource bindings against the installed macOS 26 SDK: pass. Recheck the final typed-token implementation separately because several semantic tokens intentionally reuse the same system color API.
- Resolved all 10 specified SF Symbols through `NSImage(systemSymbolName:accessibilityDescription:)`: pass.
- Compiled a Swift probe containing `GlassEffectContainer`, `.glassEffect()`, `NSGlassEffectView`, and `NSGlassEffectContainerView`: pass.
- Compiled a Swift probe containing the specified SwiftUI accessibility environments and AppKit `NSWorkspace` accessibility display options: pass.

Pending evidence:

- The system `quick_validate.py` cannot currently import `PyYAML` in either available Python runtime. Do not install a global dependency merely for this check; rerun when a vetted environment supplies PyYAML.
- Implicit, explicit, negative, and boundary trigger tests require a fresh Codex task that reloads the project Skill catalogue.
- Component previews, appearance matrices, visual regression, VoiceOver, privacy, and performance checks require the Xcode application and components to exist.

This record validates the governance assets and declared macOS API surface. It does not claim that the future application UI has passed implementation-level gates.
