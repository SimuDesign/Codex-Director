# Annotated UI polish plan

Date: 2026-09-05  
Branch: `ui-optimization`

## Approved scope

- Apply the four annotated screenshot corrections without changing navigation, data semantics, persistence, indexing, or privacy behavior.
- Keep Home as the shared page-grid reference and preserve native full-width scroll containers.
- Keep quota source selection explicit: use a compact segmented switch because the value chooses among named sources rather than toggling one Boolean state.

## Visual contract

- The `Codex Director` fragment in Home's welcome title and the active sidebar destination use the blue → ice → mint brand gradient; the window toolbar product name retains its native title color. Selected-row text and symbol use black for contrast.
- Primary page titles use one smaller rounded-semibold scale: 52 pt standard and 36 pt compact. Decorative page symbols remain 24 pt.
- Home module headings have equal top and bottom breathing room. Capability-summary and usage-ranking module subtitles are removed.
- Quota evidence is reduced to reset time below a horizontally centered ring. Recorded time and the evidence heading are removed. Daily bars and date labels share the same categorical center.
- Toolbar refresh uses a 28 pt compact control height. Settings index actions use one compact inline size and equal width.
- Capability project groups have a tinted, icon-led header and a 16 pt gap between group outlines.
- The dark teal data accent uses the high-contrast cyan-teal value already approved for dark emphasis.
- Settings omits the hero subtitle. Every section uses equal 24 pt top/bottom padding, and its ordinal aligns to the top of the section title.

## Implementation and verification

1. Add source-contract tests for the approved title, branding, quota, group, contrast, and Settings geometry.
2. Update shared tokens and components, then route Home, capability pages, sidebar, toolbar, and Settings through them.
3. Update the design-system and validation contracts.
4. Run focused UI tests, the complete Swift test suite, and the synthetic UI validation host in Dark/Light and standard/compact windows.
5. Build and install the verified Release app according to the local deployment contract, then perform an independent quality review.

## Validation record

- Focused visual-contract suite: 48 tests passed, 0 failures.
- Full regression suite: 652 tests passed, 0 failures, 3 conditional skips.
- Synthetic validation host inspected in Dark and Light appearances at 1280 pt and 720 pt product widths.
- Follow-up title-placement correction verified that only the `Codex Director` fragment in the Home hero uses the brand gradient, while the toolbar title keeps its native color; the full hero remains one accessibility heading.
- Release build succeeded and the installed bundle matched the build artifact byte-for-byte.
- Installed bundle signature passed strict deep verification; version `0.3.1 (16)` launched from `/Applications/Codex Director.app`.
- Previous installed bundle remained recoverable in `{{HOME}}/.Trash/` during local validation.
- Formal review found no blocking visual, accessibility-tree, localization, data-contract, or installation regressions in the approved scope.
