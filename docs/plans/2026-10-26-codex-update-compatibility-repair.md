# Codex Update Compatibility Repair Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Use the available local workflow; unavailable superpowers tools are not required.

**Goal:** Correct supported structured tool completion states and recognize explicit v5 project-registry companion declarations without clearing user data or inventing attribution.

**Architecture:** Extend the existing transient rollout extractor and bounded recent parser-upgrade policy. Normalize supported registry layouts once for discovery validation and companion resolution while retaining canonical TOML/Skill identities. Keep ordinary indexing read-only, existing transactional persistence, shared refresh, source ownership, history schema v1, SQLite schema v6, presentation-cache v1 and capability-package manifest v1.

**Tech Stack:** Existing Swift 6, Foundation, XCTest and SQLite; no new dependencies or UI design.

## Authority and decisions

- The user approved repairing the two diagnosed compatibility defects on 2026-10-26. Work in the existing public `codex/capability-change-history-1.6.0` checkout; preserve all uncommitted 1.6 work and the private archive checkout.
- Keep marketing version 1.6.0. Build 38 passed source/artifact review and was recoverably installed, but runtime discovery exposed the directory-metadata wait below; increment to build 39 for the additional verified repair. Do not commit, push, open a PR, tag or publish a Release.
- Use current local protocol shapes as evidence, but reproduce them with synthetic fixtures only. Never copy commands, prompts, outputs, thread/account IDs, personal paths or capability content into tests, logs or public documents.
- Chosen approach: repair the existing extractor and registry resolver. Rejected alternatives are a second indexer, manual SQL patches, clearing/rebuilding all history, and inferring a specialist role from unknown child metadata.
- Explicitly out of scope: inventing Agent identity for role-less children; creating new calls from unsupported standalone items; changing menu-bar cadence, quota selection, folder memberships, evaluations, source capabilities/configuration, or unavailable project entries.

## Task 1 — Software engineering: structured completion and recent replay

Owned files: `Sources/DirectorCore/Parsing/InvocationExtractor.swift`, `RolloutEventDecoder.swift`, required adjacent parsing types/tests, the parser-upgrade block of `Sources/DirectorCore/Indexing/IndexingCoordinator.swift` and focused indexing/parser fixtures. Do not edit discovery, grouping, app/UI, version metadata or root-owned documentation.

1. Add synthetic failing regressions for `event_msg/item_completed` CommandExecution and McpToolCall shapes, including failed/completed, nonzero exit, malformed/unknown item types, missing/ambiguous IDs, repeated items and later wrapper output. Do not retain raw error/output content.
2. Correlate using validated item/call identifiers and existing call history; normalize terminal state, bounded duration and safe error category where authoritative. Failure must not be overwritten by a generic output. A completion item updates a known call rather than adding another count. Preserve conservative nested Skill evidence semantics; wrapper success does not prove an internal operation succeeded.
3. Cover incremental append behavior and terminal events after the matching start has already committed. Preserve original calls, parentage and count identity; ensure failure corrections are not lost at a checkpoint boundary. Use existing merge/transaction seams, not direct production SQL.
4. Advance rollout parser to 1.4.2. Add 1.4.1 to the explicit deferred-old-version set: unchanged older archives outside the recent 30-day window remain deferred, recent affected checkpoints reparse transactionally once, changed older files retain normal handling. Test idempotence, cancellation/source races, no uncommitted checkpoint advance, unchanged counts and preserved evaluation metadata.
5. Run focused regressions first (RED then GREEN), save concise separate logs, and hand off frozen code and exact evidence. Escalate any required persistence-interface change before implementing it.

## Task 2 — Software Engineer: supported registry normalization

Owned files: `Sources/DirectorCore/Discovery/ResourceScanner.swift`, `Sources/DirectorCore/Grouping/CapabilityCompanionRelations.swift`, a small shared Core registry-normalization helper if needed, and adjacent discovery/grouping fixtures. Do not edit parsing/indexing, app/UI, version metadata or root-owned documents.

1. Add failing synthetic fixtures for supported legacy entries, packages object/array and v5 `packages` with `kind`, `id`, `nativeAgent`, `usesSkills` and `invokedBy`.
2. Parse and validate supported layouts consistently. A valid supported packages registry must not be reported as invalid merely because it lacks legacy `entries`. Preserve bounded verified reads, UTF-8/size/symlink/source-race protection and truthful unsupported/corrupt coverage.
3. Resolve native Agent identifiers through same-project canonical TOML configurations/validated aliases, and Skills through explicit unique names/IDs. New packages metadata must not manufacture duplicate Agent resources. Preserve historical legacy-entry resource IDs and declaration support rather than silently dropping existing folder references while deduplicating. Do not guess ambiguous names, let a global Agent own a project-only Skill, or convert metadata into source files.
4. Preserve declared relation direction and source. Project-local Skills take priority; unique global Skills may appear as previews. Handle `invokedBy` inversely and deduplicate repeated declarations; do not infer new semantics from unrelated fields such as forwarding or trigger text.
5. Advance the independent relationship projection marker to v3 for one existing source refresh, without introducing another scan or historical-session replay. This is independent from Task 1's parser repair.
6. Run focused registry, resolver and discovery/history regressions (RED then GREEN), keeping preexisting history observations and member IDs unchanged.

### Integration review clarifications

- Supported schema/version validation must be shared, including rejection or
  truthful qualification of unknown, malformed or conflicting version fields.
  An absent legacy version remains compatible; it does not make an explicitly
  unsupported version trusted. Contradictory duplicate package identities
  must not use last-write-wins resolution; reordering must not change meaning.
- Legacy entries retain both resource identity and explicit forward/reverse
  declarations. A v5 repair is not authorization to remove historical resources.
- Existing call records do not persist every raw response/call alias. Append
  handling may recover an alias through a strictly bounded, pending-only source
  lookback. Unresolved or ambiguous evidence must emit a safe partial-coverage
  issue, not claim a successfully corrected call. No schema or raw-alias cache is
  added; unsupported role identity remains unknown.
- Independent review additionally requires same-size/changed-mtime replacement
  to use full transactional reparse, prior session metadata to survive a
  terminal-only append, and exact complete-line alias boundaries to remain
  readable. True growing appends stay incremental; no per-append whole-history
  replay or additional per-file full-session-table query is introduced.
- Contradictory alternate registry fields fail closed. This does not prohibit
  explicitly declared package ID/name/native-Agent aliases that serve distinct
  roles; it prohibits silently choosing between conflicting fields claiming
  the same semantic identity or kind.

## Task 3 — Root integration and independent Quality Engineer

1. Integrate the two frozen branches in the shared checkout; one writer per file. Root owns plan, bilingual version notes, architecture, validation record, README and build metadata.
2. Run focused integration tests and full `./scripts/verify.sh`, then the untracked-inclusive public current/history audit using a disposable Git index. Leave real staging unchanged.
3. Compare the corrected registry projection with local declarations using aggregate-only diagnostics; record no private bodies, identifiers or paths. Compare supported failed items with their parsed status in memory or an isolated disposable database, not by manually editing the live database.
4. Build and verify universal Release 1.6.0 (38), identity, signatures, dependency licenses and hashes. No new visual contract or OS accessibility settings are involved.
5. Independent read-only Quality Engineer reviews final source, no-double-count/append behavior, migration bounds, regression logs, privacy audit and artifact evidence. Remediate blockers through the implementer, not the reviewer.
6. Only after passing, normally quit the installed App, preserve its bundle in uniquely named Trash, stage/verify the replacement and recoverably install. Verify folder preferences, evaluations and independent history are not changed by installation; normal subsequent indexing may legitimately update derived/history observations.
7. Relaunch and inspect normal shared refresh. Recent replay may be substantial: report its real progress and distinguish a verified build from completed live backfill. Never claim all historical rows were repaired while archives are deliberately deferred or replay is still running.

## Completion evidence

The source/artifact repair passed independent acceptance and is installed as
1.6.0 (39). Full verification passed 1,267 total tests including 3 existing
opt-in skips, zero failures. See the matching validation record for exact
boundaries. Live discovery is still waiting in a directory-open syscall before
inventory commit; historical correction is **not complete**. Passing build and
synthetic gates must not be presented as passing live backfill.

## Runtime follow-up — directory type checks

The installed build 38 showed a real source-discovery wait before inventory
commit or historical replay. A short stack sample, symbolicated with the
matching Release dSYM, identified `productionDirectoryRead` calling
`FileManager.attributesOfItem` solely to determine directory type; Foundation
was waiting in `getxattr`. No evidence identifies a particular project or
proves a File Provider cause. No system permission is changed.

Software engineering may replace only the directory type checks in
`FileSystemClient.productionDirectoryRead` / `productionDirectoryStatus` with
the same file's existing basic POSIX metadata/descriptor pattern. Preserve
the methods' respective symlink semantics, typed errors and permission-denied
fail-closed behavior. Do not change file size/mtime calculation: that could
invalidate older checkpoints and defeat bounded replay. Do not refactor
refresh scheduling, grant permissions or remove configured roots.

Add synthetic directory/file/missing/symlink/error/race regressions, run the
complete suite and privacy audit, build universal 39, and obtain independent
acceptance before recoverable replacement of 38. Verify actual inventory and
parser checkpoint progress after relaunch. Other filesystem/provider I/O can
still block; this narrow repair is not a whole-filesystem timeout guarantee.
