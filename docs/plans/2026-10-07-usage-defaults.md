# Usage selection defaults — 2026-10-07

## Approved behavior

- Home rankings, all four capability libraries, and capabilities inside every Global, Project or custom folder initially select the last 30 local natural days.
- All capability lists initially sort by observed call count descending. Home rankings already use descending counts.
- Missing or invalid period preferences resolve to 30 days. Valid remembered 7-day or 30-day choices remain authoritative; do not reset production preferences.
- Folder/Tab session sort overrides remain authoritative after a user changes them. Only their absent/default fallback changes.
- Keep the existing controls, count/unknown semantics, natural-day intervals, cached aggregates, shared refresh and folder memberships. Do not change indexing, schema, parser marker, manifest v1 or the unpublished 1.5.1 version.

## Implementation and checks

1. Add regression tests for fresh/default construction, malformed preferences, valid remembered values, all four libraries, folder sort fallback and unavailable statistics.
2. Change only default values and fallback choices; retain explicit seven-day test/validation scenarios.
3. Run focused tests, complete verification, public audit and a universal Release build. Preserve the earlier uncommitted attribution repair.
4. Replace the installed App only after verification, retaining the old bundle recoverably. Confirm live selectors and sorting without clearing saved preferences. No Git publication is authorized.

## Execution record

- Focused default/preference/library regressions: 48 tests passed, no failures.
- Complete verification: 1083 tests, 3 existing skips, no failures; public audit, version/release/performance contracts and Release build passed.
- Installed the verified 1.5.1 (35) universal ad-hoc build, containing arm64 and x86_64. Installed bundle matched the build artifact; the previous App remains recoverable in Trash.
- Native installed-App AX checks confirmed Home's thirty-day selection, all four libraries' thirty-day/Usage ↓ values and all three Global-folder tabs' thirty-day/Usage ↓ values. Available Agent and Skill row counts were descending.
- Before/after preference fingerprints matched for both remembered periods, existing folder memberships, evaluations and classification overrides. No production preferences were reset.
- This small behavior-only check does not claim a new complete appearance or actual VoiceOver speech matrix. No Git commit, push, PR, merge, tag or Release was performed.
