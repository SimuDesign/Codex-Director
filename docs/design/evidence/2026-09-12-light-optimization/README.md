# Light UI optimization runtime evidence · 2026-09-12

This folder contains synthetic-only evidence from the isolated Debug Validation Host. It did not read production preferences, logs, source roots or installed-app data, and it did not replace `/Applications/Codex Director.app`.

## Frozen candidate

- App: `.build/ui-optimization-validation/Build/Products/Debug/Codex Director Validation.app`
- Bundle ID: `com.peiweitang.CodexDirector.Validation`
- `DirectorUIValidationMode`: `true`
- Fresh/staged debug dylib SHA-256: `6ba1406903331d76264517951eb2b4d3e08eac100145c5f4d1997091eaf62989`
- Runtime: macOS 26.5.1; standard system contrast, transparency and motion settings.
- Focused tests: 35 passed, 0 failed.
- Full `scripts/verify.sh`: `Executed 660 tests, with 3 tests skipped and 0 failures (0 unexpected)`; the script's final Debug build also completed. Existing SwiftPM unhandled-fixture and compiler warnings remained non-fatal.

## Final post-icon-fix captures

| File | Configuration and evidence |
| --- | --- |
| `light-agent-1280x800.png` | zh-Hans, explicit Light, AX product viewport 1280×800. One sidebar gradient; selected SF Symbol and label both use the black navigation foreground. Filter values, metadata and call units remain readable. |
| `light-agent-selection-detail-1280x800.png` | Same matrix with the first capability selected. The opaque selection wash and boundary remain inside the group row; title/summary/metadata remain readable behind the scrim. The Light action rail uses white content. |
| `light-agent-evidence-expanded-1280x800.png` | Same detail after evidence expansion. Show/hide controls keep the same full-width outer geometry and the evidence remains scrollable. |
| `dark-stress-refresh-loading-1280x748.png` | zh-Hans, System/Dark, Stress, controls visible, AX product viewport 1280×748. Repeated evidence/list scrolling and post-scroll keyboard selection completed without a crash. Refresh loading exposes one native busy indicator named `刷新中…`; the selected sidebar icon and label share black foreground on the bright Dark navigation rail. |

PNG pixel dimensions include the Retina backing scale, title bar and window shadow. They are not product-view dimensions; the AX Host value above is the product contract.

## Width captures awaiting independent replacement

`light-plugins-en-720x480.png`, `light-plugins-zh-1600x1000.png` and `dark-agent-selection-detail-1280x800.png` were captured before the final explicit sidebar-symbol foreground correction. They remain useful for filter/action geometry only and are not final evidence for review item 04. Independent QA was asked to replace them from the frozen candidate.

- The 720 Host reported AX product viewport 720×480. The English search field owns one row and the closed values `All capabilities`, `Past 7 days ↓` and `All plugins` remain readable below it.
- The wide Host reported the requested AX product viewport 1600×1000 after hiding controls. macOS constrained the on-screen window to 1600×875 points on the available display; the stored window capture must therefore be treated as width/layout evidence, not proof of a physically displayed 1000-point height.

## Interaction and accessibility record

- Pointer selection and `Escape` dismissal preserved the native List selection binding and AX selected state.
- After dismissal, `Down` selected an actual capability row and reopened its detail. Structural header, metric, filter, notice and group rows did not receive keyboard selection; no native blue selection painted into the gutter.
- The row-scoped public AppKit adapter survived repeated Stress evidence scroll down/up/down, capability-list scroll and post-scroll selection. No `NSOutlineView` reload crash occurred.
- CUA AX exposed localized labels/values for sidebar destinations, filter menus, close, evidence show/hide, evaluations and refresh loading. This is AX inspection, not VoiceOver speech.
- Actual VoiceOver speech, Increase Contrast, Reduce Transparency and Reduce Motion were not exercised because they require separate accessibility runs; no global accessibility preference was changed. Hover/pressed action colors were verified by resolved dynamic-color full-rail sampling tests rather than a held-pointer screenshot.

Independent Quality Engineer review and Release identity/signature checks remain separate acceptance decisions.
