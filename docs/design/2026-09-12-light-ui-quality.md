# Light UI optimization · independent quality review

**Decision: passed** for the authorized review scope 01–08.

I reviewed the frozen `ui-optimization` source, the updated design contracts,
the recorded test/build logs, and the isolated Debug Validation Host. The
review was limited to the eight approved high/medium issues; item 09 remains
outside scope.

## Evidence

- Focused UI run recorded 35 passed tests. The full verification record in
  [runtime evidence README](evidence/2026-09-12-light-optimization/README.md)
  reports 660 executed, 3 skipped and 0 failed; Release build and bundle
  identity checks also passed. I reviewed these records rather than rerunning
  a competing broad build.
- The candidate was the isolated
  `.build/ui-optimization-validation/Build/Products/Debug/Codex Director Validation.app`
  with the recorded SHA-256 and Stress fixture. The installed 1.3.0 (25)
  application was left untouched while the branch remained 0.3.1 (16).
- Final source screenshots are linked from the evidence README:
  [Light library](evidence/2026-09-12-light-optimization/light-agent-1280x800.png),
  [Light selection detail](evidence/2026-09-12-light-optimization/light-agent-selection-detail-1280x800.png),
  [Light evidence expanded](evidence/2026-09-12-light-optimization/light-agent-evidence-expanded-1280x800.png),
  and [Dark stress/loading](evidence/2026-09-12-light-optimization/dark-stress-refresh-loading-1280x748.png).
- Fresh independent AX excerpts are in
  [qa-ax-snapshots.md](evidence/2026-09-12-light-optimization/qa-ax-snapshots.md).

## Acceptance review

1. **Selected capability row — passed.** Light and Dark pointer/keyboard
   selection opened the detail sheet with readable title, summary and
   metadata. The row-level `NSTableRowView` adapter left the enclosing table's
   selection style unchanged; the runtime selection wash and boundary stayed
   within the group row while the list retained AX selection and arrow-key
   behavior. Stress scrolling and a later keyboard selection completed without
   the earlier outline reconstruction crash.
2. **Supporting metadata — passed.** Source, scope, state, dates, inferred
   markers and call units use `textSupporting`/`dataText`; resolved-color tests
   cover Light/Dark canvas and panel surfaces. The values were legible in the
   four-category fixture, including unavailable plugin attribution.
3. **Light action text — passed.** The action role is separated from brand,
   chart and navigation gradients. Light normal/hover/pressed/disabled rails
   use opaque darker stops with white content; Dark keeps the bright rail with
   black content. Tests sample every interpolated rail segment, and the
   runtime Light loading action showed readable white text and spinner.
4. **Sidebar selection — passed.** Light and Dark showed one navigation
   gradient, with a monochrome symbol and label using the same black
   navigation foreground. AX retained the selected destination. The focused
   border is separately represented in source; a full VoiceOver/focus matrix
   was not run.
5. **Refresh control — passed.** Idle/loading use one 14pt symbol/progress
   slot, small native progress, localized labels and a stable shared style.
   Settings Light idle/loading and Dark loading showed the refresh and adjacent
   delete actions aligned at the same visible outer height; AX exposed the
   loading/disabled state.
6. **Filter layout — passed.** At Light English 720×480, Installed Plugins,
   search occupied a full row and the three current selector values occupied
   the next row. At Light Chinese 1280 and Light English 1600, the filters
   stayed in a single row. The AX-reported viewport was recorded separately
   from the physically constrained 1600 capture height.
7. **Evidence toggle geometry — passed.** In Light and Dark detail sheets,
   activating the evidence action changed only its label and primary/secondary
   emphasis. AX changed `View usage evidence` to `Hide usage evidence`, and
   the screenshots show the same full-width control geometry.
8. **Small data text — passed.** Ranking ordinals and chart percentage
   annotations consume the dedicated `dataText` role; resolved-color tests
   cover actual dynamic canvas/panel surfaces in both appearances.

## Coverage limits

This decision does not claim actual VoiceOver speech, Increase Contrast,
Reduce Transparency or Reduce Motion coverage; those were not exercised in
the independent run and remain explicit matrix gaps. Hover/pressed appearance
was covered by the resolved-color sampling tests, not by a held-pointer
screenshot. The validation host's explicit Appearance menu can override the
visual theme while its in-memory Settings theme store retains its own value;
this is a harness behavior and was not treated as a production defect.

No P1/P2 finding remained for issues 01–08 at source freeze.
