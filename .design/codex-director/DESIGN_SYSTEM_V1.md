# Codex Director Design System v1

Version: `0.3.1-annotated-ui-polish`  
Target: native macOS application, minimum macOS 26.0, Xcode 26 SDK  
Status: approved capability-centered structure, nonblocking startup and shared Scheme A visual contract; implementation acceptance pending  
Last updated: 2026-09-05

## 1. Purpose

Codex Director is a private, local operational application for understanding available AI capabilities and observing how they are used. Its interface must make dense evidence legible without turning the product into a generic admin dashboard or a decorative AI control room.

The 0.2 product goal is personal Agent/Skill inventory and usage feedback: understand what has been developed or installed, what each capability is declared to do, where it was used, and what warrants human validation or improvement. File existence, invocation frequency and execution completion are not effectiveness. The approved contract is [the 0.2 implementation plan](../../docs/plans/2026-08-28-capability-centered-redesign.md). Its six-page structure supersedes all earlier product navigation; privacy and source protection remain unchanged.

The product adopts Apple's Liquid Glass design language as expressed on macOS. It does not copy iPhone navigation, touch layouts, or ornamental glass treatments. Native macOS structure, pointer behavior, keyboard access, resizable windows, menu-bar integration, and user control take precedence.

Codex Director v1 supports macOS 26.0 and later only. It does not ship an earlier-macOS UI fallback. Use macOS 26 availability as a deployment-target guarantee rather than scattering `#available` branches through the app. If support for an earlier system is proposed later, treat it as an architecture and design-system change requiring explicit approval, a fallback material specification, and an expanded validation matrix.

## 2. Sources and precedence

| Priority | Source | Governs |
| --- | --- | --- |
| 1 | Project and system safety instructions | Privacy, write boundaries, source-data protection |
| 2 | Current Apple HIG and framework documentation | macOS behavior, standard components, API correctness |
| 3 | This document | Product identity, tokens, semantics, component contracts |
| 4 | `director-visual-system` | Design and review workflow |
| 5 | Third-party references | Background comparison only |

Primary Apple references:

- [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines)
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Liquid Glass overview](https://developer.apple.com/documentation/technologyoverviews/liquid-glass)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/)
- [Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)

Official-source review record: reviewed 2026-08-15 for a macOS 26.0 deployment target and Xcode 26 SDK. Recheck the relevant official page before implementing an API whose signature or behavior may have changed.

Reviewed but not installed references:

- `ehmo/platform-design-skills@macos-design-guidelines`
- `Dimillian/Skills@swiftui-liquid-glass`
- `affaan-m/ECC@liquid-glass-design`

Do not automatically track the `main` branch of a third-party repository. Any future adoption requires a pinned commit, license record, manual diff, and a new approval.

## 3. Design principles

### 3.1 Evidence before spectacle

Emphasize the resource, call, sequence, status, and confidence being examined. Animation and depth must clarify causality, selection, or hierarchy.

### 3.2 Native structure, distinctive data language

Use native macOS windows, menus, sidebars, toolbars, tables, focus, and shortcuts. Express Codex Director's identity through legible capability inventories, honest quota observations, traceable invocation evidence and lightweight human evaluation.

### 3.3 Content and controls are separate layers

Keep data and visualization in the content layer. Use Liquid Glass for the functional layer: navigation, top-level controls, transient overlays, and system-provided surfaces.

### 3.4 Confidence is visible

Never present inferred Skill or Workflow activity as exact telemetry. Encode `exact`, `inferred`, and `unknown` consistently in topology, timeline, details, audits, and exports.

### 3.5 Calm by default, expressive on focus

The default workspace is quiet and dense. Strong color, glow, and path animation appear only for the current selection, a state transition, a failure, or a user-requested playback.

### 3.6 Privacy is a visual requirement

Compact and ambient surfaces must not expose prompts, tool arguments, tokens, raw paths, or personal data. Redaction is part of the component contract, not an optional data-layer feature.

## 4. Product surfaces — 0.2 approved replacement

| Primary destination | User question | Required structure |
| --- | --- | --- |
| 首页 / Home | How much quota remains, how many capabilities, what was used? | Three Card Atlas outline modules: quota ring + annotated daily bars; continuous four-metric strip; three-column Top10 comparison ledger |
| 自定义 Agent / Custom Agents | What Agents have I developed and used? | Category totals; visible scope/search/sort; purpose-first list; invocation detail |
| 自定义 Skill / Custom Skills | What Skills have I developed and used? | Same shared browsing contract |
| 安装 Skill / Installed Skills | What installed Skills do I use? | Independent and current plugin-provided Skills, explicit source |
| 安装插件 / Installed Plugins | Which installed packages are enabled and observed? | Current package inventory, incl disabled; attribution limitations visible |
| 设置 / Settings | Is my data current and private? | Language and app appearance, indexing/status/diagnostics, capability migration, confirmed derived-data deletion, privacy, author and version |

There are exactly six primary destinations. Old Capabilities, Tasks, Review, Usage and Data Status entries are removed. Related calls and findings remain detail content; indexing and diagnostics move into Settings. Topology, workflow, menu-bar and desktop-pet contracts below are dormant platform guidance, not 0.2 scope or new navigation obligations.

Home contains exactly three Card Atlas modules. Their outer boundaries are one restrained outline grammar, while their internals remain distinct: quota ring/reset/chart, continuous metrics with responsive internal rules, and a top-aligned ranking ledger. The quota ring and daily bars share a single visibly selected source. Bars show the weekly allowance percentage observed as used on each local calendar day, derived from reset-aware increases between consecutive same-source account reports and never from Tokens, calls, or cost. Gaps and ambiguous transitions remain unavailable rather than zero; the current reset timestamp sits directly below the ring, while the daily chart does not add ambiguous reset labels. Inventory excludes project counts/instructions. Rankings contain only observed calls and explain that frequency is not effectiveness in their detailed context rather than a module subtitle.

Capability ownership and usage project are different dimensions. Default list scope is all capabilities; groups put global configuration first, then localized project name and stable ID. Project configuration overview includes unused project resources; selecting “Project · Usage” includes all current capabilities actually used there, including global ones, and still groups by the capability's own configuration owner. Category totals do not respond to search. The seven-day period is today plus six preceding local calendar days, and the thirty-day inactive period is today plus 29 preceding local calendar days, both independent of UI language.

## 5. Layout grammar

### 5.1 Main window

Use a native resizable window with these regions:

1. **Sidebar**: the six approved primary destinations.
2. **Workspace**: overview modules or capability inventory.
3. **Inspector**: capability purpose, usage, calls and evaluations; staged into the same area at narrow widths.
4. **Controls**: visible scope, search, sort and relevant view actions.

Minimum functional behavior:

- Support window resizing without truncating primary actions.
- Preserve the selected destination, filters, and inspector state where appropriate.
- Allow sidebar and inspector collapse.
- Use menus and keyboard commands for stable, discoverable actions.
- Avoid nested card grids as the default information architecture.

Approved geometry: default window 1280×800; minimum 720×480. Measure actual workspace content, not screen/window width. Quota charts stack below 760 pt; rankings stack below 1000 pt; list and detail are parallel only at 1000 pt or more. Below that, use a same-area detail with text “返回列表 / Back to list” and Escape. Compact rows preserve name, purpose and seven-day count; numeric values never wrap. Other metadata moves to secondary lines/detail.

Every single-choice control must show its selected value when closed. Use labels such as “查看：全局配置” and “排序：近7天调用 ↓”, or their English equivalents. At constrained widths wrap the control group; never replace its selected value with an icon. This also applies to quota source, language and detail classification.

### 5.2 Density

Use three named density modes only when evidence shows the need:

- `comfortable`: onboarding, empty states, overview.
- `standard`: default operational workspace.
- `compact`: expert tables and timelines.

Do not reduce target sizes or text legibility merely to display more rows.

## 6. Semantic color system

Use dynamic system colors for native UI. Fixed RGB or hex values require an explicit visualization need, Light/Dark variants, contrast verification, and an added semantic token.

### 6.1 Foundation tokens

| Token | SwiftUI binding | AppKit binding |
| --- | --- | --- |
| `surface.window` | `Color(nsColor: .windowBackgroundColor)` | `NSColor.windowBackgroundColor` |
| `surface.content` | `Color(nsColor: .textBackgroundColor)` | `NSColor.textBackgroundColor` |
| `surface.raised` | `Color(nsColor: .controlBackgroundColor)` | `NSColor.controlBackgroundColor` |
| `surface.selection` | `Color(nsColor: .selectedContentBackgroundColor)` | `NSColor.selectedContentBackgroundColor` |
| `text.primary` | `Color(nsColor: .labelColor)` | `NSColor.labelColor` |
| `text.secondary` | `Color(nsColor: .secondaryLabelColor)` | `NSColor.secondaryLabelColor` |
| `text.tertiary` | `Color(nsColor: .tertiaryLabelColor)` | `NSColor.tertiaryLabelColor` |
| `stroke.separator` | `Color(nsColor: .separatorColor)` | `NSColor.separatorColor` |
| `stroke.focus` | `Color(nsColor: .keyboardFocusIndicatorColor)` | `NSColor.keyboardFocusIndicatorColor` |
| `accent.primary` | `Color.accentColor` | `NSColor.controlAccentColor` |

### 6.2 Runtime status tokens

| Token | SwiftUI binding | AppKit binding | Redundant signal |
| --- | --- | --- | --- |
| `status.idle` | `Color(nsColor: .systemGray)` | `NSColor.systemGray` | Pause symbol or `Idle` label |
| `status.running` | `Color(nsColor: .systemBlue)` | `NSColor.systemBlue` | Activity symbol and optional pulse |
| `status.success` | `Color(nsColor: .systemGreen)` | `NSColor.systemGreen` | Checkmark |
| `status.warning` | `Color(nsColor: .systemOrange)` | `NSColor.systemOrange` | Warning triangle |
| `status.failure` | `Color(nsColor: .systemRed)` | `NSColor.systemRed` | Error symbol |
| `status.blocked` | `Color(nsColor: .systemPurple)` | `NSColor.systemPurple` | Stop/approval symbol |
| `status.unknown` | `Color(nsColor: .secondaryLabelColor)` | `NSColor.secondaryLabelColor` | Question mark and `Unknown` label |

### 6.3 Resource-type tokens

| Resource | SwiftUI/AppKit system color | SF Symbol |
| --- | --- | --- |
| Agent | `systemIndigo` | `person.crop.circle` |
| Skill | `systemBlue` | `sparkles` |
| Project instruction | `systemGray` | `doc.badge.gearshape` |
| Workflow | `systemTeal` | `arrow.triangle.branch` |
| Tool | `systemCyan` | `wrench.and.screwdriver` |
| Plugin | `systemPurple` | `puzzlepiece.extension` |
| MCP | `systemMint` | `link` |
| App | `systemPink` | `macwindow` |
| Hook | `systemOrange` | `bolt` |
| Output | `systemGreen` | `doc.text` |
| Unknown | `systemGray` | `questionmark.circle` |

Resource type and runtime status are separate channels. A Skill node that failed remains a Skill-colored node with a failure badge; it does not become a red resource.

Project instructions (`AGENTS.md`) are a distinct resource type and are never
counted as Agents. They use the system-gray token and `doc.badge.gearshape` in
technical details. They do not appear in Home inventory totals or a project breakdown. The symbol is paired with
the `Instruction` label for contrast, keyboard, and VoiceOver variants.

Bind a resource color in SwiftUI with `Color(nsColor: .systemBlue)`-style construction and in AppKit with the corresponding `NSColor.systemBlue`-style value. Validate every symbol with `NSImage(systemSymbolName:accessibilityDescription:)`; if a symbol is unavailable in the target SDK, fail the symbol-contract test and approve a replacement rather than silently substituting one.

### 6.4 Confidence tokens

| Confidence | Line/shape | Opacity intent | Label |
| --- | --- | --- | --- |
| `exact` | Solid | Full | `Exact` |
| `inferred` | Dashed | Emphasized but subordinate | `Inferred` |
| `unknown` | Dotted | De-emphasized | `Unknown` |

Never rely on opacity alone. Preserve these labels in details, tooltips, VoiceOver, and exports.

### 6.5 Canvas and accessibility binding

- In SwiftUI `Canvas`, resolve the same `Color` token used by native components; do not create a parallel canvas palette.
- For WKWebView/WebGL, resolve dynamic `NSColor` values under the window's current effective appearance, convert them to sRGB at runtime, and expose them through a native-to-web token bridge such as `--director-status-running`. Refresh the bridge when effective appearance or accessibility display options change.
- Observe SwiftUI `colorScheme`, `colorSchemeContrast`, `accessibilityReduceTransparency`, and `accessibilityReduceMotion` environments.
- Observe AppKit accessibility display changes through `NSWorkspace` and its accessibility display options notification/properties.
- Under Increase Contrast, strengthen boundaries and selected/focused treatments without changing semantic meaning.
- Under Reduce Transparency, replace custom glass with an opaque `surface.raised` or platform-provided legible fallback.
- Under Reduce Motion, preserve final states and labels while removing path travel, morphing, and pet locomotion.

## 7. Typography

Use San Francisco through SwiftUI/AppKit semantic styles. Do not bundle a custom interface font in v1.

| Role | Semantic style | Use |
| --- | --- | --- |
| `type.windowTitle` | Title/large title appropriate to context | Primary page or major empty-state title |
| `type.sectionTitle` | Headline | Inspector and content sections |
| `type.body` | Body | Primary readable text |
| `type.supporting` | Callout | Metadata and supporting explanation |
| `type.label` | Caption | Badges, timestamps, evidence labels |
| `type.data` | Monospaced digits | Counts, duration, token and timing values |
| `type.code` | System monospaced | Parser types, tool identifiers, redacted paths |

Text rules:

- Prefer sentence case.
- Keep labels stable across menu, toolbar, context menu, and inspector.
- Truncate only after preserving the identifying portion; provide a tooltip or inspector value.
- Use monospaced text for identifiers, not for general body copy.

## 8. Spacing and shape

### 8.1 Spacing scale

| Token | Value | Typical use |
| --- | ---: | --- |
| `space.1` | 4 pt | Icon-label micro gap |
| `space.2` | 8 pt | Compact component padding |
| `space.3` | 12 pt | Row and control grouping |
| `space.4` | 16 pt | Standard panel padding |
| `space.5` | 20 pt | Section separation |
| `space.6` | 24 pt | Large component grouping |
| `space.8` | 32 pt | Major content separation |
| `space.10` | 40 pt | Empty-state or overview spacing |

Use system component metrics when they differ. The scale governs custom surfaces and visualization overlays, not replacement geometry for native controls.

### 8.2 Shape tokens

| Token | Value/behavior | Use |
| --- | --- | --- |
| `radius.compact` | 6 pt | Tiny custom badges only |
| `radius.control` | 8 pt | Custom non-glass controls |
| `radius.panel` | 12 pt | Custom raised content surfaces |
| `radius.floating` | 16 pt | Floating visualization controls |
| `radius.capsule` | System capsule | Status pills and suitable top-level controls |

Let native Liquid Glass and system controls determine their own shapes. Do not wrap every component in another rounded container.

## 9. Material and elevation

### 9.1 Liquid Glass allowed

- System toolbar and top-level navigation treatment.
- Menu-bar popover or system-provided compact window.
- Inspector or transient controls that float above content when the platform supplies the treatment.
- A small group of top-level custom controls where native APIs are insufficient.
- Temporary playback or zoom controls over a topology canvas.

### 9.2 Liquid Glass forbidden by default

- Repeated resource cards.
- Table rows and timeline events.
- Every topology node.
- Main content backgrounds.
- Decorative panels with no control or navigation role.
- Nested glass-on-glass surfaces.

Use the regular variant by default. Consider a clear variant only above visually rich media where readability has been verified; Codex Director v1 has no default clear-glass use case.

### 9.3 Elevation

Use separation in this order:

1. Layout and spacing.
2. System separators or selection.
3. Material distinction.
4. Shadow only for a truly floating element.

Avoid ornamental shadows on tables, nodes, and content panels.

## 10. Motion system

| Token | Intent | Provisional duration |
| --- | --- | ---: |
| `motion.instant` | Hover and tiny feedback | 120 ms |
| `motion.standard` | Selection and disclosure | 200 ms |
| `motion.emphasized` | Inspector or overlay transition | 320 ms |
| `motion.narrative` | User-requested invocation playback | 480 ms per meaningful step, adjustable |

Use platform springs for spatial changes when they preserve continuity. Do not loop glow, shimmer, or particle effects in the main workspace.

Under Reduce Motion:

- Replace movement and morphing with short opacity transitions or immediate state change.
- Stop path-travel animations.
- Keep progress and state understandable through static symbols and labels.
- Allow the desktop pet to become static or fully hidden.

## 11. Component contracts

### 11.1 Sidebar destination

- Use a stable SF Symbol, label, selection state, and optional evidence-backed badge.
- Do not use resource-type colors as full-row backgrounds.
- The active destination uses the shared blue → ice → mint brand gradient with a black label and a named high-contrast deep-gray symbol. Suppress the native blue visual tint so it cannot appear behind the custom gradient; the native List remains the selection and keyboard source of truth.
- Keep the six approved destinations in the specified order. Configuration scope and usage project live inside the relevant page, not as additional navigation destinations.

### 11.2 Toolbar

- Place only frequent, context-relevant actions in the toolbar.
- Keep the manual data update in the window's trailing primary-action position so it remains available on all six destinations. It is a compact gradient text button that always shows a refresh symbol plus “Refresh data” when idle, and a native indeterminate progress ring plus “Refreshing…” while source or projection work is active. Its two labels share one layout footprint, so state changes do not shift the toolbar. Never collapse it to an icon at narrow widths. Hide the macOS shared toolbar glass background for this already-filled control and omit its toolbar-size shadow so the button has exactly one visible container.
- Supply menu equivalents and keyboard shortcuts where appropriate.
- Group related controls and avoid a row of unrelated glass capsules.
- Search, sort and scope controls retain stable locations and visible current values.

### 11.3 Inspector

- Present name/purpose/ownership or source; recent-seven-day summary and usage projects; paginated calls with time/project/execution result/evidence and human evaluation.
- Evaluation supports effective/ineffective/uncertain, edit and clear. A successful execution never preselects “effective”.
- Missing declared purpose or modification time is shown as missing, not inferred from the name.
- Keep technical metadata, classification correction and related findings in disclosures.
- Keep raw commands, paths, and arguments redacted by default.
- Use disclosure for advanced parser/debug details.

### 11.3a Quota and ranking charts

- Use Swift Charts with native dynamic colors. Content charts are not glass panels.
- Quota: used/remaining donut, textual remaining percentage and reset time below the centered ring. The quota-column heading aligns to the leading content edge; the ring and reset group remain centered. The ring diameter is 216pt with a 20pt ring-to-reset gap. Recorded time and an extra evidence heading are omitted. If the active observation expired, show “waiting for a new quota record”, not a newly full allowance. Multiple sources use an outlined segmented switch whose selected border uses the shared brand gradient; no system-blue selected fill is allowed.
- Daily weekly-quota usage bars: seven local calendar dates, each containing the reset-aware percentage-point increase observed from consecutive same-source weekly allowance reports. Retain use observed before and after a reported reset within one day. A day without an observation, an adjacent-day baseline, or sufficient reset evidence is unavailable rather than zero; only a confirmed flat sequence displays 0%. The current day ends at its latest report. Use the shared vertical brand gradient, a data-dependent percentage axis with annotation headroom, horizontal grid lines only, and centered date/bar columns whose labels and marks share the exact categorical center. Do not add ambiguous per-day reset text.
- Rankings: current category resources with positive recent-seven-day calls only, descending count, up to ten, proportional bars and explicit inferred labels.
- Provide accessible labels and textual counts/time/missing states without hover. Do not use decorative symbols as extra AX content.
- Distinguish loading, unindexed, no inventory, filter empty, not observed, attribution unavailable and update failure.

### 11.3c Shared visual language — approved 0.3.1

The [Home refresh contract](../../docs/plans/2026-08-28-home-visual-refresh.md) established the canvas, panel, inset, boundary and emphasis values. This release promotes those values and their spacing, radius, typography and symbol companions into shared Director tokens consumed by Home and all four capability pages. Other navigation, status and resource semantics remain unchanged.

| Shared token | Light | Dark |
| --- | --- | --- |
| canvas | `#F3F6F8` | `#090F13` |
| panel | `#FFFFFF` | `#111A20` |
| inset/hover | `#EAF1F5` | `#15222B` |
| boundary | `#CAD7DF` | `#344650` |
| emphasis | `#006B83` | `#5FD7EE` |

Use dynamic Light/Dark bindings, existing label colors and stronger boundaries/muted text under Increase Contrast. The app owns a persisted Light/Dark preference, defaults to Dark when missing or invalid, applies it to every app window and SwiftUI sheet, and never changes the macOS global appearance preference. Settings exposes the two choices as a permanently visible segmented control; there is no “Follow System” option. Home and capability pages are opaque and static under Reduce Transparency/Motion. No content glass or ornamental shadows.

All gradient primary actions use pure black foreground content. The blue → ice → mint endpoints provide at least `4.5:1` contrast against black in both supported themes; the lowest approved endpoint is light blue `#0879D9` at approximately `4.75:1`. `DirectorPrimaryActionButtonStyle` provides standard, 28pt toolbar and equal-width Settings action sizes while preserving native focus, hover, pressed, disabled and Increase Contrast behavior.

Home uses Card Atlas's three unnumbered `.title2` modules, 32pt inter-module spacing, a tighter 16pt hero-to-first-module gap, 40/16pt page gutters and a 1440pt maximum content width. The compact hero reads “Welcome to Codex Director”, has no decorative illustration or inline refresh action, and leaves refresh to the global toolbar. The quota stage stacks below 760pt; the metric strip is four columns at 760pt and above, two columns from 420–759pt and one below 420pt; rankings use three top-aligned columns at 1000pt and above and stack below. Draw each day's observed weekly-quota use above gradient bars, retain seven dates and evidence gaps, scale the percentage axis to the largest available daily value, and remove per-day reset text, vertical grid lines, the visible daily table and duplicate remaining value. The quota ring uses a 20pt stroke and one Reduce Motion-aware entrance reveal. Inventory SF Symbols match navigation and are decorative AX-hidden. Home numeric roles (`homeMetric`, `homePercentage`, `homeTimestamp`, `homeRank`, `homeRankCount`) use Avenir Next with tabular digits only for numeric values; interface labels and prose retain the system font. All four capability pages use `DirectorEditorialFrame`, `DirectorEditorialHero`, `DirectorMetricSequence`, `DirectorMetricCard`, `DirectorFilterRibbon`, project-group outline boundaries and a transient `DirectorSideSheet`; page content is capped at 1440pt with 40/16pt outer padding. Capability metrics remain four columns at 760pt and above, two columns from 420–759pt, and one below 420pt; their final outer heights are 96pt desktop and 88pt compact, with visible hover and selected treatments but no decorative selected underline. The entire capability page is one native `List(selection:)` scroll container, so the header, metrics, filter rail, status and ledger move together. The filter rail owns the single flexible search field plus narrower visible scope, sort and plugin-status controls where applicable; it does not repeat a result count. Menus place one disclosure chevron on the right. Global group is first, followed by stable localized project groups, with rounded outer boundaries, 16pt internal row padding and a separator between every item. Capability row titles use the named 16pt semibold and 14pt regular summary roles; call counts use named 16pt/13pt roles. Category symbols are `person.crop.circle`, `sparkles`, `shippingbox` and `puzzlepiece.extension`; metric symbols are `globe`, `folder`, `clock.arrow.circlepath`, `calendar.badge.exclamationmark`, `checkmark.circle` and `tray.full`. Symbols are decorative and AX-hidden when adjacent text carries the meaning.

Home is also the shared primary-page chrome reference. Home, all four capability libraries and Settings use 40pt horizontal gutters at 760pt and wider, 16pt below 760pt, 24pt vertical gutters and a centered 1440pt maximum content measure. Each native `ScrollView` or `List` spans the full workspace; gutters are applied to scroll content so the vertical scroll indicator remains on the same far-right workspace edge on every page. Primary page titles use the rounded semibold system face at 52pt standard and 36pt compact. Title text remains the solid primary color except for the `Codex Director` product-name fragment in Home's welcome title, which uses the shared blue → ice → mint brand gradient. Capability and Settings decorative title symbols use the shared 24pt semibold `pageHeroSymbol` token and remain AX-hidden. Home keeps no title symbol under its approved illustration-free hero contract. The window toolbar product name retains the native primary-title treatment.

### 11.3b Cached content and background refresh — 0.2.1

The approved [startup repair plan](../../docs/plans/2026-08-28-startup-performance.md) adds these states without changing layout, theme, navigation or material tokens:

- The native window, navigation and settings remain interactive while services, caches or statistics load. Never gate the whole workspace behind a spinner.
- Display a previous valid snapshot during a background update or failure. Use supporting/label text for updating, stale and retry status; keep content readable and selections intact.
- A missing computation uses an explicit pending state and an em dash, not zero or “no calls”. Successful zero, absent source evidence and unsupported attribution remain distinct.
- Separate source record time, statistics cutoff, last successful source check and completed indexing time. A new check with no records must not relabel an old record as fresh.
- Thirty-minute cache freshness does not extend an expired quota cycle. At the reported reset instant, show waiting for a new record, with historical charts retained and no invented 100% balance.
- A manual update is always available as the trailing toolbar action, with localized visible text, accessibility label and help text, and uses the same shared control in Settings. Source and projection phases show the native progress ring and “Refreshing…”; startup grace, waiting, idle and failed phases do not. The control rejects repeated activation while running without losing its primary visual emphasis. Localized status/value labels remain available to accessibility without duplicate container announcements.
- Use the same dynamic colors, native controls and spacing in Light/Dark, minimum/default/wide windows, Reduce Motion, Increase Contrast and Reduce Transparency. No new decorative loading animation or glass content panels.
- State correctness requires cold/warm-cache, delayed, cancelled, failed and large-data tests. A screenshot of six navigation entries is not startup-performance evidence.

### 11.4 Status badge

- Combine status symbol, short label, and semantic color.
- Use a capsule only for compact status, not for ordinary metadata.
- Keep `Inferred` and `Unknown` visible rather than hiding them in a tooltip.

### 11.5 Topology node

- Encode resource type in the node identity treatment.
- Encode runtime status as a badge or ring.
- Encode confidence in the relation edge, not by recoloring the node.
- Show name, type, availability, and selected/focused state at useful zoom levels.
- Aggregate or collapse by default; never open the entire global graph at launch.

### 11.6 Topology edge

- Use direction only where causality or invocation order is known.
- Use solid/dashed/dotted patterns for exact/inferred/unknown evidence.
- Highlight only the selected path or active playback segment.
- Provide an accessible relation description outside the canvas.

### 11.7 Timeline event

- Show timestamp/order, actor/tool, event type, status, duration when known, and confidence when inferred.
- Preserve parent/child nesting without relying only on indentation color.
- Keep raw payloads collapsed and redacted.

### 11.8 Menu-bar status

- Default to a single template-style symbol plus an optional short state indicator.
- Never display prompt text, task titles, file paths, or tool arguments by default.
- Use a privacy-safe popover for current state, elapsed time, pending approval, last outcome, and Open Director.
- Allow the user to hide the menu item and disable launch at login.

### 11.9 Desktop pet

- Treat the pet as an optional redundant status avatar, never as the only way to learn system state.
- Provide visible, interactive, click-through, paused, and hidden modes.
- Do not steal keyboard focus or cover primary controls.
- Pause animation when hidden, screen-locked, inactive by user preference, or under an applicable energy-saving mode.
- Map behaviors to status tokens rather than inventing a separate emotional truth model.

### 11.10 Desktop-pet state grammar

| Runtime state | Visual/action behavior | Duration/loop rule | Redundant non-pet signal |
| --- | --- | --- | --- |
| Idle | Neutral breathing or resting pose | Slow, low-energy loop; static under Reduce Motion | Gray menu-bar state and `Idle` label |
| Indexing | Brief organizing/searching gesture | Loop only while indexing; no file names shown | Blue activity symbol and indexing label |
| Running | Attentive working pose | Subtle loop while active | Blue running state and elapsed time |
| Tool call | One short task gesture | Play once per visible state change; never reveal arguments | Tool symbol in popover/timeline |
| Waiting approval | Still pose with attention marker | No repeated bouncing or flashing | Purple approval symbol and `Approval needed` label |
| Success | Short acknowledgement | Play once, then return to idle | Green checkmark and last-outcome label |
| Warning | Cautious pose | Play once; no continuous alert loop | Orange warning symbol and label |
| Failure | Short stop/recovery pose | Play once; remain calm | Red error symbol and failure label |
| Blocked | Paused pose with stop marker | Static until state changes | Purple blocked symbol and label |
| Unknown/offline | Neutral question or disconnected marker | Static | Gray question symbol and `Unknown`/`Offline` label |

Do not derive a personality judgment from conversation text. The pet represents runtime state only.

## 12. Interaction and state requirements

Every interactive component must define applicable states:

- Default
- Hover
- Pressed
- Selected
- Keyboard focused
- Disabled
- Loading
- Empty
- Error
- Privacy-redacted

Use native pointer and focus behavior first. Keep destructive actions reversible or confirmed in proportion to risk. Preserve Escape, Return, arrow-key, Tab, and standard Command-key behavior where the control semantics support them.

## 13. Accessibility

Required variants:

- Light appearance
- Dark appearance
- Increase Contrast
- Reduce Transparency
- Reduce Motion
- Keyboard-only navigation
- VoiceOver labels and ordering
- Resizable window and text without clipped primary content

For custom canvases, expose a synchronized accessible list or inspector representation. Canvas-only labels do not satisfy the accessibility contract.

## 14. Privacy presentation rules

Safe by default:

- Resource type and redacted display name.
- Running/idle/success/failure/blocked state.
- Aggregate counts.
- Duration and recency.
- Evidence confidence.

Hidden or redacted by default:

- Prompt and response text.
- Tool arguments and full output.
- Tokens, keys, cookies, and credentials.
- Raw shell commands.
- Usernames and unredacted absolute paths.
- Personal or customer data.

Fixtures, previews, documentation screenshots, and visual tests must use synthetic data.

## 15. Implementation contract

When an Xcode project exists, establish typed namespaces rather than scattered constants:

- `DirectorColor`
- `DirectorSpacing`
- `DirectorRadius`
- `DirectorMotion`
- `DirectorTypography`
- `DirectorSymbol`
- `DirectorStatusStyle`
- `DirectorResourceStyle`
- `DirectorConfidenceStyle`

Create reusable components only after at least two concrete consumers or when a platform contract requires centralized behavior. Prefer native components with modifiers over wrappers that hide system behavior.

## 16. Versioning and change control

A design-system change must record:

1. The user or product problem.
2. The affected token or component contract.
3. Light/Dark and accessibility behavior.
4. Migration impact on existing components.
5. Preview or screenshot evidence.
6. Whether the change modifies a v1 rule or adds a new rule.

Do not change the system merely to match a single mockup. Promote a pattern only after it proves reusable or represents a required platform/product invariant.

## 17. Scheme A migration — 0.2.5

Scheme A promotes the canvas, opaque panel, inset, boundary and emphasis
language that was first validated on Home into shared `DirectorColor`,
`DirectorSpacing`, `DirectorRadius`, `DirectorTypography` and
`DirectorSymbol` tokens. The fixed accent values are declared only in the
central color namespace: dark blue `#159DFF`, ice `#49CAFF`, mint `#79EAD8`
and readable data teal `#5FD7EE`; light blue `#0879D9`, ice `#118EAE` and mint
`#148F7E` (deeper teal remains confined to ambient environment tokens). Views consume
these values through the typed `DirectorAccentTone` vocabulary.

Shared `DirectorCanvas`, `DirectorPanel`, `DirectorEditorialFrame`,
`DirectorEditorialHero`, `DirectorSectionBand`, `DirectorMetricSequence`,
`DirectorMetricCard`, `DirectorGroupHeader`, `DirectorFilterRibbon`,
`DirectorContentStage`, `DirectorTableHeader`, `DirectorInspectorPanel`,
`DirectorSideSheet`, `DirectorPrimaryActionButtonStyle` and
`DirectorAdaptiveGrid` are the
implementation contract. The grid is four columns at 760 pt and above, two
columns from 420 through 759 pt, and one column below 420 pt. The filled
primary action uses the blue → ice → mint gradient with pure black content and keeps native Button
focus, disabled and keyboard semantics; secondary and destructive actions
remain native controls.

Home and all four capability libraries use the shared components. Home uses its
three Card Atlas outline modules, quota semantics, capability totals and Top10
navigation; its metrics and rankings use blue, ice, mint and teal tones and a
restrained deep-teal canvas environment. Capability pages use one Hero → metric
sequence → outline filter rail → project-group ledger → dismissible right-side
Sheet grammar. The Sheet is 380–420 pt wide, keeps the native List spatially
stable beneath a scrim, and is dismissed by its close control, Escape or the
scrim. Settings uses the same editorial Hero and six single-column section
bands while preserving native separators, diagnostics lazy loading and the
confirmed destructive deletion flow. Content remains opaque: Liquid Glass is
limited to navigation and control layers.

## 18. Refresh and theme refinement — 0.3.1

The 0.3.1 refinement centralizes refresh presentation in
`DirectorRefreshButton`, adds the compact toolbar size to the shared primary
action style, and changes `primaryActionForeground` to black for every gradient
action consumer. Settings section 01 is “Language & appearance” and owns the
visible Light/Dark segmented control. `AppThemeStore` persists only the app's
theme under its dedicated preference key and shares changes across windows and
sheets. These changes are presentation-only: refresh scheduling, SQLite,
indexing cadence and the capability-package format remain unchanged.

Settings section 06 presents the localized Author label with the fixed public
credit `七木 Simu`, followed by the application version. The credit is static
metadata and does not add a link, account identifier, or interaction.

The annotated polish keeps those semantics and adds one presentation pass:
the active sidebar row and Home welcome title's `Codex Director` fragment use
the brand gradient while the toolbar title remains native; page titles move to
52/36pt; Home module headings use symmetric spacing and omit the
two overview subtitles; the quota source uses a segmented switch and reset time
sits below the centered ring; project groups gain explicit inter-group spacing
and tinted icon-led headers; dark teal data text uses `#5FD7EE`; and Settings
uses balanced section padding with equal compact index actions.

The screenshot-correction pass removes competing system chrome from those
approved custom treatments: sidebar selection visually exposes only the brand
gradient, the selected sidebar symbol uses the shared deep-gray token, the
toolbar refresh item has no shared glass background or toolbar shadow, and the
quota source switch uses a brand-gradient outline rather than a system-blue
fill. The quota heading aligns to its column, the ring uses the named 216pt
diameter with a 20pt reset gap, and chart dates share each bar's category
center. These are refinements to existing v1 rules, not new product behavior.

This migration changes presentation only. It does not alter Core, SQLite,
indexing, cache schema, startup scheduling, source capability files, or real
user data. The implementation validation matrix is recorded in
`VALIDATION_PLAN.md`; GUI, VoiceOver, screenshot and Release evidence remain
explicit gates and are not inferred from source or unit tests.

### Native recomposition delivery record — 2026-08-31

The 0.2.5 implementation preserves the Scheme A rule that a successful build
is not visual acceptance. The disposable Debug Validation Host captured the
Home, four capability categories and Settings at the approved viewport
controls, with additional language, appearance, compact, stress and empty
states. The Host reports its actual product viewport in AX; screenshots never
label Host chrome as product content. Core, persistence, indexing, cache,
startup and source-resource contracts remain outside the visual migration.
