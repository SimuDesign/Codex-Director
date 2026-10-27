# History availability repair — 1.6.0 (37)

Status: **implemented, independently accepted and installed locally as 1.6.0 (37)**.

The user authorized the bounded repair in the
[implementation plan](../plans/2026-10-24-history-availability-repair.md).
Keep the existing uncommitted 1.6 work, history schema v1, parser, SQLite,
cache and capability-package contracts. No publication is authorized.

## Diagnosis and preservation boundary

The history document was readable and initialized, with no recorded events,
but its latest source-scan coverage was unavailable. Aggregate-only local
diagnostics found missing configured project directories. Source inspection
confirmed that any unavailable source dominated the whole scan, and the UI
mapped source coverage to a history-read failure while separately rendering
empty content. No production document bodies, history records, database,
credentials or screenshots are included in this validation record or fixtures.

Actual empty history is not a storage-read failure. The earlier diagnostic
test attempt used the wrong default SwiftPM scratch directory: sandbox/cache
errors and zero executed tests are **not** passing evidence. Rerunning the
two existing presentation tests against the isolated established scratch
directory completed 2/2, zero failures. This diagnosis is distinct from the
repair regression evidence below.

## Ownership and focused verification

- Native Software Engineer owns the pure cross-source coverage helper,
  detector use and Core regression tests. Native Frontend Developer owns
  presentation predicates, bilingual state copy and synthetic fixtures.
  Root owns integration, current build metadata, documentation, native runtime
  checks and recoverable replacement. Independent native Quality Engineer is
  read-only and does not accept its own implementation.
- Core author's RED run selected 34 cases and reproduced five expected
  failures; GREEN selected 34 and passed all with zero failures. The output
  is in the tool transcript, not a saved standalone log. Root's final
  whole-tree run below provides independently inspectable integrated evidence.
- The Core author interrupted the adjacent indexing selection after an
  output-silent interval, exit 130. This is an **incomplete run**, not evidence
  of a hang, a test failure or a pass. Root's read-only process check found no
  leftover xctest/swift-test using the shared scratch directory. Final full
  verification reran and passed this suite rather than inheriting the interruption.
- Version-contract fixtures passed 11/11 and audit-script fixtures passed
  15/15. The current version reader reports 1.6.0 / 37. Those fixtures alone
  do not prove a passing public audit, final build or runtime.

## Review findings and remediation

The first independent review was **blocked**: generic/atomic/injected save
failures reuse `storageUnavailable`, which the first UI repair still treated
as a read failure. Its test covered only file-budget failure. The finding was
accepted before deployment; the repair adds an explicit nonpersisted
coordinator save-failure flag and regression coverage for generic save errors.
No passing decision or installation is inferred from the initial 17/17 UI run.

Core added the non-Codable, default-false status flag. Its initial rerun
compiled Core but did not run the selected tests because a new UI test used
the draft initializer ordering; that compile error is **not** a GREEN pass.
The parent also identified a new test's invalid hex fixture and the need to
guard late failure diagnostics across clear/cancel generations. The native
owners froze their files before a bounded handoff to `gpt-5.6-sol / xhigh`
following the Software Engineer Brief. This upgraded integration executor is
not claimed to be the fixed native Software Engineer preset. Independent
Quality Engineer remains separate and read-only.

The integration repair also guards both sides of the awaited retained-status
read against generation changes. Late failed saves cannot resurrect diagnostics
after clear/cancel. A readable retained store after an invalid-state save is a
recording failure, not a claim that the history document is corrupt.

## Final verification

- Integrated focused suite: **63 tests, zero failures** (observation 12,
  detector 22, coordinator 10, presentation 19), recorded in
  `/tmp/codex-director/history-state-integration-focused.log`. The earlier
  Swift 6 test-capture compile error was fixed before this passing run.
- Full `./scripts/verify.sh`: **1,218 tests total, including 3 existing opt-in
  skips, zero failures**. The final log is
  `/tmp/codex-director/history-state-final-verify-rerun.log`. Version, audit,
  release and performance-script fixtures also passed. The first full run had
  one static UI-contract failure: a consolidated helper now occurred six rather
  than seven times. The assertion was corrected and strengthened to check shared
  Sheet/detail empty/Retry predicates; the complete rerun passed. No production
  source changed after the verified build.
- Untracked-inclusive public current/history audit passed with a disposable
  Git index; the real staging area remained empty. Whitespace checks passed;
  ignored runtime history/lock artifacts were not found in the public tree.
- Universal Release and isolated synthetic Debug builds passed. Release is
  macOS 26+, `arm64` and `x86_64`, bundle identity
  `com.peiweitang.CodexDirector`, ad-hoc signed. Dependency/license, privacy,
  icon, architecture and signature verification passed. It is not notarized.
- Final Release executable SHA-256:
  `c3dfc7626c780eaf56e676fe316285af23bd74abd964683e2296822ee3810a76`.
  Debug validation dylib SHA-256:
  `367ef5d1ee22d149ec5781a69090e1402be1fe3893539f52286f64321f403ba1`.

## Native synthetic runtime

Raw local screenshots and AX observations are retained under
`/tmp/codex-director-history-state-runtime/`; none contain production data and
none are published. Mixed-empty history was exercised in all eight combinations
of zh/en, Light/Dark and compact/wide. Compact product size was measured at
720×480. The wide outer window was 1280×800, with product content 1280×748;
this is not a claim of exact 1280×800 product-content coverage.

- Readable mixed-empty and legacy-unavailable source coverage showed accurate
  coverage/scan notices plus normal empty content, without a read-error Retry.
  Native Agent and Skill detail disclosures were checked as well as the Sheet.
- True unreadable history showed its error and working Retry, never a normal
  empty/baseline claim. Both Sheet and detail were exercised. The Sheet's AX
  tree exposes Retry as a selectable row; the native visual action was verified
  rather than inferred absent from its AX role.
- A successful first page followed by an actual injected second-page failure
  retained the same 16 synthetic event rows. Retrying kept those valid rows and
  the truthful read error; it did not claim the failed filter result succeeded.
- Copy remained readable and Close was visible. Escape closed the history
  Sheet. Read-only and failed-save classifications and generation races are
  covered by automated tests, not claimed as additional runtime matrix cases.
- Independent read-only Quality Engineer accepted the corrected source,
  regression results, builds and synthetic evidence before installation.

## Recoverable installation and real-data smoke check

After normal UI exit, the old build 36 was moved to a uniquely named recoverable
Trash bundle. Build 37 was verified in sibling staging before replacement, with
rollback guards. Installed bundle contents matched the Release artifact;
signature, identity, version, both architectures and executable hash matched.
Installation log: `/tmp/codex-director/history-state-installation.log`.

Before relaunch, SHA-256 digests of the existing history file and folder
preferences matched their pre-install values exactly. No history was cleared,
no folder members were changed, and no source/configuration files were edited.
After relaunch, the real history Sheet displayed the incomplete-source notice
and normal no-events state without unavailable-history or read-Retry UI.
Escape returned to the folder page; Settings displayed concise version 1.6.0.
No production screenshot or document body was saved as validation evidence.

Actual VoiceOver speech, full keyboard activation and controlled OS
accessibility-mode checks remain **unverified at the user's prior request**.
No system setting was changed. No history clear, source mutation, project
configuration removal, dependency installation or Git publication is part of
this fix. No commit, push, PR, tag or GitHub Release was created. These checks
do not establish new input-to-paint performance or screen-reader results.
