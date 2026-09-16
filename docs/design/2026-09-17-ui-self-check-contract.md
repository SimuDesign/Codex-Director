# UI self-check repair contract — 1.3.1

Date: 2026-09-17  
Target: native macOS 26+, visible version `1.3.1`, internal build `26`  
Owner: UI Designer; local container amendment: root following Product Designer review; production implementation: Frontend Developer; independent acceptance: Quality Engineer  
Status: implementation-ready presentation contract, not a claim of runtime acceptance.

### Approved local container exception

Following repeated independent native AX failures, root accepts the Product
Designer's bounded behavior-equivalent ruling: replace only the nonselectable
`CapabilityFoldersView` List with one native vertical ScrollView and a
LazyVStack with zero implicit spacing. Headers, tabs, filters and results
scroll together; the existing detail overlay stays viewport-pinned. The four
capability libraries retain their native `List(selection:)` without changes.
This amendment supersedes the List-specific and real-button fallback wording
below for this folder browser; it is not a general design-system exception.

Use full 40/16pt content gutters, not List's previous minus-8pt compensation.
The scroll container and indicator remain full workspace width. Preserve the
1280pt cap, 4/3/2/1 grid and every named gap with one owner. Keep stable IDs,
scroll target layout and the existing per-window, per-folder/tab search,
sort, expansion, selected detail and scroll restoration. No data, membership,
relation, preference, index or I/O behavior changes are authorized.

Prefer the existing real SwiftUI Buttons once their actions export correctly;
remove the newly added button bridge if unnecessary. New Folder, Back, Add
Existing and empty-state actions must be distinct correctly named native
controls with working AX activation; headings retain their semantic roles.
Do not use hidden duplicates or aggregate-row replacement actions. Fresh
native geometry, action, keyboard and long-content scroll restoration checks
are required; this container ruling alone is not acceptance.

Native long-content verification found that the outer target layout suppressed
the nested resource targets. Apple's [scroll target layout documentation](https://developer.apple.com/documentation/swiftui/view/scrolltargetlayout%28isenabled%3A%29)
specifies that a primary layout prevents its nested layouts from becoming
targets. The bounded repair uses sibling header/grid/resource target layouts,
not an outer primary layout, removes the grouped-stage target and explicitly
anchors restored view IDs at the top. Binding callbacks capture their session
context and ignore transition nils. Entry and folder/tab positions must both
pass fresh native round trips; this does not authorize new persistence.

## Inputs and boundaries

Read: repository `AGENTS.md`, `HANDOFF.md`, the complete Director visual Skill,
`DESIGN_SYSTEM_V1.md`, `VALIDATION_PLAN.md`, the approved Capability Folder
browsing plan, the approved folder visual contract and the UI Designer Brief.
The reusable UI design method informed alignment, rhythm and state checks; it
does not supersede Scheme A. User-provided screenshots are private defect
evidence and must not be copied into this repository.

The approved behavior is unchanged: seven primary destinations; existing
folder membership, three tabs and per-folder/tab session state; explicit
companions and outside-folder previews; details, import, sorting, search,
theme and refresh. Do not change Core, SQLite, indexing, source files,
preferences, initialization, members, relation resolution, unknown/zero
meaning, capability-package format or network activity. Do not replace the
native app with the web prototype. Do not introduce icons, assets, glass
content panels or new colors.

## Source findings and bounded repairs

These findings combine source inspection with the user's observed defects.
They require final native after-state evidence rather than source assertions
alone. Line numbers refer to the starting snapshot and may move.

| Priority | Surface / source | Cause | Required repair |
| --- | --- | --- | --- |
| P1 | Folder entry, `CapabilityFoldersView.swift:150–188` | My Folders, Global & Projects and search-results titles are native `Section` headers, while cards/results are ordinary rows. The headers carry `listRowInsets`, but macOS does not paint those section headers on the same ordinary-row content boundary. | Render those headings as ordinary nonselectable structural rows in the same native List, using exactly the same row insets as their grids/results. Do not add random left padding to the native header. Preserve header AX traits and action labels. |
| P1 | Folder interior, `CapabilityFoldersView.swift:1250–1268` | Native `.segmented` Picker retains the system-blue selected fill, unlike the existing outlined quota selector. `minHeight` does not establish the painted segment geometry. | Use the shared outlined single-choice presentation specified below; keep the existing selection binding and tab sequence/default/session behavior. |
| P1 | Folder interior, `CapabilityFoldersView.swift:189–204, 463–520` | Header, tab and search/filter are independent List rows. Tabs and filters have zero explicit vertical row insets, so their painted boundaries nearly touch the next row. | Make spacing an explicit token contract, not a side effect of List defaults: header to tabs, tabs to search, search to result stage. |
| P2 | Folder sort, `CapabilityFoldersView.swift:1276–1297` | A borderless native Menu wraps a label with `minHeight: 36`; the outer native menu chrome still collapses to a small pill, unlike the search field. | Plain native Menu, one explicit disclosure chevron, hidden native indicator, visible current value. The outer custom field—not merely its label—owns the 36pt minimum painted/hit height. |
| P2 | Folder actions/membership, `CapabilityFoldersView.swift:631–651, 940–963` | Icon-only Menu uses default AppKit/SwiftUI menu-button chrome, producing thin unstyled pills beside branded controls. | Reuse an outlined icon-menu presentation with a minimum 28×28pt target, one neutral inset/outline and no extra native bezel. Keep real native Menu items, checked values, disabled state and localized AX label. |
| P2 | Import type and Settings theme, `CapabilityFoldersView.swift:1511–1519`, `SettingsView.swift:218–229` | The same system-blue segmented treatment survives in adjacent related flows. | Reuse the outlined single-choice component; keep all current filter/theme values and bindings. This is not permission to redesign Settings or the menu-bar switch. |
| P1 / native recheck | New outlined helper, `DirectorSchemeA.swift:DirectorOutlinedSegmentedOptionButtonStyle` | The interim helper applied `DirectorTypography.label` (`.caption`, 10pt on macOS), shrinking controls that previously used the native body-sized label. The approved prototype sets tabs, search input and sort value to 13 logical pixels. | Introduce a scoped segmented-control/text-control typography role at native body size (13pt), selected semibold / unselected regular. Never globally increase `DirectorTypography.label`, and do not shrink compact controls to caption size. |
| P2 / independent native recheck | Real segmented bridge intrinsic sizing, `DirectorSchemeA.swift:NSSegmentedControl` subclass | Intrinsic width based on different text measurement from the drawing path can underestimate selected semibold glyphs. Settings `.fixedSize()` then unexpectedly wraps short Light/Dark labels despite being unconstrained. | Measure the same 13pt semibold attributed string used for painting, round its width upward and apply the existing 4pt tolerance. Use the widest choice for equal segment width. Unconstrained Settings labels must stay one line; explicit narrow proposals retain equal-height wrapping. |
| P1 / independent AX recheck | Final structural-row and folder-header boundary, `CapabilityFoldersView.swift:structuralRow / folderHeader` | List can flatten an otherwise correct heading/action HStack into one nonactivatable aggregate. Containment passed source checks but subsequent native testing still did not expose genuine New folder, Back and header Add existing children. | Retain scoped `.accessibilityElement(children: .contain)`, but do not treat it as sufficient. Use the bounded real NSButton bridge below where SwiftUI/List does not export the genuine action. Native child activation, not a modifier or aggregate-row click, is the acceptance condition. |
| P3 / verify | Wide page geometry, `DirectorSpacing.swift:DirectorPageLayout / DirectorCapabilityFolderLayout` | General pages cap at 1440pt; folder browser has an intentionally approved local 1280pt cap. Above a 1360pt workspace, their centered left edges can therefore differ despite identical 40pt minimum gutters. | Preserve the local cap in this contract; align every element within each page's chosen measure. If root approves one cross-page cap, document that precise visual change before implementation. Do not confuse intentional centering with the Section-header bug. |

### All-seven-page audit coverage

- Home uses `HomeCardAtlasFrame` → `DirectorPageContentFrame`; its existing
  16pt hero-to-module and 32pt inter-module separation already express the
  approved rhythm. Do not globally enlarge its spacing to fix folder rows.
- Custom Agents, Custom Skills, Installed Skills and Installed Plugins all
  use `CapabilityLibraryView`: common header/metric/filter rows, shared page
  insets, 24pt metric-bottom space and 12pt filter-bottom space. They do not
  contain the entry-page native Section-header defect. Keep their native
  `List(selection:)`, row-contained selection paint and exact 20pt
  inter-project group gap. Verify both themes and constrained controls.
- Settings uses the same content frame as Home and six bands with 24pt
  symmetric vertical padding. Its adjacent theme segmented style is in
  scope; preserve the existing 48pt Settings actions and their widths.
- Capability Folders is the direct defect surface. Inspect both entry and
  interior states, not just one representative screenshot.
- Capability details keep the current information order and approximately
  400pt side sheet. Body/context groups already use 20/12pt spacing; verify
  no relation title or menu clips after the icon-menu presentation changes.
  Evidence/evaluation controls and modal dismissal are not being redesigned.
- The quota source already has an outline selector. It is the local
  appearance reference, not permission to change current allowance/history
  data, source selection or menu-bar formatting.

## Layout and geometry

Measure workspace viewport points, not total window width or screenshot
pixels. Native List/ScrollView spans the workspace, retaining its far-right
scroll indicator. Apply margins to content/ordinary structural rows, never
to the whole scrolling container.

| Item | Standard workspace ≥760pt | Compact workspace <760pt |
| --- | ---: | ---: |
| Minimum horizontal page gutters | 40pt | 16pt |
| Folder local maximum content measure | 1280pt | Available width |
| Folder ScrollView content inset | Full content margin; no List compensation | Full content margin; no List compensation |
| Top content inset | 24pt | 16pt folder variant; other pages retain their approved 24pt |
| Entry title/search block to first section heading | 20pt | 16pt |
| Section heading to its card grid/results | 12pt | 12pt |
| End of a folder section to next section heading | 32pt | 24pt |
| Folder scope/header to tab control | 20pt | 16pt |
| Tab control to search/filter | 16pt | 16pt |
| Search/filter to list/empty/status result stage | 16pt | 16pt |
| Search and sort painted minimum height | 36pt | 36pt |
| Search/sort horizontal gap | 12pt | Search on its own row, then 8pt gap to visible sort |
| Segment item minimum height | 32pt | 32pt; grow for wrapped labels if necessary |
| Outlined selector inner padding | 4pt | 4pt |
| Icon-only action menu minimum target | 28×28pt | 28×28pt |
| Bottom page inset | 24pt | 24pt |

Use semantic local spacing tokens referencing the existing scale where
possible: `entrySectionGap`, `sectionContentGap`, `sectionGap`, `headerTabsGap`,
`tabsFilterGap`, `filterContentGap`, `pageBottomPadding`. One owner applies
each gap exactly once. Do not stack identical padding on both adjacent rows
or rely on native section-spacing defaults. Test measured painted bounds;
List may add platform-specific outer space.

Every structural block uses the same leading/trailing row edges: title,
search, section heading/action, card grid, tabs, filter, status, empty state
and result panel. Title text may be inset after its decorative symbol; the
title block itself must still start on the page grid. Group internal skill
indent and card internal padding remain intentional subordinate alignment.

Preserve the existing folder 4/3/2/1 grid thresholds and card heights. Do not
change which capabilities are counted. Entry inline search switches once at
900pt; folder filters switch once at 760pt. Instantiate exactly one live
native text editor per context; never reintroduce two shared-binding editor
candidates into `ViewThatFits`.

## Shared outlined single-choice appearance

Suggested name: `DirectorOutlinedSegmentedControl`. It has at least three
concrete consumers: folder three tabs, import type filter and Settings theme.
Keep the existing native single-choice state and local selection bindings.
Use a real AppKit `NSSegmentedControl` with `.selectOne` tracking and
`.fillEqually` distribution through a public, locally owned
`NSViewRepresentable` bridge. Its target/action updates the existing binding,
and state updates select the corresponding native segment. A scoped drawing
implementation may express the outlined appearance below while preserving
the real control's hit testing, selected state, keyboard, focus and AX
semantics. This route is preferred after native testing found that the
SwiftUI button group's virtual Picker accessibility representation collapsed
inside List to a nonactionable aggregate. Do not use a hidden/duplicate
Picker or virtual representation as a substitute for the actual control.
A drawn label with only a tap gesture is not suitable. Do not
discover/mutate window-wide AppKit controls, use private API, globally change
system tint or rewrite control classes outside this bridge.

- Outer boundary: existing `controlBoundary`, 1pt standard / 1.5pt Increase
  Contrast; radius `DirectorRadius.control` (8pt), opaque control/inset
  surface, 4pt internal padding and 4pt item gaps.
- Control text: scoped `DirectorTypography.segmentedControl` mapped to
  `.body` (13pt on the target macOS) or an explicitly scoped system 13pt role.
  Apply it to all outlined selector labels and outline text Menu current
  values. Selected is semibold, unselected regular. Preserve search's native
  readable body size. Do not use the general `.caption`/`label` role for
  primary control choices, and do not globally change metadata typography.
- Unselected items: no system-blue fill; primary text, regular weight,
  neutral content surface. Hover uses existing inset tone, without changing
  size or position.
- Selected item: semibold primary text and opaque inset fill with a
  1.5pt brand-gradient outline; 2pt outline in Increase Contrast. Gradient
  is a border only, not text or a second filled accent pill. Retain the
  native selected segment state and a current-value announcement.
- Pressed uses a darker/stronger neutral inset; selected border remains
  visible. Disabled uses existing neutral disabled presentation, not a blue
  fallback. Show native focus separately from selected styling.
- Folder tabs retain exactly Agent & Companion Skills → Agent → Skill,
  with real member counts on the latter two; pending count stays `—`.
  Their outer box is leading-aligned to the same page grid, maximum 620pt
  on desktop and full available width when constrained. Do not center the
  control as a side effect of the labeled Picker's intrinsic geometry.
- Compact/English labels may wrap inside equal-width items and increase
  height together. Keep the 13pt control role at compact widths rather than
  shrinking it; do not turn tabs into icons or hide the current choice.
- Settings Light/Dark remains permanently visible, not a dropdown and not
  a System option. Import All/Agent/Skill remains complete. Unconstrained
  Settings `.fixedSize()` must present `浅色` / `深色` and `Light` / `Dark`
  as single lines. Intrinsic text measurement must use the drawing-identical
  13pt semibold attributed string, `ceil` its measured width and add the
  existing 4pt tolerance; equal segment widths use the widest choice.
  This is geometry correction, not a new font, shorter label or larger
  global spacing rule. An explicitly narrow proposal may still wrap choices
  into equal-height segments without shrinking the 13pt type.

### Accessibility and keyboard

Container has the existing localized label and selected value; children
expose their full localized names and native selected state. Counts may be
read with the tab title; icons and outlines are AX-hidden. Preserve the
real NSSegmentedControl's roles and activation behavior rather than inventing
an unrelated role. Avoid duplicate container announcements. The folder
selector must expose all three individually actionable choices, with exactly
one selected. VoiceOver must identify that choice and activate the others.

The following List-boundary investigation is retained as historical evidence;
the approved local ScrollView amendment above supersedes its implementation
route. At the investigated ordinary List boundary, structural section-heading rows and
folder-header rows use `.accessibilityElement(children: .contain)`. Native
heading text, New folder and Back remain distinct children, with their
existing labels and real actions. The container must not collapse into an
aggregate that cannot activate its child controls. Do not create synthetic
replacement actions or change which row is selectable. Apply containment
only at these scoped boundaries, not as a window-wide AX rewrite.
Containment is necessary for the intended grouping, but native evidence has
shown it is insufficient on its own inside this List. A source assertion
that the modifier exists does not establish that a genuine action is exposed.

### Historical real-button fallback (superseded locally)

Repeated actual native tests found that even genuine NSButton children were
flattened at this List boundary. Do not retain an unused bridge merely to
match these historical attempts; the local ScrollView amendment is current.

If the existing SwiftUI action still does not export as a genuine activatable
child, a public `NSViewRepresentable` owning a real AppKit `NSButton` is
approved for these specific consumers: New folder, Back, custom-folder
header Add existing, and generic empty-state Add / Clear / Retry actions.
The real button owns its visible native title, SF Symbol image/cell,
target/action, enabled state, focus and AX action. Target/action calls the
existing closure; it does not create a second interaction or change behavior.

Preserve exact Scheme A standard/toolbar secondary-action geometry, including
the existing font, padding, minimum height, outlined surface, hover/pressed/
disabled/contrast states. Back retains its plain presentation rather than
receiving a new bordered button. A locally scoped drawing treatment may keep
that appearance while the real NSButton remains the hit-testing, keyboard,
focus and accessibility source of truth. Do not implement a hidden duplicate,
overlay-only button, virtual representation, global AppKit mutation or private
API. Do not substitute a clickable aggregate row for the button.

Every affected action must appear as its own genuine native control with the
correct localized name, and actual AX/keyboard activation must perform the
existing action. Verify New folder opens its input sheet, Back returns to the
entry page, Add existing opens the existing import sheet, and empty-state
Clear/Retry calls the established action. Until that native evidence passes,
the defect remains blocked regardless of containment or source-test results.

Native Menu items are not being rewritten under this fallback. The automation
provider's unsupported direct AX invocation of a menu item is not by itself
a product defect when the real native menu opens and its keyboard Home /
Return selection correctly activates the existing import action. Record
tool limitations separately and verify genuine native menu behavior.

Keyboard-only users can enter the group, discover native focus and select
all options with standard activation. If left/right keyboard handling is
needed beyond the real native control's existing navigation, scope it to
focus inside this control; it must never steal arrows from the search
editor, capability List, menu, or detail. Keep native focus-ring geometry
separate from the selected gradient border even when draw is overridden.
Preserve existing selection and per-tab browsing state after keyboard and
pointer transitions. Focus visibility and actual VoiceOver speech require
native evidence, not source tests alone.

Apple references reviewed for implementation guidance on 2026-09-17:
[segmented controls](https://developer.apple.com/design/human-interface-guidelines/segmented-controls),
[selection accessibility traits](https://developer.apple.com/documentation/swiftui/view/accessibilityaddtraits(_:)),
[move commands](https://developer.apple.com/documentation/swiftui/view/onmovecommand(perform:)).
The static documentation reader did not expose the JavaScript body/Markdown
content. Treat API correctness as an SDK compilation and native verification
gate rather than inferring behavior from an unavailable body.

## Appearance, motion and privacy

Use current Scheme A canvas/panel/inset/controlBoundary/text tokens. Dark and
Light must both show neutral outlines and readable selected text; no fixed
system-blue selected segment fill. This does not change theme-specific main
action foregrounds (Light white, Dark black) or sidebar brand selection.
Increase Contrast strengthens existing outlines without making selection
depend solely on color. Reduce Transparency is opaque; Reduce Motion removes
nonessential transitions. No new animation, scaling, glow or shifting geometry.

Use synthetic fixtures and the disposable validation host only. Do not read,
reset, seed, clear, reorder or rewrite production folder preferences for an
UI screenshot. Saved Self Training and all other memberships are unchanged.
Capture only synthetic app surfaces; do not publish the user's screenshots,
desktop, paths or account values.

## Frontend and independent acceptance

Frontend owns presentation production code, local token registration and
source/tests; Quality Engineer owns the independent outcome. Root owns
build/install/publishing. Report any necessary Core or persistence change to
root and stop that extension.

Minimum native after-state evidence:

1. All seven destinations in zh/Dark/default width: common workspace
   gutters, scroll-indicator edge, no clipping; verify matching Light sample
   and compact Settings/library layout.
2. Folder entry and every internal tab in zh/en, Light/Dark, 720×480 and
   1280×800 window presets plus a wide preset. Record actual workspace
   viewport and screenshot pixels separately. Measure title/section/grid/
   tab/search/result leading edges and vertical painted-bound gaps.
3. Tab pointer and keyboard selection, selected AX values, native focus,
   search-no-results-clear, Skill query → Agent → Skill state restoration,
   sort current value and actual reordered rows. In Settings, verify both
   zh and en theme labels paint on one line at unconstrained intrinsic size,
   and a genuinely narrow selector proposal wraps all segments to a common
   height. Verify New folder and Back are separate native AX controls whose
   pointer and keyboard/AX activation actually opens the sheet or returns
   to the entry page; aggregate-row click success is not equivalent.
4. Expand/collapse companion groups, outside-folder preview, reverse detail,
   close/Escape, import selection/confirm, row membership menus and folder
   reorder menus. No counts or memberships change simply from browsing.
5. Empty custom folder, pending count, background refresh with old content,
   failure/retry, theme switch and refresh idle/loading. Control geometry
   remains stable, unknown does not become zero and data does not disappear.
6. Increase Contrast / Reduce Motion / Reduce Transparency and keyboard/AX
   checks. Record actual VoiceOver speech separately. List any unexercised
   OS setting or interaction honestly; prior snapshots are not new evidence.
7. Fresh focused/full tests, public audit and Release verification before
   root's authorized recoverable App replacement. No GitHub push, Tag or
   Release is authorized by this contract.

Reject a result in which the section title remains outside the row gutter,
the system blue segment returns, search/list boundaries touch, sort paints
as a smaller pill, primary tab/control text shrinks to metadata caption size,
multiple text editors hang, actions disappear at compact width, or any
production membership/configuration change is required. Inspect the three
individual choices and selected state in the native AX tree; one collapsed
aggregate without activatable choices is not accessible acceptance.
