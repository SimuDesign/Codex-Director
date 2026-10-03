# Invocation Observation Repair Implementation Plan

> Execute task-by-task with the available executing-plans workflow and verify each repair boundary before deployment.

**Goal:** Repair missed Agent delegation and Agent/Skill read evidence without guessing usage, double-counting inherited history, or changing capability identities.

**Architecture:** Keep the existing read-only streaming indexer and shared refresh coordinator. Add allowlisted evidence provenance, scope-aware identity resolution, bounded static read extraction, and transactional recent-history replacement. The UI continues to consume the existing aggregates; requests and redundant reads do not inflate counts.

**Tech Stack:** Swift 6, Foundation, SQLite, XCTest, existing SwiftUI application. No new dependencies.

---

## Decision / scope

- Patch version: **1.4.4 (32)**. Parser marker: **1.4.0**; disposable database schema: **6**.
- Reuse the public checkout on `codex/invocation-observation-1.4.4`. Preserve the uncommitted 1.4.3 work; do not stage, commit, publish, or mutate private archives.
- Keep resource IDs, folder membership, manual evaluations, classification overrides and manifest v1 unchanged.
- Distinguish actual child-session delegation, delegation request, Agent Brief/configuration read, Skill manifest read, and structured invocation. A completed read/dispatch never proves capability effectiveness.
- Child-session metadata is the authoritative launch observation. `agent_type` records request evidence, not a second confirmed launch. Name/context resolution without a stable explicit ID is inferred; ambiguity stays unknown.
- Read evidence in a delegated child's own Agent is retained in detail, but excluded from the aggregate when the authoritative delegation exists. Delegation requests never add to capability usage. Unrelated Brief reads and Skill reads remain observed read evidence.
- Only literal, unconditional read operations are recognized. Do not execute JavaScript/shell or infer from prompts, comments, outputs, capability lists, task names, dynamic paths or uncertain branches.
- Reprocess unchanged supported old-parser files intersecting the last 30 local calendar days, using cached session timestamps and file mtime. Defer unchanged older files. Normal future append indexing remains incremental.
- Keep prior checkpoints on cancellation; no partially read session becomes marked current. Do not clear the database.

## Task 1: Identity and metadata (focused regression first)

**Files:**
- Modify: `Sources/DirectorCore/Discovery/ResourceScanner.swift`
- Modify: `Sources/DirectorCore/Parsing/AgentEvidenceResolver.swift`
- Modify: `Sources/DirectorCore/Parsing/SkillEvidenceResolver.swift`
- Modify: `Sources/DirectorCore/Parsing/RolloutEnvelope.swift`
- Modify: `Sources/DirectorCore/Parsing/RolloutEventDecoder.swift`
- Modify: `Sources/DirectorCore/Parsing/InvocationExtractor.swift`
- Test: `Tests/DirectorCoreTests/Parsing/InvocationObservationRepairTests.swift`
- Test: `Tests/DirectorCoreTests/Discovery/ResourceScannerTests.swift`

1. Add synthetic tests for project/global same-name roles, TOML/Brief aliases, actual child metadata and inherited ordinal boundaries.
2. Run `swift test --disable-sandbox --scratch-path /tmp/codex-director/build --filter InvocationObservationRepairTests` and capture the regression failure.
3. Add ephemeral project pairings and context-aware resolution; preserve all canonical resource paths/IDs. Carry the validated source ordinal only transiently.
4. Emit one stable delegation observation per child session. Ignore inherited response/event records below an explicit boundary; unknown fork boundaries are not guessed.
5. Rerun focused tests and existing extraction/discovery suites.

## Task 2: Bounded read extraction

**Files:**
- Create: `Sources/DirectorCore/Parsing/TransientToolInput.swift`
- Modify: `Sources/DirectorCore/Parsing/ManifestReadEvidence.swift`
- Modify: `Sources/DirectorCore/Parsing/InvocationExtractor.swift`
- Test: `Tests/DirectorCoreTests/Parsing/InvocationObservationRepairTests.swift`

1. Add failing tests for JSON `arguments`, literal multiple-tool wrappers, multiple manifests and unconditional read-only shell sequences.
2. Add a bounded non-executing tokenizer that ignores comments/string references and extracts literal tool argument objects. Reject uncertain control flow/dynamic interpolation and malformed/oversized inputs.
3. Resolve every uniquely known manifest separately, using explicit command workdir or the session workdir. Reject writes, redirection, pipelines, command substitution, mutation options and arbitrary path suffix matches.
4. Preserve unknown operation results for batch reads; do not infer per-operation success from a wrapper's overall success.
5. Test comments, nonexecuted branches, name collisions, unknown paths, escaped literals, failed reads and partial batches.

## Task 3: Provenance and counting compatibility

**Files:**
- Modify: `Sources/DirectorCore/Domain/InvocationEvent.swift`
- Modify: `Sources/DirectorCore/Persistence/DatabaseSchema.swift`
- Modify: `Sources/DirectorCore/Persistence/DatabaseStore.swift`
- Test: `Tests/DirectorCoreTests/Persistence/InvocationObservationPersistenceTests.swift`

1. Add nullable fixed-enum evidence provenance; old Codable records and schema v5 rows decode with no provenance.
2. Migrate schema v5 in a transaction without deleting any data. Persist only enum values, stable IDs and existing normalized metadata, never raw arguments, role instructions, outputs or absolute paths.
3. Add an indexed usage view excluding delegation requests and duplicate own-Agent reads/structured records. Apply it consistently to capability-period, history and project usage aggregates; keep raw evidence accessible.
4. Verify migration, privacy allowlist, read/write round trip, late delegation insertion, independent reads, and unchanged legacy counts.

## Task 4: Recent historical repair and append safety

**Files:**
- Modify: `Sources/DirectorCore/Indexing/IndexingCoordinator.swift`
- Test: `Tests/DirectorCoreTests/Indexing/IndexingCoordinatorTests.swift`
- Modify: `Tests/DirectorCoreTests/Parsing/RolloutEventDecoderTests.swift`

1. Supply project/session workdir and metadata to the extractor, including append parses via a bounded metadata read.
2. Upgrade parser marker and reprocess recent old checkpoints; do not reparse all historical archives.
3. Keep cancelled checkpoints at the last committed segment. Require complete byte coverage when skipping unchanged files.
4. Verify unchanged recent files repair once, old files stay deferred, appended child files preserve context, inherited history is excluded, and cancellation/retry does not lose or double data.

## Task 5: Documentation, verification and local deployment

**Files:**
- Modify: `README.md`, `README.zh-CN.md`, `CHANGELOG.md`, `CHANGELOG.zh-CN.md`, `PRIVACY.md`, `docs/ARCHITECTURE.md`, `docs/RELEASE.md`
- Modify: `project.yml`, `CodexDirector.xcodeproj/project.pbxproj`, version contract tests as required

1. Document evidence/count boundaries and bounded backfill; update current version, not historical changelog entries.
2. Run focused tests, full Swift tests, `./scripts/verify.sh`, `./scripts/audit-public-release.sh --all`, and `./scripts/build-local-app.sh`.
3. Inspect privacy and final diff. Independent Quality Engineer review is requested separately; do not claim an independent decision from author verification.
4. After gates pass, use `./scripts/install-local-app.sh`, retaining the previous bundle in Trash. Compare installed bundle/signature/version with the verified artifact.
5. Use the normal shared refresh for real recent-history repair. Report only aggregate comparison, completion/coverage and preference preservation; keep private content out of artifacts. No GitHub push, tag or release.

## Acceptance / deferred work

- Target project roles no longer show zero solely because real delegation or known Brief reads were dropped.
- Source capabilities/logs/configuration receive zero writes. Existing folders and evaluations remain intact.
- Parent requests plus child metadata and inherited history do not inflate usage.
- Unknown/dynamic/conditional reads remain honestly unobserved; this repair is not a general JavaScript/shell interpreter, historical capability registry, or proof of workflow success.
- No UI redesign or new statistics dashboard. A dedicated evidence-type presentation can be a later product change.

## Execution record — 2026-10-03

- Tasks 1–5 implemented with author verification. No independent Quality Engineer acceptance is claimed in this record.
- Focused extraction, discovery, indexing and persistence verification: **101 tests, 0 failures**.
- `./scripts/verify.sh`: **1003 tests, 3 opt-in heavy-performance tests skipped, 0 failures**, followed by a successful debug build and project contract checks.
- `./scripts/audit-public-release.sh --all`: passed. New untracked implementation/test/plan files received an additional personal-path and credential-pattern check.
- Release build and local deployment: passed for **1.4.4 (32)**, macOS 26+, **arm64 + x86_64**, ad-hoc signature. Installed artifact matched the verified build; the previous application remains recoverable in Trash.
- Real recent-history repair completed through the existing shared refresh coordinator. A read-only comparison of child-session metadata and derived delegation observations agreed for the affected roles. Both Agent and Skill lists visibly showed repaired 30-day results.
- A second normal refresh completed without duplicating delegation IDs or changing the delegation checksum. Existing capability-folder preferences remained byte-for-byte unchanged. A pre-upgrade local database backup was retained; the resulting database passed `quick_check`.
- No capability source, session log or global Codex configuration was edited. No database reset, commit, GitHub push, tag or Release was performed.
- Coverage remains intentionally conservative: dynamic/conditional inputs and uncertain inherited boundaries are not guessed; unchanged older history stays deferred. Observed usage is not proof of a completed method or effectiveness.
