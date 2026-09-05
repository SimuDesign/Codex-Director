# Phase 2A native UI acceptance — 2026-08-27

Status: Core interaction acceptance and final independent delta QA passed. Full release/accessibility matrix is not complete. This is not a release-readiness declaration.

Outcome: the custom inventory → observed calls → local effectiveness evaluation journey is usable at the tested default and compact widths. Luna implemented all code; root supplied the plan, real-window findings, and acceptance evidence. The project visual-system workflow kept native controls, explicit evidence semantics, and privacy-safe screenshots as acceptance requirements.

## Scope and environment

- Request: execute the previously identified real-window UI/accessibility validation; root owns planning/acceptance, Luna owns code.
- Product contract: identify custom Agents/Skills, inspect observed calls, distinguish operational completion from user-assessed effectiveness.
- Environment: macOS 26.5.1 (25F80), Xcode 26.6 (17F113).
- Implementation plan: [UI validation plan](../plans/2026-08-27-ui-validation.md).
- Design authority: [design system](../../.design/codex-director/DESIGN_SYSTEM_V1.md) and [validation gates](../../.design/codex-director/VALIDATION_PLAN.md).
- Validation uses an opt-in Debug app with a separate bundle identity, temporary SQLite, synthetic fixtures, no scanner/coordinator, and memory-only classification/evaluation storage. No production application or real capability/session dataset may be captured.
- Light/Dark overrides are local to the validation view. The installed SDK exposes contrast/transparency/motion environments as read-only (confirmed by compilation); no fake override or system change is introduced. Actual OS-setting and spoken VoiceOver validation remain manual gates.

## Acceptance matrix

| Journey / surface | Expected evidence | Result |
| --- | --- | --- |
| Home → My Agents / My Skills | Exact user-owned category, counts agree with fixtures | Passed: exactly 2 Agents and 2 Skills, excluding installed/built-in assets |
| Home → observed / not observed / limited evidence | Filtered resources match summary semantics | Passed: 3 / 1 / 2; compact Home → Observed closes a previously selected unobserved inspector |
| Capability profile | Purpose, source metadata, confidence, operational stats, evaluation distinct | Default and compact profile passed; zero-call outcome remains explicitly insufficient |
| Capability selection / dismissal | Pointer and keyboard can open/close inspector | Pointer, Escape and Down passed from focused table |
| Tasks → invocation → evaluation | Effective/ineffective/uncertain/clear update selected state and Home aggregate | Passed: default labels/Clear/aggregate; compact inspector scroll reaches evaluation, Uncertain updates, Escape closes, Back returns to list |
| Semantic / technical timeline | Mode change clears hidden selection; unknown/partial evidence remains explicit | Passed: Technical reveals tool call and clears inspector; partial session remains marked Partial |
| Review / Data Status | Parser coverage notice discoverable in Data Status, not actionable review list | Passed: 1 actionable finding, 1 parser notice, 1 partial session; AX exposes counts/warning, native Filter menu activates and updates its current value |
| Usage | Reported allowance and local task tokens remain separate | Inspected: historical synthetic five-hour allowance 25%, local task/model total 175; Home has no valid weekly snapshot |
| Empty fixtures | Destinations remain navigable; no fabricated success or allowance | Passed for Home/Capabilities/Tasks/Review; zero summaries, missing allowance, incomplete-evidence message |
| Stress fixtures | Long names and many records remain selectable/scrollable | Passed: 160 resources/520 calls seeded, 159 visible rows with built-in hidden, scrolling/search/long-name profile/Unknown confidence inspected |
| Minimum / default / wide windows | Primary actions and evidence usable without unintended clipping | Core inventory/evaluation passed at measured 720×480 and 1280×748; wide 1600×748 geometry/AX exercised but right edge was partly outside visible capture; full wide acceptance incomplete |
| Light / Dark | Text, selection, control boundaries legible | Representative pairwise coverage inspected; full appearance matrix not completed |
| OS contrast / transparency / motion | Read actual values only; no setting changes or fake simulations | Not tested |
| AX tree / keyboard | Names, values, roles and primary navigation inspected | Capability filters, compact Back/Close and native Review Filter passed; search editing → Tab to table → Down → Escape → Shift-Tab passed; not full keyboard-only acceptance |
| Spoken VoiceOver / OS-wide accessibility | Requires explicit real-service/manual validation | Not tested |

## Evidence and findings

First real-window inspection used only the isolated Debug bundle. Home showed My Agents 2 (global 1/project 1), My Skills 2, observed 3, not observed 1, evidence-limited calls 2, evaluated invocations 3/ineffective 1. My Agents opened exactly the two Agent rows. Capability profile exposed meaningful purpose, fingerprint/modification metadata, operational outcomes and separate evaluation counts. Escape dismissed the inspector; Down reopened selection from the table.

| ID | Observed defect | Expected / remediation | Evidence |
| --- | --- | --- | --- |
| UI-01 (P1) | At default 1280×800, selecting a task compresses its list to a narrow strip; selecting a call pushes most of the evaluation inspector outside the right edge. | Readable pane minima with a genuine compact detail fallback; evaluation controls must remain reachable. | [Tasks before repair](evidence/2026-08-27/04-tasks-default-before.png) |
| UI-02 (P1) | At requested minimum 720×480, validation controls disappear through clipping and the capability inspector is cropped. Native Zoom was needed to recover. | Adaptive validation controls and compact product details; keep size recovery/close reachable. | [Minimum before repair](evidence/2026-08-27/03-capability-minimum-before.png) |
| UI-03 (P2) | Real AX toolbar labels are “Grid View”, two identical “Filter” controls, “Move”, and “chart.bar.xaxis”. | Explicit Category/Kind/Scope/Project/Usage names and current filter values. | Actual AX tree, root inspection |

Initial screenshots: [Home](evidence/2026-08-27/01-home-dark.png), [Capability profile](evidence/2026-08-27/02-capability-profile-dark.png). They are evidence of tested states, not approved final visual baselines.

The validation process exited during later interaction; no subsequent launch was attempted without rechecking the activation flag. Root subsequently copied the signed app into a unique run directory to separate UI operation from build output updates. Unit-level accessibility contracts do not prove actual keyboard focus, reading order, or layout.

Second-pass observations:

- Evaluation controls became visible after pane remediation. Ineffective selection changed Home from 3 evaluated/1 ineffective to 3/2. Uncertain and Clear changed selected states correctly; Clear reduced Home to 2/1. Effective was then restored. [Evaluation controls](evidence/2026-08-27/05-tasks-evaluation-visible.png), [updated Home](evidence/2026-08-27/06-home-evaluation-updated.png).
- My Skills included one called and one unobserved Skill. The latter showed 0 calls/evaluations and “Not enough terminal outcomes”, not a fabricated 0%/100% completion value.
- Review visually separated its actionable finding from its parser-coverage notice; Data Status exposed 1 notice and 1 partial session. [Review](evidence/2026-08-27/07-review-parser-separation.png), [Data Status](evidence/2026-08-27/08-data-status-parser-coverage.png).
- Light appearance and an empty fixture were exercised. Empty Review explicitly mentioned incomplete evidence. Empty Tasks/Capabilities remained navigable but their blank-list guidance is minimal; this is a potential later UX refinement, not a claim of completed onboarding design. [Empty Home](evidence/2026-08-27/10-home-empty-light.png).
- Stress interaction covered native table virtualization/scrolling, search, a long-name profile, and Unknown resource confidence. The long-name profile wrapped source metadata within the inspector. Unknown confidence stated insufficient evidence and remained distinct from call outcomes. [Long-name profile](evidence/2026-08-27/11-capability-long-name-light.png).
- Usage distinguished the seeded historical five-hour report (25% used, inferred source) from 175 locally indexed task/model tokens. Home correctly lacked a valid weekly snapshot. [Usage](evidence/2026-08-27/12-usage-unknown-allowance.png).

Second-pass defect disposition:

| ID | Finding | Retest |
| --- | --- | --- |
| UI-04 | Filtered-out capability retained its inspector, obstructing compact results | Fixed and reproduced as passing: [filtered selection cleared](evidence/2026-08-27/15-minimum-filter-selection-cleared.png) |
| UI-05 | Tasks status/count metadata fragmented in narrow panes | Fixed: final task-list/header and timeline status/confidence/duration remain readable; long names truncate with full AX names. [Final default panes](evidence/2026-08-27/21-default-tasks-final.png) |
| UI-06 | Root accessibility labels replaced Review and compact Tasks child names | Fixed: actual AX exposes Back to task list, Close invocation inspector, Timeline mode, coverage text, and a native Filter menu with changing value. [Final compact flow](evidence/2026-08-27/20-minimum-tasks-final.png), [native Review Filter](evidence/2026-08-27/23-review-native-filter-final.png) |
| UI-07 | Validation viewport readout/presets failed, then native toolbar chrome clipped the synthetic badge at minimum size | Fixed for visible minimum controls/readout. Final 720×480 badge and controls fit. Taller requested sizes settle at 748 pt; record actual sizes below, not requested heights. [Final minimum Home](evidence/2026-08-27/19-minimum-home-final.png) |

Compact product behavior was exercised after a settled readout of 720×480: the capability inspector fit and Close remained visible; invocation evidence scrolled to all three evaluation choices; Uncertain updated and Escape/Back worked. [Capability detail](evidence/2026-08-27/14-minimum-capability-after.png), [compact evaluation](evidence/2026-08-27/16-minimum-evaluation-after.png). These captures still show the intermediate harness badge clipping and do not constitute final chrome acceptance. A table-row AX click returned offscreen after horizontal scrolling; a click on the visibly rendered row selected it successfully. This is recorded as an automation limitation, not proof of complete screen-reader navigation.

### Final measured-window evidence

Final tested run copy: `/tmp/codex-director-ui-accepted.RCqSel/Codex Director Validation.app`, copied from the verified 19:14:19 Debug artifact after the 19:13:31 source freeze. Measurement overlays do not receive pointer hits or become AX elements.

| Requested product viewport | Settled readout | Acceptance evidence |
| --- | --- | --- |
| 720×480 | 720×480 | Full synthetic badge/controls visible, Home scrollable, compact capability and task details, reachable evaluation and Back/Close |
| 1280×800 | 1280×748 | Readable Tasks panes, one-line semantic badges, evaluation controls; 800 pt height not claimed |
| 1600×1000 | 1600×748 | Wide Tasks/Review geometry and native Filter activation exercised; right edge partially outside visible capture, so complete wide visual acceptance and 1000 pt height are not claimed |

Both taller presets settle at the same measured height in this environment. This is an observed limit, not a diagnosed OS cause. The readout describes view bounds, not proof that every pixel is on the visible display: the wide Light capture also shows a partially clipped right edge. No display/system setting was changed to force the requested size. [Wide layout](evidence/2026-08-27/22-wide-tasks-final.png), [wide Light capture limitation](evidence/2026-08-27/24-review-light-final.png). The app was returned to the visible default-width Home view. [Final Home](evidence/2026-08-27/25-home-light-final.png).

## Verification

- Root independent focused run (2026-08-27 18:31): `swift test --scratch-path /tmp/codex-director-ui-root --filter UIValidationTests` — 3 tests, 0 failures, 0.510 s. Covers representative/empty/stress data, session isolation, and canonical evaluation update.
- Initial WIP compilation exposed read-only accessibility environment keys; the plan was narrowed rather than introducing false simulation coverage.
- Pre-launch inspection caught a missing custom Info.plist activation key despite the Xcode command-line setting. No app was launched. A reproducible validation build/flag/signature step is required before UI testing.
- Independent QA reported full Swift suite: 299 tests, 0 failures, 97.3 s in `/tmp/codex-director-ui-quality`; focused fixture suite 3/3. Release build passed in `/tmp/codex-director-ui-quality-release`, with no validation activation flag or `UIValidationSession`/`UIValidationHost` symbols.
- Root independently verified the Debug artifact's Boolean activation flag, isolated bundle ID, Debug validation symbols and `codesign --verify --deep --strict` before launching it.
- `xcodebuild` registers the temporary app with LaunchServices as a normal build-tool side effect. No copy was installed into Applications and no production app was launched.
- Root focused run (18:54): UIValidation 8 + TasksLayout 6 + CapabilitiesLayout 3 = 17 tests, 0 failures.
- Independent QA final-first-snapshot run: 311/311 passed, 90.427 s. Fresh Release build passed in `/tmp/codex-director-ui-quality-final-release`; production ID/name preserved, activation key absent, `strings`/`nm -gU` found no validation symbols, strict signature verified. This predates the second-pass viewport/selection/AX/text-wrapping repairs and is not the final post-change evidence.
- Pure-memory closure storage, generation-guarded reset cancellation/stale errors, unique recovery allocation, failed-allocation cleanup, injected seed operation, and Debug-only activation passed independent static review and deterministic tests.
- Post-second-pass independent QA: focused 49/49 (including UIValidation 8, CapabilitiesLayout 3, CapabilitiesViewModel 15, TasksLayout 6), full 314/314 in 90.408 s; fresh Release `/tmp/codex-director-ui-quality-final3-release` passed with production identity, no validation key/symbols and valid strict signature. Final small Debug-host/AX presentation deltas receive a separate focused/static check; this full run is not a UI-layout assertion.
- Final frozen-source delta QA: `/tmp/codex-director-ui-quality-final4-focused` — 49/49 passed, 0 failures, 0.606 s. Independent static review of final host measurement, single-line timeline metadata, native Review Menu and compact Tasks accessibility found no scoped blockers. The 314-test full run and Release proof precede these final Debug/presentation-only deltas; no additional full/Release run was performed, and they are not described as final-delta builds.
- Root rechecked the final Debug opt-in Boolean, isolated bundle ID, strict signature and build/source ordering before launching its fixed run copy. No production app, real sources, global configuration, or system accessibility settings were changed.

## Remaining release gates

- Spoken VoiceOver primary journey and actual OS accessibility settings.
- Exact 1280×800 and fully visible 1600×1000 viewport acceptance; current environment produced the shorter/partly off-display cases above.
- Complete minimum-width matrix for Review/Usage/Data Status and complete keyboard-only navigation; the compact acceptance above covers the primary inventory/evaluation journey.
- Full appearance matrix across each core surface; pairwise development coverage is not complete release coverage.
- Numeric performance/energy baseline with hardware, build type, measurement method and duration. Stress interaction alone is not a benchmark.
- Future menu-bar, topology and desktop-pet surfaces are outside this change and are not validated here.

## Next action

Complete the remaining manual accessibility/display matrix before declaring release readiness. Do not start Phase 2B solely because the scoped automated checks passed. An optional later UX refinement is clearer empty-list guidance in Capabilities and Tasks; it is not included in this implementation.
