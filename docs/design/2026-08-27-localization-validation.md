# Language Switching Validation

Status: PASSED for the documented implementation, automated, Release, and representative GUI/AX scope. The unperformed runtime/accessibility cases below remain explicit residual checks, not implied passes.

## Scope

Approved plan: `docs/plans/2026-08-27-language-switching.md`. Target release: 0.1.1 (2). All runtime visual checks use the isolated opt-in synthetic validation app, never production source data or preferences.

## Acceptance ledger

| Area | Required evidence | Result |
| --- | --- | --- |
| Language preference | No/invalid preference gives Chinese; English survives store reconstruction; only dedicated key is touched | Pass — isolated production-constructor sequence and sentinel checks |
| In-memory isolation | Validation/previews/tests cannot read or write production defaults | Pass — closure-only/memory store constructors and Debug injection reviewed/tested |
| Shared state | Switching updates existing windows without replacing language/app models or starting another index | Pass for synthetic model/state and live multiwindow switching; real in-flight indexing not exercised |
| Resource integrity | Both locales have required keys, compatible placeholders and plural rules | Pass — duplicate/key/call-site/enum/format contracts; embedded-bundle lookups |
| Raw content | Names, summaries, task titles, IDs, original evidence and technical detail remain verbatim | Pass — presentation tests include source/model-name collisions and raw task/evidence boundaries |
| Semantic integrity | Agent/Skill/MCP/Token retained; completion/effectiveness and observed/unknown remain distinct | Pass — terminology tests, inspector/empty-state GUI inspection |
| Home | Chinese/English labels, counts and deep links agree | Pass — count/plural and Show Empty Projects retention checks |
| Capabilities | Table, filters, inspector, enum labels, bilingual search and stable selection | Pass — Chinese query retained in English; selected plugin preserved; hidden selection reconciliation covered |
| Tasks | Timeline modes, selected invocation, evaluation, timestamps/durations, Back/Close and keyboard | Pass — selected invocation/evaluation retained through switching; Escape closes inspector |
| Review | Localized rule names/descriptions, raw evidence, severity filters and empty states | Pass — final wide/compact/empty retests; Errors-only filter and selected finding retained through switching |
| Usage | Localized allowance/task Token summaries, dates, quantities and empty states | Pass — table rows visible and horizontally reachable, per-day AX values, raw-name tests |
| Data Status | Localized phase/counts/source categories, original error details, confirmation copy | Pass for normal GUI/confirmation and presentation tests; actual failed/live indexing not exercised |
| Settings | Fixed self-language names, immediate switch, retained privacy content | Pass — one visual heading and one native AX label; both options and privacy copy verified |
| Layout/appearance | Chinese and English at minimum/default widths, Light/Dark, readable actions and labels | Representative matrix passed; not every page × locale × appearance combination was exercised |
| Accessibility | Actual names/values/roles inspected; keyboard route exercised; unperformed spoken VoiceOver cases recorded | AX/keyboard pass; full spoken VoiceOver not performed |
| Automated regression | Focused and full Swift test evidence against final source snapshot | Pass — final focused 17/17 and full 346/346 after the last AX change |
| Release artifact | Correct version, both language resources, resource lookup independent of development location, strict signature, no runnable validation host/fixtures | Pass — final Release independently verified and root hash/signature/plist cross-checked |

## Boundaries and residual gates

- OS-owned menus and permission dialogs remain controlled by macOS.
- No installation, production launch, GitHub operation, system appearance/language change, or global dependency/configuration change is part of this task.
- Full spoken VoiceOver and OS accessibility-setting matrix are not implied by static/AX checks. Only mark cases passed after running them.
- No physical upgrade/relaunch of the installed production app was performed. Preference restoration is verified with isolated production-constructor tests; the synthetic app intentionally never persists language to production preferences.
- No real in-progress indexing, source failure/permission error, or first-run production bootstrap was launched. Synthetic model/database/generation/evaluation invariants and presentation tests cover those non-UI boundaries, not the full real-runtime scenarios.
- Increase Contrast, Reduce Transparency, Reduce Motion, and the full spoken VoiceOver flow were not toggled on the host. The appearance sampling uses validation-only controls.
- The complete Cartesian UI matrix and manual Stress-dataset pass were not run; stress cardinalities and reset races are covered by automated validation tests.
- Xcode may register a temporary built bundle with LaunchServices as a build side effect; no application was installed or copied to Applications.

## Evidence

### Final independent automated and Release evidence

- Independent reviewer: `luna_ui_quality`, review-only; all implementation and repairs were performed by the other Luna agents. Root owned GUI acceptance and this ledger.
- Final focused run: 17/17 (Accessibility 6, ReviewLayout 3, ReviewViewModel 8), `/tmp/codex-director-l10n-final-focused3.u8t3fE/scratch`, 2026-08-27 23:45:24 +0800.
- Final full run: `swift test --disable-sandbox --scratch-path /tmp/codex-director-l10n-final-full3.rj8d1H/scratch` with isolated module caches, **346/346, zero failures, 88.518 seconds**, completed 23:47:26 +0800. Includes resource contracts 5, language tests 7, and presentation localization tests 11.
- Final production build: existing `scripts/build-local-app.sh`, isolated derived-data directory; no installation or launch.
- Release artifact: `/tmp/codex-director-l10n-final-release4.LojCjF/derived/Build/Products/Release/Codex Director.app`.
- Executable SHA-256: `ce8cd94748e5104b7f9baa2a30c64b03dace67718c02f6181b5010384ffa2a96` (independent QA and root match).
- Identity/version: `com.peiweitang.CodexDirector`, display name Codex Director, **0.1.1 (2)**, universal arm64/x86_64, minimum macOS 26.0.
- `codesign --verify --deep --strict` passes. Signature is local ad-hoc with runtime flag, not a notarized distribution claim.
- `DirectorUIValidationMode` absent from Release Info.plist; no UIValidationHost/UIValidationSession strings or exported symbols; no test/fixture filenames or private/validation text in bundled localization resources. This checks executable validation surfaces/fixtures, not an assertion that every inert source-name literal has been stripped.
- Both embedded `en.lproj` and `zh-Hans.lproj` contain valid Localizable.strings and Localizable.stringsdict. Direct `Bundle(path:)` lookup against the final embedded resource bundle passed without source-tree resource lookup: Language/语言 and plural 0/1/2/Int.max, including the exact `9,223,372,036,854,775,807` value.
- Final source comparison against the pre-localization baseline shows **no DirectorCore changes**. No database raw values, IDs, schema, original resources or global configuration were changed.

### Intermediate synthetic UI snapshot

- Fixed run copy: `/tmp/codex-director-l10n-ui.nEPWF6/Codex Director Validation.app` (2026-08-27 23:14 build). Version 0.1.1 (2), validation-only bundle ID and Bool opt-in verified; strict signature and both packaged locales verified before launch.
- This snapshot predates the final Settings label, capability ID, Usage raw-placeholder/AX/table-height, and Review compact fixes. It is not the final release artifact.
- Confirmed Chinese default, fixed language choice names, instant English/Chinese switching, two existing windows updating from the shared language store, and the same native window identity after switching.
- Confirmed Home Show Empty Projects survives Settings navigation and a switch from the other window; Capabilities search `插件` and selected plugin survive a language round trip; Tasks retains the selected task, invocation, timeline mode and synthetic local evaluation.
- Inspected Chinese/English labels, dates, counts, status/confidence, and raw synthetic names/IDs/evidence. Chinese Review rule copy changes while `Synthetic evidence only` stays unchanged.
- Inspected Light and Dark appearance using only the validation host controls. Product viewport measurements, not whole-window sizes, were used (1280×800 and 720×480).
- Keyboard: language popup arrow/Return selection, Tasks Escape closes invocation inspector, and Data Status confirmation Escape cancels. The destructive confirmation was opened for copy inspection only; Delete was never accepted.
- Source data, real indexing, installed application copies and production preferences were not used.

### Findings repaired during acceptance

- Settings showed the bilingual selector heading twice: Picker now hides its visual label while retaining its explicit AX label.
- Capability inspector's app-owned ID label bypassed localization: now uses the shared ID resource; actual IDs remain raw.
- Review's nested wide-only split clipped its inspector and displaced navigation at minimum width: compact mode now stages findings and inspector with native Back/Escape.
- Usage chart's outer AX label overwrote each date/value label: child containment now preserves per-day labels.
- Unbounded native Usage tables collapsed to zero visible height in the outer ScrollView: explicit bounded heights now preserve the header and rows.
- Re-running the Debug build script reused an older renamed validation bundle. Root detected identical debug-dylib hashes despite source changes; the fresh normal-name build had a different hash. Repaired staging now validates the incoming bundle identity, preserves the old validation app in a unique backup, moves the fresh product, and compares fresh/staged dylib hashes. Repeated runs passed. Modification timestamps alone are not freshness evidence.
- The first compact Review repair omitted its existing empty-state explanation: a final small delta is reusing the same localized empty-state content in compact mode.

### Fresh artifact delta checks (23:31 build)

- Root verified signature, Bool opt-in, version, identity, then copied the artifact into `/tmp/codex-director-l10n-final-ui.r3dEDZ/Codex Director Validation.app`. Executable SHA-256 `456465da750def4a555837d01bac2d0b33ef80acd684307c8ff50e4d1c77f19c`; debug-dylib SHA-256 `59e03e4c760716c6ac5414fc1c22fc3f9fa3509402dc06c73f875af21db31d4f` (different from the stale snapshot).
- Chinese default reconfirmed after launching the new memory-only host. Settings visual duplicate is gone; one redundant native/explicit AX name was found and removed in the final source delta.
- Review 720×480: sidebar, Filter, summary and selected finding are visible; raw evidence stays raw; Escape returns to findings. Both list and inspector screenshots captured.
- Usage 720×480: both tables now show headers/data; moving the horizontal scrollbar exposes Output/Reasoning/Total; chart AX text now contains each localized date and Token value instead of seven repeated chart titles.
- Empty synthetic dataset reset preserves Chinese. Usage empty-model explanation is localized. Review compact empty-state omission above was caught here.

### Final GUI acceptance

- Final root-owned host: `/tmp/codex-director-l10n-ax-final.dHd6tX/Codex Director Validation.app`, copied only after signature, identity/Bool opt-in and hash checks. Final Debug dylib SHA-256: `ad149e08d65a17977ec77c757339087b852e4a732675fa1e71681be14e0b7452`; executable SHA-256: `20af4a67fc4524b2f58809cbd7ee9fedbbddfe9ca737a97e357c62c955f2b737`.
- Preceding final geometry snapshot (`4bf382b815f66d489af990470ea653d80bf45faa0cd3eb0472193cc76441f187`) verified Review title/Errors header no longer sit underneath the summary at 1280×800. Light/Dark and English/Chinese compact inspector captures show readable content and native Back.
- Errors-only Review filter and `finding:validation-1` selection were preserved from Chinese to English without pressing the Back/Escape action during the transition. Raw `Synthetic evidence only` remained unchanged.
- Final AX delta confirmed at both default and actual 720×480: decorative checkmark is absent from the AX tree; only the localized no-actionable-findings text and incomplete-evidence warning are exposed. No claim of Verified/Healthy is announced by the icon.
- All root-owned synthetic validation apps were quit at the end. No production app was launched.

### Representative capture matrix

All captures contain synthetic data only. Earlier snapshots are used only for unchanged surfaces; repaired Review, Usage and Settings surfaces have explicit later delta captures.

| Surface | Actual samples | Evidence |
| --- | --- | --- |
| Home / multiple windows | Chinese Dark default; English Dark default and Light minimum; two-window language sync/filter retention | [Window sync](evidence/2026-08-27-localization/multiwindow-home-zh-state.png) |
| Capabilities | Chinese Dark default inspector; English Dark default and Light minimum; bilingual query/selection | [Search retained](evidence/2026-08-27-localization/capability-en-search-preserved.png) |
| Tasks | Chinese/English Dark default; English Light minimum; selected invocation/evaluation retained | [Evaluation retained](evidence/2026-08-27-localization/tasks-zh-selection-evaluation-preserved.png) |
| Review | Chinese/English minimum; Light/Dark default; representative and empty; final geometric/AX deltas | [Wide](evidence/2026-08-27-localization/review-en-light-default.png), [compact](evidence/2026-08-27-localization/review-zh-light-minimum.png), [empty](evidence/2026-08-27-localization/review-empty-zh-dark-minimum.png) |
| Usage | English Light default; Chinese Dark minimum; table horizontal scroll and empty-model copy | [Default](evidence/2026-08-27-localization/usage-en-light-default.png), [minimum](evidence/2026-08-27-localization/usage-zh-dark-minimum.png), [hidden columns](evidence/2026-08-27-localization/usage-zh-minimum-horizontal.png) |
| Data Status | Chinese Light minimum; English Light minimum/default; confirmation open/Cancel only | [Chinese](evidence/2026-08-27-localization/data-status-zh-light-minimum.png), [English](evidence/2026-08-27-localization/data-status-en-light-default.png) |
| Settings | Both languages default/minimum; Light/Dark sampling; final single heading and native AX name | [Chinese](evidence/2026-08-27-localization/settings-zh-dark-default.png), [English](evidence/2026-08-27-localization/settings-en-light-default.png) |

### Intermediate automated checks

- Foundation localization/resource checks: 11/11 in `/tmp/codex-director-l10n-final11` (production-store test subsequently tightened to reconstruct from an invalid persisted value).
- Presentation/resource/Tasks checks: 24/24 before final layout deltas.
- Usage layout/VM/presentation/resource checks: 33/33 after the table/AX repairs.
- These are not a substitute for the pending final full-suite and Release artifact checks.

### Regression cases identified during implementation

- Settings navigation must preserve Home's Show Empty Projects filter and the Tasks invocation selection, not only the underlying task selection.
- A raw task title equal to a UI resource key (for example `Home`) must remain verbatim in both languages.
- Built-in rule summaries must use the same stable rule-ID lookup in Review and the capability inspector; original evidence bypasses localization.
- Resource checks must cover real call-site keys and the union of `.strings` and `.stringsdict`, not only matching key counts between languages.
- Missing locale resources must fall back to the supplied English source copy, not the host's preferred language.

### Platform references

- [Apple: Localizing package resources](https://developer.apple.com/documentation/xcode/localizing-package-resources) — package localization declaration, `.lproj` resources, and `Bundle.module` lookup.
- [Apple: Localizing Your App](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPInternational/LocalizingYourApp/LocalizingYourApp.html) — `.stringsdict` plural resources and localized formatting.
