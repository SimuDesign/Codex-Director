# Folder entry and control-hit repair

User-approved scope: align the Capability Folders entry title with other main
destinations, search folders at this entry point, and make painted search/filter
fields fully actionable. Version, source files, existing folder preferences,
membership, indexing, databases and refresh scheduling are unchanged.

## UX and visual contract

- Entry search filters custom, Global and Project folder **display names** only,
  case/diacritic insensitive. Keep existing ordering, card actions and member
  counts. No capability-name/purpose results at the entry. Folder interiors and
  Add Existing continue to search capabilities.
- Preserve entry search and scroll state when entering/returning. Empty query
  restores both sections. Nonempty unmatched query shows a folder-specific empty
  state and Clear Search. Do not present a pending directory as confirmed empty.
- Entry title uses existing rounded semibold 52/36pt editorial tokens and the
  24pt decorative folder symbol; interior folder titles remain 32/28pt. Keep
  existing opaque surfaces, gutters and responsive layout.
- Search fields focus the single native editor when any painted background or
  icon/padding region is clicked. Preserve ordinary caret/selection/IME and
  keyboard input. Clear remains its own native action; disabled fields cannot
  gain focus through the enclosing gesture.
- Scope/sort/plugin-status fields keep a native Menu with its complete label
  box inside the actionable bounds, including padding and chevron. Preserve
  current values, native keyboard activation and accessibility. Library height
  remains 32pt; folder height remains 36pt. No duplicate hidden controls.

## Execution and checks

1. Add tests for folder name matching, localized defaults, ordering/no-match,
   title tokens, scope separation and shared-control consumption.
2. Implement the presentation-only changes, shared text-focus field and existing
   outlined menu reuse. Update bilingual strings and affected contracts.
3. Exercise an isolated synthetic native host: zh/en, Light/Dark, 720×480 and
   1280×800, edge/icon/chevron/center pointer activation, keyboard editing,
   clear/no-match/return and menu selection. AX inspection is not VoiceOver
   speech verification.
4. Run focused/full Swift tests, public audit and ordinary dual-architecture
   Release verification. Install using the existing recoverable replacement
   procedure only after the relevant checks pass. No GitHub operations.

This is a narrow correction to the existing product job and visual system, not
a new product direction, renderer migration or new persistence interface.

## Implementation verification

- Added seven entry-search/component tests. Focused checks: 65 tests passed.
  Final `./scripts/verify.sh`: 914 Swift tests, three skipped, zero failures;
  script fixtures, public source/license/media contracts and tracked audit passed.
  `./scripts/audit-public-release.sh --all` passed for tracked tree and history.
- Ordinary Release verification passed for 1.4.0 (27), macOS 26, arm64/x86_64,
  ad-hoc signature, bundled notices and absence of fixture/private-path content.
- Native synthetic host: inspected entry title, icon, cards and search at
  zh/en × Light/Dark × 720×480/1280×800. Pointer checks covered search icon,
  top/bottom padding, left/right edges, and menu padding/chevron. Verified native
  typing, substring selection/replacement, clear, no-match, enter/return search
  retention, interior capability matching and closed-menu value changes.
  Library scope selection and keyboard End/Return sort selection also worked.
- Existing folder preferences were compared before and after replacement and
  were unchanged. No membership/persistence/index/source mutation was added.
- Evidence limits: these are implementation checks, not an independent quality
  decision. AX inspection is not actual VoiceOver speech verification. This
  round did not change system accessibility settings to exercise Increase
  Contrast, Reduce Transparency or Reduce Motion, nor measure navigation speed.
  Disabled gesture behavior is covered by its enabled guard, not a native
  disabled-field interaction experiment. No Tag, Release or GitHub push occurred.
