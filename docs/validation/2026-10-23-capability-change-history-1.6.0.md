# Capability change history — 1.6.0 validation record

Target: **1.6.0**, internal build **36**, macOS 26+.

Status: **complete; independent quality review passed and the verified local
1.6.0 (36) Release is installed**. User-declined OS accessibility checks remain
explicitly unverified. No commit, push, PR, tag or GitHub Release was performed.

The implementation baseline is public `main` commit `9b42f021853cd11c78d109b9461258be9584eced`.
Tests and runtime fixtures must be synthetic. No production history, source
capability body, database, account or session is used as validation material.
This local iteration does not authorize a commit, push, PR, tag or release.

## Scope and evidence ownership

- The approved [plan](../plans/2026-10-22-capability-change-history-1.6.0.md)
  defines behavior, storage limits and release gates.
- The [UI contract](../design/2026-10-23-capability-history-ui-contract.md)
  defines the local Scheme A presentation, focus and accessibility targets.
- Core and query implementation follows the Software Engineer Brief using
  the user-approved upgraded execution route. Native UI Designer owns the
  local contract; native Frontend Developer implements it. A separate native
  Quality Engineer issued the independent final passing decision on the
  contrast-corrected source and Release artifact. After the core execution
  agent reached its usage limit, the user explicitly authorized root to finish
  integration and verification; this was not a native Software Engineer dispatch.
- Historical Task 1 results below are not evidence for subsequently edited
  source. Final whole-tree tests must be run after integration.

## Requirements and current evidence

| Gate | Evidence / state |
| --- | --- |
| Verified observation, scope completeness, stable identity | Passed focused suites and final 1,200-test regression; independent source review passed. |
| Baseline, changes, two-scan absence, rediscovery, clock and retention | Passed detector/coordinator tests, including partial and failed observations. |
| Bounded store, atomic failure, cross-process exclusion, corruption and clear epochs | Passed store/fault tests; malformed and duplicate document arrays fail safely. |
| Single refresh chain, inventory-commit boundary, later parse failure isolation | Passed integration; history publishes before later session inventory, and clear cannot be resurrected by late completion. |
| Half-open intervals, current-rating call identity, aggregate SQL and bounded batches | Passed query and UI-model regressions; summaries distinguish unknown, zero and partial coverage. |
| Lazy history Sheet, closed detail, paging, missing capability and confirmed clear | Passed automated and native synthetic checks, including retained rows after a real page-read failure and 20-to-40-row paging. |
| Existing folders, evaluations, parser/schema/cache/manifest compatibility | Final regression passed; installed folder-preference digest unchanged before/after replacement. |
| Language, appearance, compact/wide, long text, error and retained rows | Eight zh/en × Light/Dark × compact/wide combinations checked; actual measured geometry and capture limits recorded below. Final warning text corrected and visually rechecked. |
| Keyboard, Escape hierarchy and focus restoration | Native Escape and exact launch-control AX focus restoration passed. Full keyboard activation remains unverified by user choice; no global key interception or OS setting change. |
| Native AX structure | Inspected on synthetic runtime; not a VoiceOver speech claim. |
| Actual VoiceOver speech | Unverified: user explicitly declined changing system settings. |
| Increase Contrast, Reduce Motion, Reduce Transparency | Controlled OS-mode matrix unverified by user choice; source/contract checks do not replace runtime evidence. |
| 2,000 capabilities, 20,000 events, size budget, ordinary-tab history I/O | 7,556,116 bytes, bounded paging, off-main persistence and lazy-navigation tests passed. Matched Release marker comparisons and the separate approximately 2.5-second full-scan overhead are recorded below; no input-to-paint or universal smoothness claim. |
| Full verify, public current/history audit plus untracked files | Final verify: 1,200 tests including three opt-in skips, zero failures. Version 11/11, audit 15/15, release 18/18 and performance 46/46 fixtures passed. Untracked-inclusive disposable-index public audit passed; real staging empty. |
| Universal Release, ad-hoc signature, version, bundle identity and hash | Passed: 1.6.0 (36), macOS 26+, arm64 + x86_64, expected bundle ID, ad-hoc hardened signing, matching final executable hash below. |
| Independent quality decision and recoverable local replacement | Final Quality Engineer decision passed with no unresolved P0/P1/P2. Verified replacement installed and relaunched; previous App recoverable in Trash. |

## Baseline performance provenance

An immutable tracked-file archive of baseline commit `9b42f02` was built with
the existing isolated Release interaction harness. The harness uses a distinct
bundle identity, memory preferences and synthetic temporary data. Its build
completed successfully. Baseline measurements completed at both viewports,
20 samples each, using `interactionStress` (500 Agents and 500 Skills).

| Baseline marker, ms | 1280×800 | 720×480 |
| --- | ---: | ---: |
| Longest main-run-loop turn, sample p95 | 539.27 | 353.06 |
| Longest main-run-loop turn, maximum | 573.95 | 364.14 |
| Warm Custom Agents stage, p95 | 669.88 | 517.80 |
| Warm Custom Skills stage, p95 | 800.28 | 522.76 |
| Warm Installed Skills stage, p95 | 206.67 | 171.88 |
| Warm Installed Plugins stage, p95 | 131.24 | 149.60 |

Each run contains one first-entry and nineteen warm-repeat samples; warm p95
uses nearest-rank over those nineteen values. These stress measurements show
existing long turns in 1.5.1, not a claim of already smooth performance. The
candidate must be compared and any new ≥100 ms blocking work attributable to
history investigated. The separate planned history/storage fixture uses
2,000 capabilities and 20,000 events; do not relabel this 1,000-capability UI
baseline as that larger fixture.

Both baseline and candidate interaction-marker measurements must use the same
Mac, fixture, sample count and viewports without concurrent compilation.
The existing harness reports application markers and layout settlement, **not
input-to-paint**. An uncommitted or archive tree is exploratory under its
validator; marker output alone cannot satisfy actual visual interaction,
screen-reader, or independent acceptance gates. Record this limit alongside
results instead of relabeling exploratory data as a clean release candidate.

## Failures and remediation

For native accessibility verification, the macOS 26
[VoiceOver guide](https://support.apple.com/guide/voiceover/use-the-braille-and-caption-panel-unac078/10/mac/26)
documents a caption panel for current VoiceOver speech output. The runtime
check must exercise VoiceOver navigation and announcements on synthetic
content, separately from inspecting the application's AX tree. Caption output
and any acoustic/audio evidence must be described accurately; no microphone
capture, new OS permission grant, or claim of unperformed listening is implied.
Any temporary VoiceOver setting must return to its observed original state.

The first isolated Task 4 compile attempt executed no tests: concurrent core
source had a Date optional-binding error and a callback-signature mismatch and
was still changing. This is a compile failure, not a failed behavior test or
passing query validation. It remains recorded until a stable rerun is complete.

Root integration review identified three additional requirements before final
acceptance: preserve lazy history access when database bootstrap fails; report
unavailable evaluation metadata separately from an empty valid store; and do
not infer which Agent document changed from only a combined hash. The core/query
owners are implementing targeted projections and tests. Filesystem review also
identified symlink/non-regular lock and directory handling that must fail safely
without modifying external sentinel files. These are pending verification, not
resolved findings based only on an author's statement.

After an interrupted execution, the old implementation-agent handles were no
longer live and no compiler process remained. Existing work was retained;
core and frontend completion were redispatched with bounded file ownership,
and independent read-only Quality Engineer review started. No build was
restarted merely because observation timed out. The renewed source review
also found that a selected summary must find the next event for the same
resource across retained history, not a visible filtered row, and that first
absence/partial scans require an explicit safe status projection. Owners are
addressing these before final validation.

The intermediate artifact check found no local capability-history JSON, lock
or interrupted-write file in the source tree. No real staging, commit or
publication was performed by the audit; its index was disposable.

The inclusive procedure (the standalone audit does **not** include untracked
files by default) is reproducible without staging the user's index:

```sh
audit_index_dir=$(mktemp -d /tmp/codex-director-history-audit-index.XXXXXX)
(
  export GIT_INDEX_FILE="$audit_index_dir/index"
  git read-tree HEAD
  git add --intent-to-add --all
  ./scripts/audit-public-release.sh --all
)
git diff --cached --stat
```

The last command was empty in this run. Ignored local history filenames were
also checked separately rather than treating the audit's tracking scope as
proof that no runtime artifact exists.

## First native runtime pass

The isolated Debug validation build succeeded with the distinct Validation
bundle ID and `DirectorUIValidationMode=true`. Fresh/staged debug-library
SHA-256 matched (`88f570dba82ef8f5f1f5cc510a2809b0c383b470cd910a10b6808139581c8e43`).
This is a Debug validation artifact, not the ordinary universal Release.

CUA opened the verified app and inspected its synthetic Representative dataset.
Folder entry and the native history Sheet opened. First pass failed acceptance:
the default thirty-day page showed no expected events and a failed-recording
message; All retained records did show older synthetic events. Core inspection
identified non-hex fixture hash characters being correctly rejected by the
detector. Fixture validity, clock/filter behavior and accurate coverage/error
copy are being remediated; this is not a production-data test.

Mouse selection changed the period to All retained records. Menu choices were
flattened into the containing AX row; Tab and End/Return did not demonstrate
working native keyboard selection. Escape closed the Sheet and preserved the
folder contents, but exact source-focus restoration was not proven. No AX,
VoiceOver, keyboard or visual gate is marked complete by this first pass.

## Core remediation checkpoint

The integrated focused run compiled production modules and test sources, but
was interrupted after a file-store hang. Its captured log contains 91 finished
passing cases and 9 finished failing cases, followed by an incomplete case;
there is no valid whole-run success total. Failures included the descriptor
walk rejecting macOS's trusted temporary-path alias, fixture cleanup and an
incorrect successor expectation. They remain failed evidence until rerun.

After remediation, the Core-only build passed (1.05 seconds, then 5.50 seconds
after bounded overflow guards). Independent read-only source recheck found no
remaining item in its earlier Core P1/P2 list: approved production path,
private file modes, recording-failure retention, partial/invalid coverage,
stable-ID validation, allowlist parity and malformed arrays were addressed in
source. This is **not** behavioral acceptance. Full focused tests, performance,
UI, public audit, universal Release and final independent acceptance remain open.

The independent script rerun confirmed audit fixtures 13/13 and version
fixtures 11/11, both exit 0. It found no new issue in those scripts and verified
that this ledger records the untracked-inclusive procedure and real-index limit.

## Presentation freeze checkpoint

The Frontend Developer completed the presentation source pass. Its focused
`CapabilityHistoryPresentationTests` rerun finished 8/8 with exit 0 (including
the live injected clock, full-history successor lookup, failed neighbor reads,
pending/empty/partial states and valid synthetic fixture). This does not prove
native keyboard, VoiceOver, focus or visual acceptance. Those require a fresh
host build after the integrated source is stable.

The subsequent integrated focused run finished with exit 1: 173 tests,
163 passing and 10 failing (115.441 seconds after a 21.05-second build).
Eight store cases, one storage-performance case and one indexing-retry case
failed with the same file-store descriptor-walk error (`storageUnavailable`).
A targeted reproduction observed `ENOTDIR` at the temporary-path alias.
Remediation is ongoing; the passing presentation suite and earlier source
review do not override these failures.

The root cause was Foundation folding the existing `/private/var` temporary
directory back to `/var` during a second standardization, reintroducing the
system symlink into the no-follow descriptor walk. The fix retains lexical
dot normalization and the two fixed macOS aliases without following arbitrary
source links. Failed-only regression passed 22/22. The subsequent frozen-tree
focused run finished exit 0, **173/173** (133.615 seconds selected-suite wall
time), including the store, coordinator, query, indexing, privacy and UI-model
suites. Log: `/tmp/codex-director/history-core-final-pass.log`.

Its synthetic storage fixture contains 2,000 capabilities and 20,000 events:
7,556,116 persisted bytes; cold read 2,512.41 ms, warm 200-event page 7.42 ms,
atomic no-change update 2,866.21 ms. The I/O probe did not observe persistence
on the main thread. Test-process resident memory changed from 51,888,128 to
111,853,568 bytes; this is not application RSS, peak memory or a Release
interaction acceptance measurement. Native runtime, full verify, audit,
Release and independent final acceptance remain pending.

## Integration and review checkpoints (chronological)

### User-scoped accessibility evidence limit

The user explicitly chose **not** to change system settings and to retain
those checks as unverified. No VoiceOver, full-keyboard-navigation, Increase
Contrast, Reduce Motion or Reduce Transparency preference was changed. Actual
VoiceOver speech and those OS-mode checks are therefore **unverified**, not
passed. Native AX inspection and ordinary pointer/Escape tests remain in
scope. Read-only inspection confirmed VoiceOver off; the utility's caption
panel option was already on. The utility opened for inspection was quit and
System Settings was returned to its previously observed page.

### Second runtime and independent source review

A fresh disposable Debug host build completed exit 0; fresh and staged dylib
hashes matched (`6a2436496ad389980e6e1df735ccc4fa89fcc4f7320fa2300f9756595e8644e4`).
Its default thirty-day timeline contained the expected synthetic events with
no failed-recording banner. Selecting the indexed synthetic Agent produced a
qualified four-call summary with one effective current evaluation. Its real
Open capability detail action dismissed the native Sheet and opened the
existing side detail; the history disclosure initially remained closed and
loaded matching Agent events only after expansion. This diagnostic snapshot
precedes the next remediation and is not final native acceptance.

Independent source review then identified bounded-window future events,
reused detail identity, cancelled-summary reopening, summary/page error
separation, filter-title wrapping, compact date layout and focus-transition
risks. They have been assigned to their respective owners, with targeted
tests and a fresh source/runtime recheck required. The native AX snapshot
still flattened filter and summary containers; it did not demonstrate separate
VoiceOver-operable popup controls. No screen-reader claim follows from it.

### Whole-suite and later remediation checkpoint

The first whole-project `verify.sh` test run completed: 1,197 tests, three
opt-in heavy performance tests skipped, two stale UI source-contract assertions
failed (settings action count and the inserted history disclosure ordering).
Those assertions were updated to cover five settings actions and the explicit
history section; an intermediate focused 54-test UI-contract/model run passed.
Later focus and measured-viewport fixes still require a fresh whole-tree run.

Pointer-opened native filter menus also accepted arrow/Return selection:
Agent filtering removed Skill rows, and the missing-event filter left the
confirmed missing record. Selecting it did not expose usage counts or period
controls. Escape closed the Sheet, but focus landed in folder search instead
of the launching history action. The Frontend Developer changed restoration
to native `onDismiss` with explicit button focus eligibility; this requires
fresh runtime proof. Missing summaries no longer use a post-change call
heading. The Debug capture host now reports measured geometry rather than
labeling a requested size as actual; earlier capture-mode size labels are not
accepted as measured-viewport evidence.

The public audit initially rejected generic system temporary-root constants
used by the safe descriptor traversal. Its normalization now permits only
exact double-quoted system-root literals, never a nested private path. The
expanded 15-fixture audit suite passed; the independent Quality Engineer
reran all 15 and reviewed that narrow boundary. A disposable-index `--all`
audit including untracked source files also passed; the real index stayed
unchanged. No local history file or runtime data was published.

The independent review withdrew an alleged signed-integer reader underflow
after checking the positive limit and 64-KiB buffer bounds; no trap or
reproduction was found. One real P2 remains: publish history mutation/status
immediately after its commit rather than waiting for later session parsing.
The Core execution agent hit its usage limit before that remediation. The
user explicitly authorized root to take over the remaining implementation
and whole-feature verification while retaining independent review. Root added
an awaited, metadata-only notification immediately after the history commit;
the shared model rereads cached current status with lifecycle and clear-
generation guards instead of replaying a potentially stale run result. A new
integration fixture holds later synthetic session enumeration off the main
thread, checks that history is already published, then clears history before
releasing indexing to check for late resurrection. Its regression is pending.

The root remediation focused run passed **55/55**, including the actual
held-session-inventory/clear-race integration test. The final frozen-tree
`./scripts/verify.sh` then finished exit 0: **1,198 tests, three opt-in heavy
benchmarks skipped, zero failures**, followed by a successful Swift build.
Audit/version/release/performance script fixtures passed 15/11/18/46. The
storage stress case again passed with 2,000 capabilities, 20,000 events and
7,556,116 persisted bytes; its current-run cold/warm/update measurements were
1,964.69 / 6.03 / 2,346.04 ms, with persistence off the main thread. RSS remains
test-process only. Logs: `/tmp/codex-director/history-root-remediation-focused.log`
and `/tmp/codex-director/history-full-verify-final.log`.

Independent read-only recheck found no remaining P1/P2 in the immediate-status
remediation or its regression test. Final native runtime, Release interaction
comparison, rebuilt universal artifact and independent overall decision are
still pending; full-test success does not close those gates.

The build-only Release preflight passed the existing bundle verifier:
`1.6.0 (36)`, macOS 26.0, arm64 and x86_64, ad-hoc signature and hardened
runtime. This artifact predates root's final notification remediation and
must be rebuilt; it is not installation or final acceptance evidence.

The independent early source review returned **blocked**. It did not run a
build or behavioral/runtime tests on the moving tree. Required remediation:

- Reject root/broad history directories before any permission change, and
  enforce private permissions for an existing history file.
- Preserve and display failed-recording/budget status across read-only status
  refreshes; do not silently turn it into a healthy state.
- Invalidate open timelines and selected summaries across windows on clear or
  epoch changes.
- Treat the first complete empty scan after a partial seed as the first absence
  confirmation; preserve invalid/no-evidence batch coverage explicitly.
- Validate stable IDs against path/URL forms; reject duplicate malformed public
  arrays without a dictionary-construction trap; match every persisted key to
  the history allowlist.
- Keep baseline-pending and initialized-empty UI copy mutually exclusive.

These findings have been assigned to their implementation owners. A fresh
independent review after remediation and stable final evidence is required.
No new version has been installed by this validation record.

## Final-tree verification checkpoint

The independent final source pass identified two more malformed-input edges:
the public document-byte initializer could precondition-trap, and a persisted
baseline's nested document array accepted duplicate entries. Root changed the
new initializer to fail with `nil` on incomplete/extra/empty bytes and made
the store reject duplicate document arrays. The new file fixture verifies
that rejected bytes remain untouched and cannot issue a write permit.
Focused tests passed **32/32**; the independent reviewer found both P2 items
source-clear. Log: `/tmp/codex-director/history-qe-boundary-remediation.log`.

On that final source tree, `./scripts/verify.sh` completed exit 0: **1,200
tests, three existing opt-in heavy benchmarks skipped, zero failures**,
213.372 seconds, followed by a successful Swift build. The skipped tests are
the existing twenty-sample call-summary/plugin-attribution and quota scale
benchmarks gated by `CODEX_DIRECTOR_RUN_HEAVY_PERF=1`; they were not silently
counted as executed. Log: `/tmp/codex-director/history-acceptance-final-tree.log`.
The storage fixture remains 2,000 capabilities / 20,000 events / 7,556,116
bytes: cold read 2,155.59 ms, warm 200-event page 6.84 ms, atomic update
2,690.56 ms. Persistence was not observed on the main thread. Test-process
RSS was 110,804,992 → 180,518,912 bytes (+69,713,920); this is not app peak RSS.

The rebuilt Debug host has matching fresh/staged dylib SHA-256
`8bba15653a09c586cf45f88123f131a7167ec8df7554bbbf12d9173a72b1039d`.
The rebuilt ordinary universal Release passed the bundle verifier:
`1.6.0 (36)`, macOS 26.0, arm64 + x86_64, ad-hoc hardened signature.
Its executable SHA-256 is
`f292acd1f84822f29acd9f2e8ed15b4c6ea4c19a3c01f94b6bb4ca8ffbd7f92c`.
Logs: `/tmp/codex-director/history-validation-final-tree.log` and
`/tmp/codex-director/history-release-final-tree.log`. These are build results,
not installation or overall acceptance.

Native runtime observed a 1280×800 overall window with 52pt native chrome
and 1280×748 measured product content in capture mode. Normal mode includes
validation controls and was screen-height constrained. Neither requested size
nor whole-window size is relabeled as exact product-content geometry.
Pointer opening plus Return selected the first native menu choice; Last 7
days showed the expected no-match state, and closing/reopening preserved that
window-session filter. The thirty-day synthetic Agent summary showed four
qualified partial/inferred calls and the corresponding current evaluation.
Escape returned AX focus to the exact entry action. Space activation with
system keyboard navigation disabled instead reached the Debug host's first
control; its save panel was cancelled without saving. Full keyboard activation
remains unverified under the user's explicit no-system-settings decision;
no global event interceptor or system preference workaround was added.

Quiet Release interaction comparison, final language/appearance/compact
inspection, independent overall decision and recoverable installation remain
pending. No commit or publication has been performed.

### Quiet Release comparison

The final-tree Release interaction harness completed twenty samples at each
viewport, without concurrent compilation or UI automation. The directory
fixture stays at 1,000 capabilities for baseline comparability; the candidate
also holds 2,000 history capabilities and 20,000 history events. Reports retain
their `exploratory` / `input-to-paint-not-claimed` limits because publication
and a source commit were not authorized.

| Marker p95, ms | 1.5.1 original 1280×800 | 1.6.0 1280×800 | 1.5.1 720×480 | 1.6.0 720×480 |
| --- | ---: | ---: | ---: | ---: |
| Longest main-run-loop turn | 539.27 | 476.19 | 353.06 | 307.14 |
| Warm Custom Agents stage | 669.88 | 531.48 | 517.80 | 428.02 |
| Warm Custom Skills stage | 800.28 | 665.98 | 522.76 | 415.52 |
| Warm Installed Skills stage | 206.67 | 208.00 | 171.88 | 149.10 |
| Warm Installed Plugins stage | 131.24 | 114.31 | 149.60 | 108.89 |

A fresh 1.5.1 wide-window control then measured 454.17 ms main-turn p95,
465.31 ms maximum, and 510.64 / 649.69 / 153.91 / 98.94 ms for the four warm
stages. This variation is retained rather than cherry-picking the slower
original baseline. A repeated candidate run is pending. No claim of an
absolute sub-100-ms UI follows from these existing long stress-fixture turns.
Both completed candidates and all baselines report the same seven identity
and one diagnostics query per sample. The lazy-service regression separately
verifies no history store access for ordinary presentation changes. The
existing NSTableView reentrancy warning occurred forty times in both original
wide runs; it was not introduced by history and is not hidden as a new fix.

The same `time -l` diagnostic wrapper measured maximum resident set size
283,803,648 bytes for the fresh baseline control and 309,362,688 for the wide
candidate (+25,559,040 bytes). This is a process-tree rusage maximum, not a
sampled production-app peak or a private-dataset result. The compact candidate
reported 277,708,800 bytes. Harness setup time includes synthetic history
seeding and must not be presented as application cached-startup latency.

Reports are under `/tmp/codex-director-interaction-perf/` with prefixes
`history-baseline-1.5.1-memory-control-1280x800` and
`history-candidate-1.6.0-final-1280x800` / `history-candidate-1.6.0-final-720x480`.

The repeated wide candidate completed twenty samples: main-turn p95/max
449.23 / 459.34 ms; four warm stages 595.91 / 645.56 / 169.59 / 117.03 ms.
Against the fresh control, changes are −4.94 / −5.98 ms for main turns and
+85.27 / −4.13 / +15.68 / +18.10 ms for the warm stages. These are variable
stress-harness markers, not a proof of universal speedup or input-to-paint.
There was no new ≥100-ms increment in those matched aggregate markers, no
extra counted SQL query, and no ordinary-navigation history-store access in
the regression probe. Existing absolute long turns remain visible above.

An additional standalone Release Core benchmark links the existing baseline
and candidate Core objects to identical read-only scanning code. It creates
2,000 small synthetic SKILL.md documents, scans six times, verifies all 2,000
resources each time, then removes its own disposable fixture. The candidate
also asserts complete coverage and 2,000 verified history observations on all
six scans. Baseline first/warm reads were 2,425.80 / 2,322.81–2,416.14 ms;
the verified candidate was 4,895.67 / 4,833.13–4,950.43 ms. History's verified
document observation adds about 2.5 seconds at this deliberately large scale.
It runs in the existing background scanner, not a tab action; this is an
explicit cost, not hidden as a performance improvement. The standalone
benchmark has no UI, SQLite or history persistence. Its first `time -l`
wrapper exited 1 because the sandbox denied a sysctl used by `time`; direct
baseline and verified-candidate reruns both exited 0. Logs:
`/tmp/codex-director/history-scan-baseline-repeat.log` and
`/tmp/codex-director/history-scan-candidate-verified.log`.

### Final native matrix and states

The final Debug UI was exercised in all eight language/appearance/size
combinations: zh/en × Light/Dark × compact/wide. Safe long names wrap and
Close remains visible. Compact capture measured 720×480 product content and
a 1440×1064 Retina parent image (720×532 logical window including 52pt chrome).
Wide capture measured 1280×748 product content in the 1280×800 logical window.
This records actual constraints rather than claiming an exact 1280×800
product-content viewport. Escape restored the entry's exact AX focus in each
combination; OS keyboard activation and screen-reader checks remain waived/
unverified as described above. System Reduced Motion was already observed on
in the later session; it was not changed or treated as a controlled OS matrix.

Synthetic native state checks demonstrated partial coverage, unavailable read
with Retry, initialized-empty history distinct from baseline pending, and
confirmation Cancel/confirm for clear. After confirmed synthetic clear the
timeline was baseline-pending while folder inventory remained intact.
The read-failure gate was exercised with a **second** page request: changing
the period showed failure + Retry while retaining sixteen prior events.
The earlier file bearing a `triggered` name without the warning was replaced
with the genuinely triggered evidence, not counted as passing retrospectively.
With 20,000 synthetic events, the native global Sheet loaded twenty rows,
then forty after one Load earlier records action; it did not load all history.
A selected history-only resource had a computed-zero recorded-call summary,
not an unindexed/unknown summary; the fixture name does not change that fact.

Evidence is local under `/tmp/codex-director-history-runtime/`: eight
`zh/en-light/dark-720/1280-final` snapshots, `state-partial-final`,
`state-unreadable-final`, `state-retained-failure-triggered-final`,
`state-initialized-empty-final`, `state-cleared-baseline-pending-final`,
and `stress-page1-final` / `stress-page2-final`. CUA sometimes composites
parent/sheet captures with white outer padding; those pixels are a capture
artifact and are not used as product layout or published media. Raw captures
are retained unchanged; no screenshot was retouched or added to Git.

The independent reviewer then caught a Swift 6 Release callback conversion
warning. Frontend Developer made the period callback MainActor-isolated and
used an explicit Binding setter rather than an unsafe function conversion.
Focused UI tests passed 11/11; actual universal Release rebuild succeeded
without that warning. Full-tree tests and a final native summary/derived-index
check are rerunning. Earlier performance probes precede this callback-only
type fix, which does not execute in the measured ordinary-navigation stages.

### Final callback-safe build

`/tmp/codex-director/history-sendability-final-verify.log` completed exit 0:
**1,200 tests, three existing opt-in benchmarks skipped, zero failures**,
200.442 seconds, followed by Swift build success. Its storage stress result
was 7,556,116 bytes, cold/warm/update 2,110.20 / 6.66 / 2,530.82 ms;
test-process RSS 109,559,808 → 177,324,032 bytes (+67,764,224).
`history-sendability-final-release.log` completed exit 0 with arm64 + x86_64,
1.6.0 (36), macOS 26.0 and ad-hoc hardened signing. The period-callback
Sendable/data-race warning is absent in the actual universal Release build.
The final Release executable SHA-256 is
`3e718ad4ee9306fda722f1daa97c650049d5414b4aface893170ee65d5ab7a3b`.
The final Debug fresh/staged dylib hashes match:
`bc4491997691447f8c05ae0d270c3b358d0ed1913f6e40dd8169efd78648de39`.

The fresh callback-safe Debug app displayed the expected qualified four-call
Agent summary. Its real Settings → Delete derived index confirmation was then
used **only on synthetic data**. The index became unindexed, sixteen history
events remained readable, and selecting the same retained Agent displayed
`— · Call data is not indexed` and unavailable evaluation coverage, rather
than computed zero. Evidence:
`/tmp/codex-director-history-runtime/final-build-agent-summary.txt` and
`final-derived-deletion-preserves-history.txt`. The disposable app was quit.
No production index, preferences or history was cleared.

Final untracked-inclusive public audit, independent overall decision and
recoverable installation are the only remaining delivery gates.

### Light warning-ink remediation

The independent reviewer passed the preceding snapshot, but root's final
Light image inspection found systemOrange warning text too faint. An AppKit
process-local Aqua appearance check measured 2.12796:1 against the canvas;
the existing `textSupporting` token measured 7.01861:1. No OS preference was
changed. Frontend Developer separated text/icon color in a private helper
used by all six new history warning surfaces, without changing global tokens.
Focused presentation tests passed 11/11 and the existing visual-contract case
passed with assertions for the shared separated styles. Native Light/Dark
compact and Light partial-coverage captures confirm readable text with the
orange redundant icon. Root inspected the raw images, not only their AX text.
Evidence: `/tmp/codex-director/history-warning-contrast.log` and local
`contrast-zh-light-720-delivery`, `contrast-zh-dark-720-delivery`,
`contrast-partial-light-delivery` captures.

The final Debug fresh/staged dylib hashes match
`9760bfa8b8608950c9319bf67fb9819612cee9f84e7616d7222d2916ee3aa080`.
The color-corrected universal Release verifier passed; executable SHA-256 is
`cdc9cfcce237027faa38373534dd7bfb959d3b4c305ae8c9a02ef606108dac6f`.
Logs: `/tmp/codex-director/history-delivery-release.log` and
`history-delivery-validation.log`. A fresh whole-tree verification and
independent post-remediation decision are required before installation.

## Final acceptance and installed delivery — 2026-10-23

This section supersedes the pending statements and older artifact hashes in
the chronological checkpoints above; those checkpoints remain as an honest
record of failures, remediation and evidence provenance.

- Final whole-tree `./scripts/verify.sh` completed exit 0. XCTest executed
  **1,200 tests, including three existing opt-in benchmark skips, zero
  failures**, in 200.095 seconds, followed by a successful Swift build. The
  skipped large query benchmarks require `CODEX_DIRECTOR_RUN_HEAVY_PERF=1`;
  they were not silently counted as executed. Log:
  `/tmp/codex-director/history-delivery-verify.log`.
- Final storage stress retained 2,000 capabilities / 20,000 events in
  7,556,116 bytes, below 16 MiB. Cold read / warm 200-event page / atomic
  update were 2,049.10 / 6.52 / 2,471.99 ms. The persistence probe observed no
  main-thread file I/O. Test-process RSS was 110,100,480 → 172,081,152 bytes;
  it is not production-app or peak-RSS evidence.
- The final untracked-inclusive current-tree/history audit passed using the
  disposable-index procedure above. Audit fixtures passed 15/15; version,
  release and performance script fixtures passed 11/11, 18/18 and 46/46.
  Source, privacy, license, pinned dependency and media checks passed.
  Actual staging stayed empty; no local history JSON or lock artifact was
  found in the repository. Logs include
  `/tmp/codex-director/history-inclusive-audit-color.log` and the final
  docs-only `history-final-docs-audit.log`.
- The final contrast-corrected universal Release and synthetic Debug build
  succeeded. Installed Release executable SHA-256:
  `cdc9cfcce237027faa38373534dd7bfb959d3b4c305ae8c9a02ef606108dac6f`.
  It is 1.6.0 (36), macOS 26+, arm64 + x86_64, bundle identity
  `com.peiweitang.CodexDirector`, with ad-hoc hardened runtime signing. It
  does not claim Developer ID signing or Apple notarization.
- Independent native Quality Engineer issued **passed**, with no unresolved
  P0/P1/P2, after reviewing final source, focused/full tests, inclusive audit,
  performance limits, fresh contrast-corrected images and Release artifact.
  It then independently passed the installed-artifact consistency check.
- Old production 1.5.1 (35) was quit using the native application UI. The
  installer copied and verified the new App before moving the old bundle to
  a uniquely named recoverable Trash location, then verified the installed
  bundle. Full artifact comparison and strict deep codesign verification
  passed. The installation log remains local at
  `/tmp/codex-director/history-installation.log`; its personal backup path is
  not copied into public documentation.
- CUA relaunched the exact installed App and verified Settings displays
  `1.6.0`, the folder-entry Change History action opens, first-use state is
  baseline-pending, and Escape closes the Sheet. The first normal refresh
  will establish a baseline; historical changes are not fabricated.
  The before/after digest of existing production folder preferences matched;
  no production index, history or preferences were cleared. No production
  screenshot, capability body, database or session was saved as test material.
- A read-only post-install `pgrep` attempt was denied access to the process
  list by the sandbox. It is not counted as a successful check; native CUA
  launch and interaction supply the runtime evidence instead.

Residual evidence limits are intentional and visible: actual VoiceOver
speech, full keyboard activation and the controlled OS accessibility-mode
matrix remain **unverified at the user's request**. No system setting was
changed. The stress suite still shows existing long navigation turns; its
markers are not input-to-paint measurements. The 2,000-file scanner benchmark
adds approximately 2.5 seconds of background full-scan work; that cost is not
a Tab action, and is not hidden by the faster warm paging measurements.
No commit, push, PR, tag or GitHub Release was performed for this iteration.
