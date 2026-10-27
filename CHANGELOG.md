# Changelog

All notable public changes will be documented here. The project follows semantic versioning for public releases.

[简体中文更新说明](CHANGELOG.zh-CN.md)

## 1.6.1

Codex compatibility and refresh reliability. Internal build: `43`.

- Includes the local capability change history introduced in 1.6.0, together with its empty/unavailable-state repair and current Codex registry/completion compatibility fixes.
- Keeps available projects, account usage, plugins and sessions refreshable when individual project storage is slow or unavailable; retains verified cached capabilities and relations instead of treating a failed scan as deletion.
- Fixes repeated scanning of long JSONL lines and runtime-command exit waiting. Preserves existing folder members, evaluations, stable IDs and capability-package manifest v1.
- Live validation recovered 42 readable project sources; three configured paths were absent. Storage wait causes remain unestablished, and older unchanged archives outside the eligible replay window remain deferred.
- This source update does not create a Git tag, downloadable GitHub Release, Developer ID signature or Apple notarization.

## 1.6.0

Local capability change history and compatibility repairs. Internal build: `42`. Local iteration only;
no Tag or GitHub Release is implied. See the validation record for acceptance
evidence; a changelog entry is not a test or deployment result.

- Tracks verified Agent configuration/method documents and custom or independently installed `SKILL.md` files. The first reliable per-scope scan is a silent baseline; later reliable observations record additions, document changes, two-scan absence and rediscovery.
- Adds a lazy, filtered history Sheet from Capability Folders and an initially closed history section in details. Removed capabilities retain a safe read-only summary; no source content, paths or diffs are displayed or stored by history.
- Provides one selected-event, bounded 7/30-day call and manual-evaluation summary with explicit interval, cutoff and evidence coverage. Current ratings join actual calls, not rating-edit times, and counts do not claim causal effectiveness.
- Keeps history in a separate bounded local store with atomic commits, cross-process writer exclusion and confirmed clearing in Privacy. Derived-index deletion retains history; source files, evaluations, folder members, schema v6, cache v1 and package manifest v1 remain unchanged. The history feature itself does not require rollout replay; the separate compatibility repair below advances the parser.
- Repairs history availability notices: an unavailable project does not make readable retained history unavailable; empty records, partial source scans, read-only recording and real read failures remain distinct. Existing baselines and records are preserved without a history-format migration.
- Repairs supported structured tool completion states without counting the completion event as another call. Parser v1.4.2 corrects eligible recent evidence through the existing transactional replay policy; unchanged older archives remain deferred. Unsupported role-less child sessions are not guessed into specialist Agent totals.
- Recognizes supported project registry packages, including v5 explicit native-Agent and Skill declarations, using canonical capability identities. A valid packages layout is not treated as an invalid legacy entries list. Relationship projection v3 refreshes source declarations without changing folder membership or capability files.
- Avoids unrelated extended-attribute queries when checking directory type during source discovery; retains permission, symlink and unavailable-source handling. This does not promise a timeout for every filesystem/provider operation and does not change checkpoint timestamp calculation.
- Avoids repeatedly searching the same unfinished JSONL line as more chunks arrive. Long records retain their complete content and offsets; this reader optimization does not change parser v1.4.2, source files or previously committed checkpoints.
- Uses descriptor-backed directory enumeration with fail-closed permission, symlink and read-error handling. Local source-discovery diagnostics contain only fixed phase/kind labels and root ordinal/total, without paths, names or contents. Nonblocking open flags are not a general filesystem timeout guarantee.
- Registers runtime-command exit notification before launch, avoiding a separate blocking `waitUntilExit` result path for fast child exits. Output caps, stderr-presence reporting and timeout causes remain distinct; a termination request is not a hard guarantee for an uncooperative child.
- Bounds the caller's wait for individual project-source reads and the number of outstanding workers. Unavailable projects keep their verified cached capabilities and relations while available global/runtime/session data can refresh; late project results cannot become new observations or deletion evidence.

## 1.5.1

Bounded wrapper-attribution repair. Internal build: `35`. Local iteration only; no Tag or GitHub Release is implied.

- Defaults Home, all four capability libraries and all folder tabs to Last 30 days and descending observed call counts. Valid remembered periods and user-selected session sorting remain unchanged; no indexing, schema or source-data change is required.

- Replaces whole-wrapper syntax vetoes with a bounded, nonexecuting structural recognizer for supported eager literal tool calls, including direct calls and supported aggregate wrappers.
- Retains proven earlier reads only across a finite, syntax-validated barrier grammar, including simple unknown calls/awaits and approved output callbacks or loops; an unrecognized suffix is rejected whole even when it might be valid JavaScript. A top-level statement allowlist crosses only static literals, supported literal tool/Promise execution sites and one exact read-only `ALL_TOOLS` metadata filter/map output grammar whose regex subset is limited to literal words, safe separators, grouping, alternation and correctly placed boundary anchors. Unknown evaluation, interpolated or unverified escaped templates, deferred/conditional bodies, delete/update/rebinding of protected runtime names, and unsafe shell mutations stop or reject attribution. Tool-object fields use a finite grammar: a supported dynamic sibling may run or throw before the tool call, so that call is not counted and only earlier proof may survive with unknown results. Malformed or unproved lexical, binding, operator, statement, object-field, delimiter, catalog or regex structure plus input, token or nesting-limit violations reject the whole wrapper; exceeding the 64-call budget retains only the proven bounded prefix with unknown results. Each synchronous extraction uses a local autorelease boundary without extending across async or persistence work.
- Keeps batch, unawaited and limited-wrapper operation results unknown unless a single direct awaited call supplies individual result binding; aggregate completion, failure or interruption is not assigned to every inner operation.
- Advances the parser marker to `1.4.1` and transactionally reparses unchanged `1.4.0` files only inside the recent 30-local-day window. Unchanged older archives remain deferred; schema v6, cache v1, manifest v1, stable resource IDs, folder memberships, evaluations and source files remain intact.
- Replaces definite non-use copy with **No attributed records in 30 days** and clarifies that unsupported or incomplete evidence can omit actual use. Pending, unavailable, positive partial and inferred states remain distinct.

## 1.5.0

Capability usage and unified filters. Internal build: `34`. Local iteration only; no Tag or GitHub Release is implied.

- Shows each capability's observed calls in Agent & Companion Skills, Agent and Skill tabs, including out-of-folder Skill previews without changing membership.
- Adds an independent, remembered Last 7 days / Last 30 days selector shared across windows. Usage ascending/descending and Name A–Z sorting retain the selected period.
- Unifies that period selector, sort vocabulary and 36pt native filter geometry across all four libraries and Capability Folders; preserves scope/plugin filters and custom modification-time sorting. Name/ascending/modified sorting no longer silently changes a thirty-day count to seven days.
- Labels the all-usage-project scope; distinguishes pending statistics from observed zero and keeps partial/inferred evidence qualifications in help, accessibility and details.
- Reuses the existing bounded batch and in-memory projections. Switching period/sort does not index, read account usage or query SQLite; source files, folder members, parser/schema and manifest v1 remain unchanged.

## 1.4.4

Local invocation-observation repair. Internal build: `32`. No Tag or GitHub Release is implied.

- Recognizes actual child-session Agent roles with project-aware identity resolution; keeps delegation requests separate from confirmed child launches.
- Maps project/global Agent configurations and companion Briefs to the existing stable resource identity without changing folder memberships or evaluations.
- Recognizes literal batch tool reads, JSON function arguments and multiple known manifests; uncertain branches, dynamic inputs and mixed mutations remain unattributed.
- Excludes inherited child history and redundant own-Agent reads from usage totals, while retaining fixed evidence provenance. Read/dispatch completion does not prove capability effectiveness.
- Upgrades the derived schema transactionally and reparses recent old-parser sessions once in the background. Unchanged older archives remain deferred; cancellation cannot advance an uncommitted checkpoint.

## 1.4.3

Adaptive menu-bar allowance refresh. Internal build: `31`. No Tag or GitHub Release is implied.

- Uses the exact `com.openai.codex` foreground application identity for a one-minute cadence, a two-minute cadence for ten minutes after confirmed departure, and a five-minute cadence while another application remains active after that grace period.
- Keeps a conservative two-minute fallback when foreground identity is unknown and a thirty-minute cadence after thirty minutes of aggregate input idle time. Foreground status is not treated as evidence of background Codex task activity.
- Keeps foreground state and the last confirmed Codex departure only in memory. No window, task or input-event contents and no application-activity history are read or persisted.
- Preserves pause/disable gates, the two-minute popover freshness rule, reset-aware reads, one shared coordinator, cached values, and stable 5/15/30-minute failure deadlines under repeated system or cache notifications.

## 1.4.2

Local account-refresh patch. Internal build: `30`. No Tag or GitHub Release is implied.

- Refreshes menu-bar account allowance every two minutes during active use without opening the popover; idle account reads remain thirty minutes apart.
- Detects resumed aggregate input activity using the existing single wake-up, without starting Codex, reading SQLite or indexing capabilities during idle checks.
- Restores the two-minute popover freshness threshold and preserves reset deadlines, shared refresh coalescing, pause states, cached values and 5/15/30-minute failure backoff.

## 1.4.1

Source update; this merge does not create a Tag or GitHub Release. Internal build: `29`.

- Added remembered 7- and 30-day Home rankings and 30-day sorting across capability libraries and folder tabs. Both windows use one bounded aggregate and cached projections; switching periods does not trigger indexing, account reads, or a database query.
- Aligned Installed Skills totals, lists, and rankings to independently installed Skills. Plugin counts remain separate, while observed plugin-provided Skills remain source-labeled in folders.
- Moved installed-plugin inventory to the local Codex app-server's `plugin/installed` report. Partial or local-only results remain unverified rather than becoming zero, and distinct marketplaces retain distinct identities.
- Completed offline Chinese purpose descriptions for the current Agent/Skill inventory and improved Markdown purpose parsing without indexing body instructions.
- Improved library navigation and rendering responsiveness, folder-entry search, control hit areas, and synthetic interaction-performance validation.
- Preserved prior source-data, folder membership, quota-history, presentation-cache schema v1, and capability-package manifest v1 boundaries.

## 1.4.0

Source update only; no Tag or GitHub Release was created by this merge. Internal build: `28`.

- Recognizes ChatGPT's embedded CodexCLI application bundle even without a shell PATH, restoring the runtime discovery entry point used by live quota reads.
- Preserves legacy application paths, explicit user-selected runtime priority, source-data boundaries, and saved folder memberships.
- Adds regression coverage for missing legacy locations and runtime-selection priority.

## 1.3.1

Local presentation patch; this entry does not imply a published Tag or GitHub Release.

- Aligned Capability Folders section headings, actions, grids and lists to the same page gutters; added explicit vertical rhythm between the header, tabs, search and content.
- Unified folder tabs, capability-import filters and Settings theme choices with real native segmented brand-outline controls rather than system-blue fills.
- Matched folder search/sort painted heights and outlined icon-menu targets while preserving search, tab state, sorting, details and membership controls.
- Preserved all saved folder memberships, capability relationships, source files, cache/index behavior and package manifest v1.

## 1.3.0

Source integration only; a version entry does not imply a published Tag or GitHub Release.

- Added a Capability Folders destination with Global and Project folders, plus an empty Self Training folder that preserves user-selected memberships across refreshes and upgrades.
- Added custom folder create, rename, delete, reorder, multi-membership, atomic existing-capability import, global search, folder search, project Agent/Skill tabs, and recent/name sorting. Folder preferences contain only stable IDs and names; no paths or capability content.
- Removed the unpublished automatic category classifier and eight preset categories. Plugin-provided Skills are visible in Global; system capabilities, plugin packages, instructions, MCP/tools, and stale plugin caches remain excluded.
- Added explicit Agent/Skill companion relationships from registry declarations, Agent TOML/Brief instructions, and Skill descriptions. Negative or ambiguous references fail closed; related previews never become members automatically.
- Separated declarations from batched seven-day shared-session evidence and added bidirectional detail navigation. Shared Skills retain one resource identity.
- Refined the folder interface with responsive 4/3/2/1 grids, three internal tabs, compact outlined relationship groups, current-value sort menus, and a trailing detail sidebar. Preserved existing Self Training and other folder memberships; fresh installs still start with an empty Self Training folder.
- Fixed native search layout re-entry during clear-search and tab changes by instantiating only one search editor for each responsive layout.
- Fixed the presentation clock monitor ignoring a shorter configured polling interval when a source refresh was already running. Normal automatic refresh cadence is unchanged.
- Fixed replayed snapshots from an earlier weekly reset cycle being counted as new consumption. A regression sequence that previously produced 224% now produces 62%; genuine forward reset-cycle consumption is not artificially capped.
- Updated bilingual product documentation, synthetic Capability Folders screenshots, local UI contracts, and regression tests. Capability package manifest v1 and the rollout parser version are unchanged.

## 1.2.0

- Added local restoration of trusted `.codexpack.zip` packages through a staged verify, project mapping, preflight, and final confirmation flow.
- Existing files are never overwritten or merged. Identical entries are skipped; conflicting capabilities can be excluded while the package remains available for review.
- Restore writes are anchored to approved directory descriptors, reject symlink ancestry and target races, journal every type before exclusive atomic publication, and preserve executable bits plus descriptor-verified relative symlinks.
- Failed/cancelled restore and one-session undo never delete restored objects. Every approved root receives a private mode-0700 quarantine before writes; verified unchanged objects move there and remain available through an in-memory Finder reveal action, while replaced, moved, or user-modified objects stay in place and are reported. Sheet-close discard keeps the shared migration lock until active cleanup finishes.
- Conflict review shows capped redacted text differences and metadata-only binary details. Plugins and external requirements are concrete read-only checklists; restore never executes content, installs dependencies/plugins, modifies Codex configuration, or uses the network.
- Added bilingual restore UI, privacy copy, manifest v1 round-trip tests, and a shared export/restore migration lock.

## 1.1.1

- Synchronized Home's current five-hour and weekly allowance rings with the sanitized live account reading used by the menu bar.
- Kept the seven-day weekly chart on indexed same-source history and left presentation-cache schema v1 unchanged.
- Added account usage to the main Refresh data action while the menu-bar account feature is enabled; an explicit opt-out still starts no Codex account process.
- Updated the Home timestamp to reflect a newer account-only refresh and added regression coverage for source isolation, missing windows, and stale-cache ordering.

## 1.1.0

- Added same-source five-hour allowance projection alongside the existing weekly allowance, without a database migration.
- Home now presents valid five-hour and weekly windows as concentric rings; expired or unavailable windows are hidden independently and the weekly daily chart remains weekly-only.
- Menu-bar status now formats dual windows as `5h 82% w 57%`, or a single bare percentage when only one window is available. The popover lists each available reset independently.
- Updated the local app-server reader, presentation cache compatibility, reset scheduling, bilingual copy, and synthetic coverage for both windows.

## 1.0.0

- Prepared the first public open-source release with a clean 1.0.0 application identity.
- Unified Settings action sizing across localized labels and kept capability project-group boundaries 20pt apart.
- Unified the three Settings actions on a shared 176pt content width and 48pt outer height; the internal build was 21 while the visible version was 1.0.0.
- Removed the trailing ellipsis from the capability-package export action for a stable compact control label.

## 0.6.2

- Added an app-scoped adaptive account-usage schedule for the enabled menu bar.
- Active sessions refresh every five minutes; aggregate idle sessions use a 30-minute cadence, with 5/15/30-minute failure backoff.
- The schedule pauses for lock, sleep and Low Power Mode, and never starts capability indexing or a second database reader.
- Popover reads now refresh missing, expired or older-than-two-minute account data through the shared coordinator.

## 0.6.1

- Fixed live menu-bar insertion and removal by binding `MenuBarExtra` to the shared app-scoped preference store across windows.
- Menu-bar visibility now defaults to enabled for new installs while an explicit user opt-out remains persisted across launches.

## 0.6.0

- Added an opt-in native macOS menu-bar quota summary with weekly remaining allowance, next reset time, reset-card count, data refresh, and a main-window shortcut.
- Reads account allowance through the local Codex app-server only when requested; no account identifiers, credentials, model buckets, or source details are retained or displayed.
- Added a backward-compatible optional account-usage field to the presentation cache and kept menu-bar refreshes on the shared refresh coordinator.

## 0.3.1

- Added application-owned Light and Dark themes.
- Replaced icon-only refresh controls with shared text and loading states.
- Preserved portable capability package manifest v1.

Earlier private development history is retained outside the public repository and is not part of the public changelog.
