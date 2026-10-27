# Long-line Indexing Repair Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Use the available local execution workflow; unavailable superpowers tools are not required.

**Goal:** Remove repeated scanning of unfinished long JSONL lines without dropping evidence, changing parser meaning or resetting user data.

**Architecture:** Keep the existing streaming reader and incremental coordinator. Track the portion of the pending line already searched for a newline, use bounded byte-range searching, and preserve all existing consumed-offset and bounded-window behavior. No database, source ownership, cache, capability-package or UI contract changes.

**Tech Stack:** Swift, Foundation, existing Darwin byte operations and XCTest; no new dependency.

## Evidence and scope

- The user authorized continuation of the compatibility repair on 2026-10-27.
- Work only in the existing public `codex/capability-change-history-1.6.0` checkout. Preserve all other local work and private-archive checkout. No Git publication.
- Build 39 is no longer in the previously observed directory-open wait: read-only checkpoint and relation comparisons show real forward progress. A fresh matched-dSYM sample now identifies repeated `firstIndex` work inside `JSONLIncrementalReader.takeLineFromPending` as the dominant worker-stack hotspot.
- The current reader searches the entire unfinished line again after each chunk. For a long line this is superlinear work. This evidence changes the immediate repair target; do not attribute it to macOS or assume the earlier directory cause has been established.
- Keep marketing version 1.6.0; increment the verified local artifact to build 40. Parser remains 1.4.2. Previously completed checkpoints remain useful.
- No truncating, skipping, line-size cutoff, source rewriting, role guessing, manual SQL correction, index reset, permission adjustment, configured-root removal or background diagnostic upload.

## Task 1 — Software Engineer: reader algorithm

Owned files: `Sources/DirectorCore/Parsing/JSONLIncrementalReader.swift` and focused parsing tests. One writer; preserve earlier bounded-window repairs.

1. Reproduce excess search work using only synthetic long lines. Use deterministic search-work accounting or a separate optimized benchmark, rather than a noisy absolute-time CI threshold.
2. Add a cursor for the first byte not yet searched for a newline. Search only new bytes; reconcile both consumption and search cursors during compaction. Prefer an existing bounded byte-search primitive over a Swift per-byte generic loop.
3. Preserve exact line text, lossy UTF-8 behavior, line number, byte offset, resume, empty lines, EOF without newline, bounded complete-line endpoints and omitted partial bounded tails.
4. Check cancellation between chunk operations if added; never advance a checkpoint on partial/cancelled work. This is cooperative cancellation, not a timeout guarantee for a blocked filesystem syscall.
5. Test a long line across many chunks, several consecutive long/short lines, compaction before and after a long line, UTF-8 split across chunks, bounded windows and cancellation. Verify search work is linear.
6. Run focused parsing/indexing regressions, record separate RED/GREEN and benchmark evidence, then freeze source for independent review.

## Task 2 — Root: integration and evidence

Owned files: plan, validation ledger, bilingual version notes and existing version metadata. Do not rewrite design contracts or other feature work.

1. Independently confirm exact returned bytes/offsets using synthetic data and compare an optimized before/after reader benchmark.
2. Update build metadata to 40 without changing marketing/parser versions.
3. Run complete `verify.sh`, untracked-inclusive public audit using a disposable index, whitespace checks, universal Release and frozen-source verification.
4. Hand frozen source and evidence to independent read-only Quality Engineer. Passing source gates alone do not prove live replay completed.

## Task 3 — Acceptance and recoverable local deployment

1. Quality Engineer independently reviews algorithm correctness, deterministic complexity evidence, cancellation, bounded reads and neighboring regressions. Return passed or blocked.
2. After passing source/artifact gates, normally quit the app, retain its previous bundle in uniquely named Trash, verify staged replacement and install build 40.
3. Compare installed bundle, signature, architectures/version/hash and prelaunch preservation of folders/evaluations/history/database. Do not clear or manually alter source/index state.
4. Relaunch and verify real forward checkpoint progress and normal source-refresh completion. Distinguish completion, active replay, source race/deferred archives and any remaining I/O wait. Do not claim a general filesystem timeout fix or all historical data corrected.

## Completion evidence

Pending implementation and independent verification. Record actual results in `docs/validation/2026-10-27-long-line-indexing-repair.md`.

## Follow-up — directory enumeration and safe stage diagnosis (build 41)

Build 40 passed source/artifact acceptance and was recoverably installed. Live
sampling again found an interval waiting in `ResourceScanner` root probing
through Foundation directory enumeration/open. The long-line repair does not
explain or resolve this separate wait, and pre-existing checkpoints must not be
misreported as build-40 forward progress.

Software engineering owns the minimal next slice in
`FileSystemClient.productionDirectoryRead`, `ResourceScanner` and Discovery
tests only:

1. Preserve the existing directory-type/symlink checks and size/mtime reader.
2. Replace Foundation enumeration with `open` using directory, no-follow,
   close-on-exec and nonblocking flags, then `fdopendir/readdir/closedir`.
   Preserve hidden/Unicode/reserved-character names and reject incomplete or
   failed enumeration rather than presenting an empty success. Close every
   owned descriptor on each exit. A nonblocking flag is not a guarantee that
   all filesystem/provider operations terminate promptly.
3. Add at most three fixed root-stage log events per scan root: begin,
   probe-end and root-end. Only a fixed phase, fixed root kind and ordinal/total
   may be logged. No raw/stable root ID, name, path, filename, content or error
   payload; no new database, UI or second indexer.
4. Add synthetic regressions for filename fidelity, symlink/type/errno,
   enumeration errors and descriptor lifecycle. Confirm privacy-safe logging
   and adjacent scanner/history behavior, then freeze for independent review.
5. Root updates build to 41, repeats full/audit/universal-build gates, obtains
   independent acceptance, recoverably installs and inspects actual root-stage
   logs plus refresh completion. Never bypass a failed root by deleting it or
   resetting data.

## Follow-up — runtime child-exit completion (build 41 candidate 2)

The first build-41 full run did not finish: a read-only sample identified
`ProcessRuntimeCommandClient` waiting in `Process.waitUntilExit` for minutes
despite the tests' short deadlines. No direct child remained in the owned
XCTest process inventory. The exact active test cannot be proved from buffered
output, so do not invent its identity or call this an assertion failure.
The owned stuck test process was terminated after identity verification; its
original log is retained and is not passing evidence. Build 41 was not installed.

Software engineering may make the smallest completion-notification repair in
`RuntimeCommandClient.swift` and its tests:

1. Register a termination handler before launch and establish its completion
   accounting before a fast child can exit. Remove the unbounded
   `waitUntilExit` queue from the async result path.
2. Resume exactly once, read exit status only after termination, drain/cap
   output as before, discard stderr contents, and preserve truthful timeout
   versus output-cap semantics. A successful early exit cancels its watchdog;
   launch failure must not retain a dangling completion or handler.
3. Retain direct executable/argv launch and existing privacy boundaries. Do
   not add global `waitpid`/SIGCHLD handling, unsafe PID/group termination,
   credentials, shell invocation or a second runtime reader.
4. Validate fast-exit repetition/concurrency, output drain/cap, actual watchdog
   termination and launch failure with bounded synthetic probes. Preserve the
   genuine observed-hang evidence separately from new assertion regressions.
5. Freeze source, rerun full verification/audit/universal Release and independent
   acceptance. Keep build 41 for candidate 2 because it has never been installed;
   preserve candidate-1 logs and do not deploy its artifact.
