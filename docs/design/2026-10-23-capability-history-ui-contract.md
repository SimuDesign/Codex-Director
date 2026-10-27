# Capability Change History UI Contract — 1.6.0

Status: implementation-ready local visual contract; behavior approved in the
[1.6.0 plan](../plans/2026-10-22-capability-change-history-1.6.0.md).
This document does not claim runtime, accessibility or independent acceptance.

## Authority and scope

Inputs read: public `AGENTS.md` and `HANDOFF.md`; global UI Designer Brief;
project `director-visual-system` Skill; full `DESIGN_SYSTEM_V1.md` and
`VALIDATION_PLAN.md`; approved 1.6 architecture/UX; current capability detail,
folder entry/import Sheet, Settings and typed Scheme A controls/tokens.
`ui-design-method` supplies craft checks only. Existing Scheme A is the approved
direction; no reference round, raster exploration, asset or new token is needed.

The approved plan owns event meaning, scope, ordering, retention, intervals,
query limits, refresh and deletion. This contract specifies their presentation.
Frontend Developer owns source implementation; Software Engineer owns storage
and queries; Quality Engineer owns independent software acceptance. No new
navigation, Home/menu-bar content, source action or automatic effectiveness
claim is introduced.

## Surfaces and hierarchy

| Surface | Required visual order and placement |
| --- | --- |
| Capability Folders **entry** | Keep the existing hero, one folder-name search and folder sections. Add a visible native secondary `变更记录 / Change history` action beneath the entry title/purpose block, before the folder sections, separated by `space.3`. It remains available with an empty directory, removed resources or a failed refresh; it is not filtered by folder search. Do not add it to every folder card or replace New folder. |
| Global history | One native macOS Sheet: title and Close; brief observation limit; three outlined filters; history status; continuous event list; retained-boundary note and paging when supplied. Rows run newest **commit sequence** first. Select an event to reveal its read-only observation/usage summary directly after that row in the same content flow. One selected summary at a time; no nested glass or parallel inspector. |
| Existing Agent/Skill detail | Insert a native `DisclosureGroup` titled `变更记录 / Change history`, closed on initial detail presentation, **after** identity/purpose/ownership and existing companion/membership context, **before** current usage and call evidence. Preserve every existing section's order. The expanded region shows ten recent events, selected-event summary and native `加载更早的记录 / Load earlier records` in twenty-event pages. The history region shares the detail's existing ScrollView; no nested scrolling list. |
| Current resource from history | Provide a genuine secondary `查看能力详情 / Open capability detail` action using the existing detail route and its existing identity/purpose/evidence content. Keep the history selection/filter/scroll context for return. Do not stack a second native modal Sheet over the history Sheet. |
| Resource no longer discovered | Show its last safe name, kind, configuration scope and retained events in a read-only history summary. Clearly label `当前目录中未发现 / Not found in the current directory`. No restore, export, membership, classification or source-opening actions. Absence is not a deletion or execution-failure claim. |
| Settings Privacy, section 04 | Below the existing privacy explanation, add local history scope/retention text and native destructive secondary `清除能力变更记录 / Clear capability change history`. Reuse Settings action geometry. Keep it separate from section 02's derived-index action. |

The native Sheet reuses the import Sheet's ideal 640×600 presentation and
`space.6` inset, constrained to the available parent window. At 720×480 the
platform-visible header/Close and scrolling content must fit; do not force the
import Sheet's 480pt minimum height onto a shorter usable region. Use
`space.4` content insets when compact. A pinned title/Close and a single native
List scroll region are sufficient; explanatory, filter and status rows may
scroll with the list. Do not make structural rows selectable. This local Sheet
does not change primary-page hero sizes or the 380–420pt existing side detail.

## Filters, rows and selected-event summary

Global filter order is timeline period, resource type, event type. Each uses
the existing native `DirectorOutlinedMenuField`, a 36pt painted/hit height,
13pt control type, 176pt preferred width and `space.3` gaps. Measure the actual
inner width once: show three fields when they fit, then two columns, then one
full-width column. Let localized current values wrap and increase fitting
height when necessary; never crop them, shrink their type or replace them with
an icon. Exactly one explicit chevron per menu.

| Control | Initial/current-value wording | Choices and independence |
| --- | --- | --- |
| Timeline | `记录：近 30 天 / Records: Last 30 days` | Last 7 days, Last 30 days, All retained records. Window-session state only, independent of Home and shared usage preferences. |
| Resource type | `类型：全部 / Type: All` | All, Agent, Skill. |
| Event type | `事件：全部 / Event: All` | All plus the four approved event kinds below. |
| Selected-event summary | `统计范围：近 30 天 / Summary: Last 30 days` | Existing outlined native seven/thirty-day control, 232pt preferred width and 36pt minimum height, using an independent local binding. It never inherits `All retained records` as an unbounded query. |

No additional history search field is required. Keep the underlying folder's
single native search editor stable; do not duplicate bound editors in
`ViewThatFits` or keep a hidden accessibility copy.

Event rows use one continuous opaque panel/list grammar and one separator per
event, not individual cards. Row content has `space.4` horizontal and `space.3`
vertical padding, with `space.1` between text lines and `space.2` between groups.
Height fits content; do not impose a one-line fixed row height. Wide layout:
safe name/type/scope leading, observed time trailing, then event text and fixed
document labels below. If a full date or name cannot fit, time moves to its own
leading line. In the 380–420pt detail, always stack these lines. Name may wrap
to two lines in a list; the selected safe-name heading wraps fully. Event labels
and document labels wrap fully. Do not hide identifying text behind ellipses
without a safe full accessible value. No inline count column runs a query.

| Event kind | Visible zh / en label |
| --- | --- |
| added | 新发现 / Newly discovered |
| modified | 已跟踪文档发生变化 / Tracked documents changed |
| missing | 连续两次完整扫描未发现 / Not found in two consecutive complete scans |
| reappeared | 再次发现 / Rediscovered |

Fixed document labels are `Agent 配置 / Agent configuration`,
`Agent 方法文档 / Agent method document`, and
`Skill 说明文件 / Skill description file`. Render only the supplied set.
Rows, tooltips and AX contain no raw path, body, diff, fingerprint, raw exception
or username. Resource type is a textual label; the existing Agent/Skill symbol
may accompany it and is AX-hidden when redundant. Event labels use primary
text, not success/failure coloring: discovering or changing a document says
nothing about quality. `missing` may use the existing warning symbol plus its
full wording. First-unconfirmed absence is a coverage notice, not an event.

Warning ink uses the existing readable `textSupporting`/`textPrimary` token;
reserve the warning status color for its redundant icon. Do not tint small
Light-mode warning text with systemOrange: the local AppKit check measured
about 2.13:1 on the canvas, versus about 7.02:1 for `textSupporting`. This is
a local history presentation rule, not a global status-token change.

The selected-event block uses `space.3` top separation and the same row's
leading alignment, without another rounded panel. Its order is full safe name
where needed, observed time and previous-confirmed time when supplied, the
seven/thirty-day summary control, actual interval, statistics cutoff, call
count, then read-only evaluation counts. Use these exact concepts:

- `观察到变化后的已记录调用 / Recorded calls after the observed change`.
- `已评价调用 / Evaluated calls`, `有效 / Effective`, `无效 / Ineffective`,
  `不确定 / Uncertain`, `未评价 / Not evaluated`.
- `实际统计区间 / Actual summary interval` and
  `统计截至 / Statistics through`, both explicit localized dates/times.

Counts use compact text rows or the current detail-stat grammar with wrapping
labels, not hero metrics, a score, percentage, trend or chart. Always show the
actual bounded interval and cutoff near the values. Unknown uses `—` **and** a
reason; confirmed computed zero uses `0` with `未观察到已记录调用 / No recorded
calls observed`. A partial known count retains a visible partial/inferred
qualification; it must not appear as a complete total. Evaluation coverage is
independent: unavailable ratings do not become zero or make all calls
unevaluated. Current ratings join calls by actual call time and resource ID,
never rating edit time. Missing events show their observation explanation only,
with no post-change usage/evaluation metrics or summary-period control.

Use localized full date and time for observed/cutoff/interval values; narrow
layouts wrap before dropping the date. Identify observed time as observation,
not source-modified time. `previousConfirmedAt` may be presented as a possible
change interval, never as the precise modification instant. Display the fixed
limit text in the Sheet and expanded detail:
`两次扫描之间的多次修改可能无法逐次记录。 / Multiple changes between scans may not be recorded individually.`
Also state that Agent configuration/method documents are tracked and Skills
track only SKILL.md; scripts, images, binaries and other supporting files are
outside this version. Do not call this complete capability-package versioning.

## State presentation

Status uses supporting type, a static redundant symbol where useful, a concise
label and explanation, plus a native action only when allowed. Keep previous
valid rows readable and selectable during refresh/read failure. State text does
not replace the full workspace with a spinner or convert absence to zero.

| State | Required presentation and recovery |
| --- | --- |
| Initial/baseline pending | `等待建立基线 / Waiting for a baseline`; explain that the next normal capability refresh establishes it. Existing Refresh data may be used. Do not fabricate added events or trigger a scan on open. |
| Initialized, no events | `尚无变更记录 / No changes recorded yet`; explain that the baseline is established. This is distinct from baseline pending. |
| Filters match nothing | `没有符合筛选条件的记录 / No records match these filters`; keep filters operable. Never call this an empty store. |
| Loading / pagination / summary pending | Small native progress indicator with localized task label. Preserve loaded rows; keep pagination button footprint stable and disable only repeated activation. Unknown counts show `—`, not 0. |
| Partial/unstable scope or pending absence | Warning symbol + `记录覆盖不完整 / History coverage is partial`, or explicit awaiting-confirmation wording. Explain only reliable observations are recorded. A first absence does not appear as confirmed missing. |
| Source scan incomplete / unavailable | Explain source coverage, not storage failure. Mixed readable/unavailable sources are partial; legacy unavailable latest-scan coverage gets a source-scan-not-completed notice without inferring how many sources succeeded. Retained records and truthful initialized-empty content remain readable. Explain the existing Refresh data action; do not offer a read-only Retry as a scan repair. |
| Writer conflict, readable history | Explicit read-only recording notice. Retained rows and truthful empty state remain usable; never say readable history is unavailable or show a misleading read Retry. |
| Temporarily unreadable | `变更记录暂不可用 / Change history is temporarily unavailable`; keep old rows and native Retry. Do not show a simultaneous empty or baseline claim. Read retry rereads history only; no new scanner, watcher or timer. |
| Recording/write failure | `未能保存最新观察 / Latest observation could not be saved`; old rows remain the last saved state. Explain an observation gap and the existing Refresh data path; do not relabel the old baseline as current, claim missing changes will be recovered or offer read Retry as a save repair. |
| Corrupt file | `变更记录文件损坏 / Change history file is damaged`; retain any valid in-memory rows with a last-valid qualification. Retry is read-only. Do not automatically replace/reset; explicit clear remains in Settings confirmation. |
| Unsupported history version | `此版本的变更记录暂不受支持 / This history version is not supported`; no empty-state claim, silent downgrade or overwrite. |
| Retention truncated | Supporting boundary note uses the actual supplied oldest-retained date/boundary; state the 180-day / 100-per-capability / 20,000-global limits. `All retained records` never means all-time history. Absence of older rows is not proof of no change. |
| Clock anomaly | Warning symbol + `检测到时间异常，按记录顺序显示 / Time anomaly detected; showing record order`. Keep sequence order, hide invalid duration/interval metrics and explain summary unavailability; never show negative/inverted intervals. |
| Event outside selected 7/30 days | `不在本次统计范围 / Outside this summary window`; keep event visible and period control available, without a fabricated 0. |
| Index absent/cleared | Timeline remains readable; summary says `调用数据尚未索引 / Call data is not indexed` or unavailable, with `—`. Opening history never reparses source sessions. |
| Cutoff before observation | `调用数据尚未更新至该观察时间 / Call data is not yet updated through this observation`; show the real prior cutoff. This is not zero or filter-empty. |

Clear confirmation uses a native confirmation dialog with Cancel as the safe
default and explicit destructive `清除记录 / Clear history`. Message:
`这会永久清除本机能力变更记录。早期记录无法从当前文件重建；下一次正常刷新将重新建立基线。源文件、人工评价、文件夹和派生索引保持不变。 /
This permanently clears local capability change history. Earlier records cannot be rebuilt from current files; the next normal refresh establishes a new baseline. Source files, evaluations, folders and the derived index remain unchanged.`
Cancel/Escape writes nothing. While clearing, disable repeat activation and
show native progress without shifting the action. Success returns to baseline
pending and removes old selected summaries; failure keeps existing rows and
shows a safe localized error. Derived-index deletion's own explanation and
confirmation explicitly say capability change history is retained.

## Tokens, appearance, focus and accessibility

Reuse `DirectorColor.canvas/panel/inset`, `textPrimary/textSupporting/dataText`,
`boundary/controlBoundary/focus`, resource colors and existing warning/failure/
unknown semantic styles. Use `DirectorTypography.sectionTitle`, `body`,
`supporting`, `label`, `segmentedControl`, `capabilityRowTitle/Summary` and
`data` with monospaced digits for counts. Do not use Home-only Avenir numeric
roles. All spacing above maps to `DirectorSpacing`; native controls retain
native metrics. No new palette, shadow, radius, icon family or material.

Normal/hover/pressed/disabled controls keep existing shared styles. Selected
rows have one contained opaque Scheme A wash, explicit selected AX state and
readable text; focus is a separate visible system focus boundary. Preserve
native List selection/arrow semantics; do not introduce a window-wide table
paint override. Light/Dark follow the app store immediately. Increase Contrast
strengthens existing boundaries and focus; required small metadata meets 4.5:1
on its actual surface. Reduce Transparency uses opaque `inset`; native Sheet
chrome may use platform material, with no content glass. Disclosure/selection
may use `motion.standard` (200ms), existing detail movement uses its current
transition; Reduce Motion uses immediate state change or brief opacity.
No entrance spectacle, shimmer or looping activity decoration.

Keyboard/AX contract: entry action, Sheet Close, filters, selectable events,
selected-event controls, native paging and current-resource detail action are
genuine controls. Tab/Shift-Tab, native menu keys, arrows and Return operate
according to their native roles. Escape closes the active confirmation first,
then the active detail/history presentation; it must not dismiss underlying
folder context simultaneously. Closing/returning restores focus to the exact
source action/event/disclosure where it still exists, otherwise the containing
history heading. Preserve underlying folder/tab/filter/scroll state.

On Sheet presentation focus enters the modal heading/first control; background
content is not part of its traversal. Disclosure exposes localized title,
expanded/collapsed state and expanded children. Event AX reading order is safe
name, type, scope, event, observed time, fixed documents, selected state; summary
then reads interval, cutoff, count/coverage and evaluation counts. Decorative
symbols/separators are hidden, not duplicated as announcements. Closed menus
expose label, live current value and selected choice; no hidden replica.
AX inspection and **actual VoiceOver speech** are separate evidence gates.

## Synthetic acceptance and handoff

Use only memory history stores and synthetic names/scopes/dates. A compact
fixture includes `Review Analyst` (Agent, Global, changed config + method),
`sample-report-skill` (Skill, Project Aurora, Skill document changed), one
rediscovered capability, one confirmed-missing capability, a pending absence,
a long bilingual safe name, matching timestamps with distinct sequence, and
an A→B→A pair. Provide 10/11/30 events and a 20,000-event stress projection.
No real source body, path, session, account or history JSON enters screenshots.

- Verify zh-Hans/en × Light/Dark at actual product viewports 720×480,
  1280×800 and wide. Record native Sheet bounds separately. At compact width,
  all filter values, full dates, primary actions and counts remain readable;
  content scrolls vertically without horizontal overflow or nested scrolling.
- Verify both global Sheet and default-closed detail, selected summary,
  removed-resource summary, pagination and every state above. Switching a
  timeline filter/pages does not query each event. Selecting one eligible
  event loads one bounded summary; selection/close/clear invalidates old work.
- With `All retained records`, keep summary at 7/30 days; verify actual interval,
  known zero, partial/inferred, unknown, outside-window, prior-cutoff,
  missing-index and unavailable-evaluation representations separately.
- Exercise native keyboard, Escape hierarchy, source focus return, current
  capability detail return, filter edge/padding/chevron hits and one native
  search editor. Inspect actual native AX and record real VoiceOver separately.
- Exercise Increase Contrast, Reduce Motion and Reduce Transparency on both
  surfaces, including Dark + Increase Contrast. No state is conveyed by color
  alone; no selected paint leaks outside the list boundary.
- Cancel/confirm/fail history clear with synthetic stores. Verify derived-index
  deletion retains history; no clear affects sources, ratings or memberships.
- Preserve existing folder entry search, three tabs, members, period/sort,
  expansion/scroll, detail evidence, theme and shared refresh behavior.

Frontend Developer implements this contract against the stable history page,
status and bounded summary projections. No UI file/SQLite work belongs in view
body. Runtime screenshots, interaction, VoiceOver, performance and independent
acceptance are still required; this document is their target, not their proof.
