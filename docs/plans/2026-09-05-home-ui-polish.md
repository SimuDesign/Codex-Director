# Home UI Polish

Status: approved from the user's annotated production screenshot on 2026-09-05.

## Scope

This presentation-only pass corrects six visible issues without changing quota semantics, refresh scheduling, navigation, persistence, indexing, or the capability-package contract.

- Align the current-weekly-allowance heading to the leading edge of the Usage module's quota column.
- Reduce the quota-ring diameter from 236pt to the named 216pt token and use the existing 20pt spacing token between the ring and reset time.
- Replace the native blue-filled quota source picker with an outlined source switch that uses the shared brand gradient for the selected border, plus font weight and accessibility selection traits.
- Keep native sidebar selection state while suppressing its extra blue tint behind the custom gradient; render the selected symbol with a named high-contrast dark-gray token.
- Hide the macOS 26 shared toolbar glass background for the refresh item and remove the toolbar-size action shadow.
- Center every date label in the same categorical slot as its bar.

## Responsive and accessibility contract

The changes apply in Light and Dark appearances at 720x480 and 1280x800. The source switch keeps visible values, keyboard activation, selected traits, and a group accessibility label. Increase Contrast strengthens existing boundaries. Reduce Motion remains unchanged. All screenshots and validation fixtures use synthetic data.

## Validation

Run focused Home, refresh, shell, and annotated-polish tests; render the synthetic Validation Host in Chinese and English at 1280x800 and 720x480; inspect sidebar, source switch, ring/reset spacing, toolbar, and chart alignment; then run the full suite, public audit, universal Release build, and verified local installation.
