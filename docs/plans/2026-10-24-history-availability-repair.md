# History Availability Repair Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Use the available local workflow; unavailable superpowers tools are not required.

**Goal:** Separate readable empty history, incomplete source coverage and real history-read failures without deleting retained data.

**Architecture:** Preserve per-source safety and the independent history store. Correct cross-source coverage aggregation and the shared presentation adapter, with an explicit nonpersisted save-failure signal from the existing coordinator; no schema, parser, history-format, cache or manifest migration. Existing files reporting unavailable source coverage remain readable and receive an accurate source-scan notice without inferring that their latest scan was partial.

**Tech Stack:** Existing Swift 6, Foundation, SwiftUI, XCTest and Scheme A; no new dependencies.

## Authority and constraints

- User approved the diagnosed repair on 2026-10-24. Use the existing public `codex/capability-change-history-1.6.0` branch and preserve all prior uncommitted feature work.
- Keep marketing version 1.6.0; increment the internal build from 36 to 37 for the verified replacement. No commit, push, PR, tag or Release is authorized.
- Production metadata established that baseline data is readable with no recorded events, while aggregate source coverage is unavailable. Do not copy personal paths, capability content or production history into tests or docs.
- Never clear history, remove configured projects, alter source capabilities or convert an inaccessible source into complete-empty evidence.
- Existing Scheme A, shared refresh and lazy history reads remain the approved contract. Real VoiceOver/full-keyboard/OS accessibility-mode tests remain unverified per the user's earlier choice; do not change system settings.

## Approved state contract

| Situation | Presentation and recovery |
| --- | --- |
| Readable, not initialized | Waiting for a baseline; next normal refresh establishes it. |
| Readable, initialized, no events | No changes recorded yet. Zero events never implies read failure. |
| Some scopes readable, others unavailable | Partial source coverage; retained history remains viewable. No unavailable-history warning. |
| Latest source coverage unavailable (including legacy state) | Source scan did not complete; retained history remains viewable. Do not claim a successful latest scan or infer missing changes. |
| Writer conflict / read-only instance | Explicit read-only recording notice, not unreadable history. Retained rows and truthful empty state remain usable. |
| Latest write failed but history remains readable | Latest observation could not be saved; retain prior rows and distinguish this from read failure. |
| Actual page/status read failed, corrupt or unsupported | Appropriate localized error + read-only Retry; do not simultaneously claim no records or pending baseline. Retain any previously valid rows. |

Source-coverage/recording notices must not offer a misleading read-only Retry as a scan repair. Explain use of the existing Refresh data action where applicable; no new scan-on-open, timer or coordinator.

### Read/write provenance clarification after independent review

The existing `storageUnavailable` diagnostic can originate from a failed save
as well as a failed read. A successful retained page alone must not silently
relabel an error's origin. Add `latestObservationSaveFailed: Bool = false` to
the non-Codable `CapabilityHistoryStatus`, populated by the existing actor's
actual failed-save path and preserved alongside pending submission issues.
Successful submission and confirmed clear reset it. This is volatile status,
not a new history JSON field or issue-code migration. Actual page-read errors,
corruption and unsupported versions still take precedence in presentation.
Regression tests must exercise generic/injected save failure, not only budget
failure, and verify readable retained rows, subsequent recovery and flag reset.
Do not claim Refresh data can acquire a read-only instance's lifetime writer
lease; show its recording limitation without a misleading recovery promise.

## Task 1 — Software Engineer: cross-source coverage

Files: `CapabilityHistoryObservation.swift`, `CapabilityChangeDetector.swift` and adjacent discovery/domain/indexing tests.

1. Add failing synthetic cases for complete + unavailable, partial + unavailable, all unavailable, no scopes, unstable, complete-empty, and unavailable scopes not producing missing events.
2. Introduce one pure cross-source aggregate rule: no usable scope means unavailable; mixed usable/unavailable means partial; preserve unstable and partial qualifications. Keep the same-source `dominating(with:)` rule conservative.
3. Apply the same aggregate to batch and persisted latest coverage. Never change per-scope missing-confirmation rules or auto-rewrite existing history on read.
4. Run focused detector/observation/coordinator tests and record results.

## Task 2 — Frontend Developer: distinct presentation states

Files: `CapabilityHistoryPresentation.swift`, bilingual resources, focused presentation tests and synthetic validation fixtures only.

1. Add failing tests for readable initialized-empty + mixed coverage, legacy unavailable scan coverage, real unreadable history, read-only history and recording failure with retained rows.
2. Centralize the warning/empty/retry predicates so the global Sheet and detail disclosure share identical semantics. Storage access, latest scan coverage and the existence of events are independent dimensions.
3. Reuse existing typography, readable warning ink, redundant icon and controls. Add short bilingual source/read-only explanations; do not expose paths/errors or invent scope counts.
4. Provide synthetic runtime fixtures for empty mixed coverage and true unreadable state, using the existing validation host. No production data or preference writes.
5. Verify focused tests, labels, retained rows, Retry semantics and absence of new source reads.

## Task 3 — Root integration and independent Quality Engineer

1. Run focused tests first and then `./scripts/verify.sh`; keep failure and rerun evidence separate.
2. Run the public current/history audit with a disposable Git index including untracked files; leave real staging empty. Scan ignored history artifacts separately.
3. Build and verify universal 1.6.0 (37) Release and isolated synthetic validation app.
4. Exercise affected Sheet/detail states in zh/en, Light/Dark, compact/wide; inspect native AX, Escape and actual warning text. Do not infer screen-reader results from AX.
5. Independent Quality Engineer reviews source, tests and runtime/build evidence read-only. Remedy any blocking findings and rerun affected checks.
6. Only after passed review, quit the old App, move it to a unique recoverable Trash location, install and verify the new artifact, relaunch and perform a proportional smoke check. Preserve existing folders/history/evaluations.
7. Update changelogs, local UI state contract and validation record. No publication.

## Completion evidence

Implemented and independently accepted; recoverably installed as 1.6.0 (37).
The [validation record](../validation/2026-10-24-history-availability-repair.md)
contains focused/full tests, audit, native synthetic checks, build hashes and
installed-runtime evidence. Existing history and folder preferences were
preserved. Actual VoiceOver/full-keyboard and controlled OS accessibility-mode
checks remain unverified at the user's prior request. No Git publication.
