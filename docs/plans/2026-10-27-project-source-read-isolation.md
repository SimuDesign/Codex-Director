# Project Source Read Isolation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Use the installed local workflow; unavailable superpowers tools are not required.

**Goal:** An unresponsive configured project must not prevent other available sources, sessions and quota from refreshing; keep its last verified data and qualify its availability.

**Architecture:** One persistent, in-memory project-read gate bounds complete single-project read jobs, including discovery, physical-path mapping and companion parsing. It limits the caller's wait and the number of actual outstanding workers, not the lifetime of a blocked kernel call. Existing read-only filesystem, indexer, shared refresh, cached startup and retention remain authoritative.

**Tech Stack:** Swift, existing Foundation/Dispatch locks and semaphores, XCTest; no new dependency, process, database or schema.

## Authority, evidence and exclusions

- Accepted technical repair within the user's continued data-accuracy/nonblocking-refresh authorization. Product Architect supplied the boundary; Software Engineer owns production code; Quality Engineer independently accepts it.
- Public checkout `codex/capability-change-history-1.6.0` only. Retain all unrelated dirty work, private archive, source configuration, folder members, evaluations and history. No Git publication.
- Keep marketing 1.6.0, increment installed build 41 to 42. Keep parser 1.4.2, SQLite v6, cache v1, history v1 and package manifest v1.
- Build 41 passed full 1,280-test/source/artifact gates but real fixed-stage diagnostics localized a project-root open wait after earlier roots completed. A matching independent CLI open also waited; metadata was readable. No evidence establishes TCC, File Provider or a permission cause.
- Do not remove a configured project, grant permissions, guess empty data, change timestamps, infer attribution or install a second indexer. The isolation does not guarantee deadlines for every global/session/provider operation.

## Decision and trade-offs

Use at most two actual outstanding project workers and a two-second consumer deadline. A timed-out thread may remain in the kernel until the read returns; the gate holds its slot and root identity throughout. Saturation returns busy immediately. Global/runtime/session paths are not routed through project slots. This deliberately favors available data and cached unknown projects over unbounded threads or falsely fresh empty projects.

Reject helper-process IPC and permanent exclusions: neither is required for the observed failure, and both introduce avoidable operational or source-choice changes.

## Task 1 — Software Engineer: bounded gate

Files: new `Sources/DirectorCore/Discovery/ProjectSourceReadGate.swift` and focused Core tests.

1. Provide a Sendable gate with a test-injectable deadline/capacity and a typed result distinguishing timeout, busy and cancellation. Keep actual source identity only in memory; log no paths, IDs, names or payloads.
2. Admission uses short locks and a lexical standardized URL key independent of root ID; do not resolve symlinks or perform filesystem I/O during admission. Same-path jobs, even with different IDs, and capacity exhaustion return busy without queueing or creating a task. Capture an absolute monotonic deadline at admission and check it at worker completion as well as the deadline callback; delayed timer scheduling cannot admit a late success.
3. Accepted workers return immutable Sendable values only; they cannot hold database/UI/history writers. A timeout/cancellation abandons the consumer result but does not release the active root/slot.
4. Only actual worker completion releases the slot, exactly once. Discard abandoned success/failure payloads; never reuse them as a subsequent fresh observation. An asynchronous continuation and cancellation handler are permitted to avoid blocking the actor; retain the old synchronous scanner compatibility entry and add an asynchronous isolated production entry. Never bridge async work back through a blocking semaphore or TaskGroup waiting forever for an uncancellable operation.

## Task 2 — Software Engineer: project read boundaries

Files: `ResourceScanner.swift`, `IndexingCoordinator.swift`, adjacent Discovery/Indexing tests. Change grouping only if the existing resolver cannot support the prescribed roots partition; report before expanding AppContainer/persistence.

1. Factor the scanner's single-root work into a private immutable result. Keep project probe, identity, verified documents/registry, fingerprint and final validation inside one gated project job. Preserve original root order/deduplication; global/plugin roots retain their existing route. Never share writable arrays/seen sets with a late worker.
2. Inject the same long-lived gate across scan passes and coordinator phases. On failed scan return an unavailable project scope, no fresh history observations, one fixed safe issue and project unavailable. Reuse incomplete-scope retention for resources, fingerprints, last-seen time, provenance and relations. A complete real empty scan still replaces normally.
3. Partition companion parsing: one global/runtime pass with project roots excluded, then one gated pass per complete successful project with full current candidate resources, that single root, empty transient roots and current pairings. Never reopen failed project registries or Briefs outside the gate.
4. Companion-only failure retains prior relations only while both endpoints remain in the final inventory; it cannot revive a resource reliably deleted by complete inventory. Record a safe issue, unavailable project and at-least-partial result coverage; preserve the already verified raw history batch.
5. Compute each project's runtime canonical physical-path tuples inside the same gate. Never substitute lexical paths for failed physical identity. If any configured project scope is incomplete or a project candidate's physical identity is unavailable, defer generic cross-project/global physical alias de-duplication and qualify coverage. Companion-only failure does not revoke already verified physical identity. Retain original IDs for unproved aliases; no arbitrary source priority.
6. Preserve a separately proved closed plugin namespace: require one configured native plugin root, no issues for that root in this scan, fresh native/runtime plugin parents and Skills of the expected scope/ownership, exact current parent-to-Skill `contains` relations, a fresh validated runtime package root, equal resolved package directories and equal manifest paths inside them, and exactly one runtime parent registration and one native target ID per package/manifest. Do not use names, marketplace labels, missing origin identifiers or stale relations as proof. A project's separate configuration instance is neither the alias target nor a competing plugin-package registration. Reject malformed/stale/no-transient, cross-package, multi-parent and multi-target cases. This avoids duplicating proved same-package aliases merely because an unrelated old project is unavailable.
7. Existing ID-based entry counts must not be described as fully physically deduplicated when broader mapping is deferred. Do not conflate canonical uncertainty with plugin-list API failure or independent-installed counts; no new UI or cache schema is introduced.
8. Check cancellation immediately after discovery, after runtime/companion phases and before inventory/history publication. Late workers have no publication path. Keep the existing shared coordinator, epoch and transactions. Exclude known unavailable project roots from MissingSourceRule's review context; retain applicable previous derived missing-source findings rather than declaring unknown sources repaired, while keeping all resources/sessions and manual decisions/evaluations.

## Task 3 — Synthetic acceptance

- Controlled blocked reads at probe, directory identity, document/registry read, final validation, physical mapping and companion parsing.
- One root stays one actual job across repeated scans; two blocked roots occupy two slots; a third returns busy without growth; globals, sessions and quota can still progress.
- Late success/failure cannot change previously returned inventory/history/relations or advance timestamps; real worker release permits a later fresh retry.
- Test cancellation and completion boundary races, duplicate roots, reused IDs with changed URLs, exact once release and no retained queued work.
- Preserve old members/fingerprints/history during unavailable scans; complete empty still removes correctly. Companion failure cannot restore deleted endpoints or erase reliable history.
- Preserve linear JSONL search, bounded parser replay, runtime termination handling, manifest/schema and source-data privacy.

## Task 4 — Root and independent Quality Engineer

1. Root owns build 42 metadata, bilingual notes, architecture and validation ledger. Freeze source after focused tests.
2. Run full `verify.sh`, untracked-inclusive public audit through a disposable index, source hash check and universal Release.
3. Independent Quality Engineer reviews worker bounds, retention, cancellation, late-result isolation, focused/full evidence and artifact. Installation requires passing gates.
4. Normally quit, preserve the previous App in Trash, verify/stage/install build 42, compare user-state preservation and relaunch.
5. Confirm actual refresh completion, fresh metadata/relationship marker and recent checkpoint progress while unavailable scopes remain qualified. Do not claim that every historical archive or unavailable filesystem source has been repaired.
