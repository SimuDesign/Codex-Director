# Quota history page validation — 2026-11-06

Target: **1.7.1 (47)**. Status: **passed for local delivery and installed**. The evidence limits below remain explicit.

## Approved baseline

- [Page plan and integrated UX/UI contract](../plans/2026-11-06-quota-history-page-1.7.1.md). Product Designer and UI Designer provided independent read-only handoffs before production implementation.
- Preserve the installed, accepted 1.7.0 (46), including selected-range transition deduplication, first-open and captured-session fixes. A recoverable 474-file source snapshot and working-tree patch were captured before the page change.
- Reuse the current public checkout. The private archive and all original capability/session/configuration files are outside writes. No Git publication is authorized.

## Verification matrix

| Area | Required evidence |
| --- | --- |
| Navigation | Eight routes in order; sidebar and Home shortcut open the same main page; no quota-history Sheet, Close action, modal width or Escape-to-Home behavior |
| Scope | Explicit stable raw source selection; initial no-source versus removed source; no automatic first-source mixing; current and historical values use the page's same source |
| Lifecycle | One read on activation; captured-session cancellation on leaving; rapid reentry, stale callbacks/results and two-window state; no hidden index-triggered history reads |
| Existing history | Remembered 7/30/60 days; source-local date and window scroll state; zero-SQL range/pagination changes; selected-range counts; 20-item transition pages; distinct unknown/zero/empty/error/stale states |
| Presentation | Standard title/icon/gutters, source before current, responsive current blocks, full-width chart, virtualized dates, wrapping metadata and complete control targets |
| Runtime | Synthetic zh/en × Light/Dark at 720×480, 1280×800 and wide viewports; AX semantics, source menu, navigation, scroll, inline details and keyboard behavior |
| Gates | Focused tests, complete verify, public current-tree/history audit, normal universal Release, independent Quality Engineer acceptance, recoverable install and retained-data hashes |

## Evidence boundaries

- Do not alter system accessibility settings. The user's prior refusal of those changes and accepted unverified actual VoiceOver/physical-input 100 ms measurements remain in force; do not claim these checks passed.
- CUA round-trip duration is not a UI latency measurement. No repeated million-row benchmark is required if Core/query inputs remain identical to the accepted 1.7.0 benchmark.
- Use synthetic data for visual evidence; do not publish production screenshots, account values, paths, capabilities or database files.
- Root owns metadata/documents and deployment; Frontend Developer owns production presentation and relevant tests; Quality Engineer remains read-only and independent.

## Results

- Final presentation inputs are frozen. Thirty files differ from the accepted 1.7.0 baseline; no `DirectorCore` source changed. The initial opaque-view compile error, stale navigation callbacks, uninitialized-source selection and invalid outer scroll-target topology were corrected before these final gates.
- Focused quota-history checks passed with an opt-in heavy benchmark skipped; `UIValidationTests` passed all 21 checks. The full-suite totals below are authoritative.
- Complete `./scripts/verify.sh`: **1,376 tests, four expected opt-in skips, zero failures**; the remaining build checks completed successfully.
- Public audit of the current tree, untracked deliverables and complete public history passed using a disposable index; the real staging area was not changed. `git diff --check` passed.
- Normal Release: **1.7.1 (47)**, macOS 26, `arm64` + `x86_64`, ad-hoc signature verified. Executable SHA-256: `0430dc8ebf0cfd93b99aa2645380d70a0fd384ff1f23f6eea315c4716bbe3954`.
- Separate synthetic Debug application built and signed successfully. Its staged debug library matched the fresh build: `cd6a83b0ef4a524092f8c1911cf4d66280f3d04d537ddc33f589ada6c74c84da`.
- Root runtime check: eight sidebar entries; first history activation chooses the same initial source as Home; synthetic current weekly/five-hour values remain 40%/75% and history coverage remains 6/30 observed, 3/30 calculable. Both sidebar and Home link open the same main-window page without a Sheet.
- Root runtime scroll regression: leaving at scrollbar fraction 0.723194 and returning via the Home shortcut restored 0.724673 at the stable day target. The previous candidate incorrectly returned to 0.0. This is target-based restoration, not a guarantee of identical pixel offset after lazy layout.
- Root additionally exercised 60 → 7-day switching (6 observed / 3 calculable in either selected period), inline day details and explicit source A → B selection. B showed an expired weekly allowance and unknown five-hour allowance with 1 observed / 0 calculable days, without relabeling A's values as B.
- Synthetic visual inspection covered zh/en × Light/Dark at 720-wide and 1280-wide layouts. The Host reported actual **720 × 480** product content in compact mode, **1280 × 734** with controls and **1280 × 748** in the observed capture-mode run. The 1280 × 800 menu item is a requested window size; this record does **not** claim exact 1280 × 800 product-content coverage. Full 1600-wide visual coverage was limited by the display. The source/help text, standard heading, current allowance, stacked compact layout, period controls and scrollable date records were inspected without a new clipping defect.
- UI Designer accepted a P3 source-field deviation: the leading column remains capped at 360 pt even in compact mode. Runtime inspection confirmed the selected text, help and control targets remained usable; no width-only change was required.
- Automated Escape input did not navigate away, but could not reliably exit the debug capture overlay. Physical keyboard behavior, actual VoiceOver and physical-input 100 ms timing remain **unverified**; no OS accessibility preferences were changed. The debug capture overlay is separate from the production page and no production Escape navigation handler was introduced.
- Independent Quality Engineer final decision: **passed**. The reviewer independently checked navigation/session/source lifecycle, controller and projection logic, SQLite query boundaries, tests and the recorded runtime evidence. The reviewer did not modify source or issue its own production changes.
- Recoverable installation completed. The installed bundle exactly matched the verified Release artifact, including SHA-256, universal architectures and signature. The previous 1.7.0 (46) was moved to a unique recoverable Trash location before replacement.
- With the old application normally quit, before/after-install hashes matched for the independent history period, capability folders, evaluations, classification preferences, database/WAL and capability-change history. The comparison occurred **before relaunch**, separating deployment preservation from normal runtime refresh writes.
- Installed-app runtime confirmed eight sidebar entries, a standard main-window history page, source picker, current allowance and loaded historical records. The user's remembered 60-day period remained selected. Home's shortcut returned to that same page without a quota Sheet. No production screenshot or account/path value was saved to the repository.
- No Git staging, commit, remote push, PR, Tag or Release was performed.

Scroll identity restoration follows Apple's [scrollPosition(id:anchor:) documentation](https://developer.apple.com/documentation/swiftui/view/scrollposition(id:anchor:)), with separate header and lazy day target layouts and actual leave/return verification.
