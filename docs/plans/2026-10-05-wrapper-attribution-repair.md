# Wrapper Attribution Reliability Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. In this workspace use the available local executing-plans skill; unavailable superpowers tools are not required. The user has selected real Software Engineer execution in this session, followed by independent Quality Engineer review.

**Goal:** Recover missed literal Agent/Skill reads without inventing execution, double counting, losing user organization, or blocking cached startup.

**Architecture:** Retain the read-only streaming indexer, canonical resource resolvers, normalized usage view, and shared refresh coordinator. Replace whole-wrapper syntax vetoes with bounded structural recognition of supported execution positions, preserve known observations independently of unsupported siblings, and separate observed invocation from per-operation success. Reparse only the affected recent history transactionally.

**Tech Stack:** Swift 6, Foundation, SQLite, XCTest, existing native application and localization. No new dependency, JavaScript evaluator, network request, database reset, or schema migration.

---

## Scope and ownership

- Reuse the clean public checkout and current `codex/capability-folder-usage-1.5.0` branch. Do not modify the private archive or stage, commit, push, tag, or publish.
- Local repair version: **1.5.1 (35)**. Rollout parser marker: **1.4.1**. Preserve schema v6 and presentation-cache schema v1.
- Software Engineer owns production changes, regression tests, version sources and technical documentation. Parent owns this plan, acceptance boundaries, private read-only comparisons and deployment. Quality Engineer remains read-only and independent.
- Preserve stable resource IDs, custom folders and memberships, manual evaluations, classifications, manifest v1, Codex configuration and source logs. Do not clear derived data to obtain a green result.
- The private audit document and raw sessions must never be copied into tests, documentation, logs or Git. Use synthetic equivalents. Private validation reports contain only safe aggregate counts, fixed reason codes and evidence kinds.
- This plan supersedes the old wrapper-recognition and parser-upgrade rules only. It does not redesign pages, controls or evidence dashboards.

## ADR — bounded structural recognition

**Status:** Accepted implementation direction for this authorized repair.

**Context:** A global token veto rejects valid literal reads because unrelated output formatting contains callbacks, loops or regular expressions. A single unsupported argument can also discard previously recognized calls. Current aggregate-result certainty depends only on call count.

**Decision:** Use an explicitly bounded structural grammar in Swift. Recognize direct awaited literal calls, supported top-level sequential expressions, and literal calls eagerly constructed in supported Promise batches. Analyze invocation position rather than searching all tokens. Skip or stop at unsupported constructs according to their control-flow impact; never descend into deferred callbacks, functions, uncertain branches or loops as execution evidence. Retain proven earlier call sites when later output formatting is unsupported. Permit harmless output loops/callbacks to remain non-evidence. A call embedded in deferred code is not equivalent to an eagerly evaluated Promise-array element.

The internal extraction result must represent known calls and limited/unsupported extraction separately. It may add internal enums/fields, but must not persist raw text or paths. A known call should retain its uncertainty about result binding; `Promise.allSettled` or a multi-operation aggregate result cannot establish per-call completion, even when exactly one capability read was found. An unrelated top-level tool with dynamic arguments must not erase a separately supported earlier literal read, but calls whose execution depends on unresolved preceding control flow must not be guessed.

**Rejected alternatives:** Removing forbidden words globally permits false positives in nonexecuted code. Substring/path matching counts references rather than reads. Executing historical JavaScript is unsafe. A full JavaScript engine/parser dependency is disproportionate for the supported evidence grammar.

**Consequences:** Common safe wrappers gain coverage; arbitrary JavaScript remains unsupported. Maintain adversarial grammar tests, input/token/call/nesting budgets and deterministic extraction. Validate the whole wrapper against the finite grammar before extracting its reachable prefix: a supported statement can produce evidence, a syntactically proved but unsupported execution barrier preserves only earlier evidence, and any malformed or structurally unproved statement rejects the whole wrapper. This includes tool argument objects and code after the first barrier. Template interpolation is not evaluated and must be rejected when its inner grammar cannot be proved. Some legal JavaScript outside the finite grammar is deliberately omitted rather than guessed. Byte/token/nesting overflow rejects the whole wrapper; the call-count limit may retain only the bounded prefix with uncertain result binding. Existing read-only Shell filtering, project/workdir resolution and wrapper-level resource deduplication remain authoritative.

## Product/state contract

- A positive count means recorded, attributed observations, not successful workflows or effectiveness.
- `0` after successful aggregation means no attributed records in the interval; it does not prove non-use. Pending remains `—`. Unavailable is not zero.
- Replace definite unused labels with **近 30 天无归因记录 / No attributed records in 30 days**; localized help/AX states that unsupported or incomplete evidence can omit actual use. Keep existing activity-filter behavior and preference IDs.
- Do not turn all partial sessions or positive counts into unavailable values. Overall session coverage includes token/decoder issues and cannot establish per-capability omission by itself.
- Keep evidence kinds distinct: actual child delegation, delegation request, Agent Brief read and Skill manifest read. Requests and redundant own-Agent reads remain excluded from usage totals through the existing view.
- No new page, card, telemetry pipeline or per-row query. Reuse current detail/help/diagnostic surfaces for concise evidence limits if necessary.
- Validation uses the application's local natural-day intervals: today and previous 6 or 29 days, ending at an injected cutoff. A rolling 30x24-hour audit interval must be labelled separately and not mixed into UI comparisons.

## Task 1 — Capture regression and negative controls

**Files:**
- Create `Tests/DirectorCoreTests/Parsing/TransientToolInputTests.swift`
- Modify `Tests/DirectorCoreTests/Parsing/InvocationObservationRepairTests.swift`
- Inspect `Sources/DirectorCore/Parsing/TransientToolInput.swift`
- Inspect `Sources/DirectorCore/Parsing/InvocationExtractor.swift`

1. Add synthetic failing tests for the following supported read sites followed by unrelated output code:

```swift
func testReadSurvivesOutputCallback() {
    let input = """
    const results = await Promise.allSettled([
      tools.exec_command({cmd: 'cat sample-agent/agent.md'})
    ]);
    results.forEach((result, index) => text({index, ...result}));
    """
    let calls = TransientToolInput.literalCalls(input)
    XCTAssertEqual(calls?.map(\.name), ["exec_command"])
}

func testReadSurvivesCatalogFormatting() {
    let input = """
    text(await tools.exec_command({cmd: 'cat sample-skill/SKILL.md'}));
    text(ALL_TOOLS.filter(x => /sample/.test(x.name)).map(x => ({name:x.name})));
    """
    XCTAssertEqual(TransientToolInput.literalCalls(input)?.count, 1)
}
```

2. Add output-only `for` formatting, multiple literal calls, known plus dynamic siblings, supported direct reads, repeated same-resource reads, and literal `workdir` cases. Record current failures before implementation.
3. Add negative controls: a never-invoked callback containing a tool, conditional/loop reads, object methods, comments/quoted/regex/template references, computed tool names/paths, mixed Shell mutation and command substitution. Do not weaken their assertions.
4. Run `swift test --disable-sandbox --scratch-path /tmp/codex-director/build --filter 'TransientToolInputTests|InvocationObservationRepairTests'`; expect the new positive regressions to fail and existing negative controls to remain green.

## Task 2 — Implement bounded recognition and honest result binding

**Files:**
- Modify `Sources/DirectorCore/Parsing/TransientToolInput.swift`
- Modify `Sources/DirectorCore/Parsing/InvocationExtractor.swift`
- Modify `Sources/DirectorCore/Parsing/ManifestReadEvidence.swift` only if a required regression cannot be solved in the wrapper adapter
- Test `Tests/DirectorCoreTests/Parsing/InvocationExtractorTests.swift`
- Test `Tests/DirectorCoreTests/Parsing/InvocationObservationRepairTests.swift`

1. Implement the accepted structural grammar, preserving the compatibility entry point where practical. Track nesting with a fixed limit, avoid recursive unbounded scans and quadratic rescans, and retain existing 256 KiB / 32,768-token / 64-call budgets or stricter limits.
2. Recover supported calls and safe extraction-limit diagnostics independently. Keep all raw input transient; persist only existing allowlisted normalized evidence. Unknown code is never evaluated.
3. Supply operation-level result uncertainty to the extractor rather than relying only on `operations.count > 1`.
4. Add a full-extractor test where a single literal read inside `Promise.allSettled` is paired with an outer result: count the inferred read once, but keep per-operation completion unknown. Also cover missing, failed and interrupted results.
5. Retain project/global resolution, TOML/Brief pairing, inherited-history exclusion, per-wrapper resource deduplication and delegation/view deduplication unchanged.
6. Rerun focused tests plus `--filter 'InvocationExtractorTests|SkillEvidenceResolverTests|AgentEvidenceResolverTests|InvocationObservationPersistenceTests'` and review the diff for false-positive/privacy risk.

## Task 3 — Versioned, bounded historical repair

**Files:**
- Modify `Sources/DirectorCore/Parsing/RolloutEventDecoder.swift`
- Modify `Sources/DirectorCore/Indexing/IndexingCoordinator.swift`
- Modify `Tests/DirectorCoreTests/Parsing/RolloutEventDecoderTests.swift`
- Modify `Tests/DirectorCoreTests/Indexing/IndexingCoordinatorTests.swift`
- Test `Tests/DirectorCoreTests/Persistence/InvocationObservationPersistenceTests.swift`

1. Add failing tests for an unchanged recent parser-1.4.0 file being repaired once, unchanged older 1.4.0 files remaining deferred, and changed older files continuing normal reparse behavior. Use injected local natural-day boundaries.
2. Bump parser marker to 1.4.1 and extend the supported deferred-old-version policy explicitly to 1.4.0. Do not accidentally trigger years of archive replay by changing only the marker.
3. Use the existing transactional session replacement and checkpoint commit path; no manual insert into the live database, no destructive reset and no alternate indexer.
4. Verify repeat refresh idempotence, append continuity, cancellation before checkpoint commit, source-file changes, and late-result guards. Preserve evaluations and metadata not owned by the session replacement.
5. Run `swift test --disable-sandbox --scratch-path /tmp/codex-director/build --filter 'IndexingCoordinatorTests|RolloutEventDecoderTests|InvocationObservationPersistenceTests'`.

## Task 4 — Synthetic cross-scope replay and performance

**Files:**
- Extend `Tests/DirectorCoreTests/Parsing/InvocationObservationRepairTests.swift`
- Extend `Tests/DirectorCoreTests/Indexing/IndexingCoordinatorTests.swift`
- Extend `Tests/DirectorCoreTests/Persistence/InvocationObservationPersistenceTests.swift`
- Create a narrowly scoped test/helper under `Tests/DirectorCoreTests` only if required

1. Reproduce the five audited wrapper shapes with synthetic names/paths in isolated fixtures; validate through extraction, persistence and `capability_usage_calls`, not only token recognition.
2. Cover at least two different configured projects plus a global capability, same-name collisions, shared resources, working-directory override, child metadata and inherited history. Do not assert an exact private before/after count.
3. Replay twice into a temporary database and compare normalized evidence IDs/counts, hashes/checkpoints and existing evaluations. Compare source-file hashes before/after; zero source writes.
4. Test malformed delimiters, long strings/comments, deep nesting, oversized inputs and many output-only callbacks under a deterministic operation limit. Measure a representative bounded synthetic corpus before/after; report time/memory and avoid UI-main-thread work.
5. Parent may independently inspect known private samples or a disposable audit copy. Keep original/live databases and logs read-only until the verified installed App performs its normal authorized shared refresh.

## Task 5 — Evidence terminology without visual redesign

**Files:**
- Modify `Sources/DirectorUI/Resources/zh-Hans.lproj/Localizable.strings`
- Modify `Sources/DirectorUI/Resources/en.lproj/Localizable.strings`
- Modify fallback terminology in `Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift`
- Test `Tests/DirectorUITests/CapabilityLibraryPresentationTests.swift`
- Test `Tests/DirectorUITests/CapabilityLibraryStateTests.swift`

1. Update the existing unused metric/filter copy and help/AX semantics to the product contract. Keep selection IDs, counts, sorting, scope, layout and controls unchanged.
2. Assert pending versus observed-zero versus positive partial/inferred evidence; partial evidence must not disappear solely because coverage is partial.
3. Verify both language keys, synthetic labels and no raw paths/payloads in AX. Do not add a new diagnostic dashboard or pretend to know which unobserved resource an unsupported wrapper would have used.
4. Run `swift test --disable-sandbox --scratch-path /tmp/codex-director/build --filter 'CapabilityLibraryPresentationTests|CapabilityLibraryStateTests|CapabilityFolderUsageTests'`.

## Task 6 — Documentation and local repair identity

**Files:**
- Modify `README.md`, `README.zh-CN.md`, `CHANGELOG.md`, `CHANGELOG.zh-CN.md`, `docs/ARCHITECTURE.md`, `docs/RELEASE.md`
- Modify `PRIVACY.md` only if its existing statements need clarification; do not broaden allowed persistence
- Modify `project.yml`, `CodexDirector.xcodeproj/project.pbxproj` and the existing Settings version fallback/contract tests
- Parent owns this plan; engineer may append a concise synthetic execution record

1. Document supported-wrapper limits, recorded-read semantics, result uncertainty and recent-only backfill. Do not claim complete historical observability or effectiveness.
2. Update current local version sources consistently to 1.5.1 (35); preserve historical release entries. No Tag or Release is created.
3. Run `git diff --check`; inspect every new file for personal paths, credentials, raw sessions and unauthorized assets.

## Task 7 — Verification, independent review and installation

1. Run focused suites, full `./scripts/verify.sh`, `./scripts/audit-public-release.sh --all`, and `./scripts/build-local-app.sh`. Record test counts, skips and failures honestly. Include new untracked files in a separate sensitive-content review since tracked/history audit alone may not include them.
2. Software Engineer hands the exact diff, commands/results, error/result-binding semantics and replay evidence to an independent Quality Engineer. Reviewer must inspect source/tests directly and return passed or blocked; no author self-approval.
3. Any P0/P1/P2 defect returns to the engineer, then undergoes independent re-review. Do not install a blocked build.
4. After acceptance and verified Release build, parent uses native UI control to quit the current app, moves the old bundle to a unique recoverable Trash name, copies the verified bundle, checks exact bundle/hash/version/architectures/signature, then relaunches through native UI control. Avoid script paths that perform shell-based UI automation.
5. Before normal shared refresh, preserve a consistent private database backup and compare folder/evaluation state using hashes or safe aggregates. After completion, compare the affected evidence under one fixed natural-day cutoff; repeat refresh to verify no duplication. Do not expose raw data in public artifacts.
6. If a required runtime/data-preservation check is unavailable, report the exact remaining gate rather than declaring complete. No commit, push, main merge, Tag or GitHub Release occurs without separate authorization.

## Acceptance checklist

- Positive wrapper shapes recover known inferred reads; deferred/conditional/dynamic references do not become usage.
- Unrelated unsupported output does not erase known prior reads. Result status never derives solely from an aggregate wrapper returning successfully.
- Five synthetic audit equivalents work end-to-end; other projects/global scopes and negative controls pass.
- Recent unchanged files backfill once; older unchanged archives stay deferred. Repeated refresh is idempotent; cancellation/source races do not advance an uncommitted checkpoint.
- Positive partial evidence remains visible. Zero means no attributed record; unavailable/pending are distinct.
- Stable IDs, folders, evaluations, source files, Codex configuration, cache/schema contracts and manifest v1 remain unchanged.
- Full tests, privacy/history audit, verified universal Release build and independent review pass before installation.

## Deferred

General JavaScript/Shell interpretation, deep historical replay beyond the existing ranking window, historical capability registries, evidence dashboards, per-capability coverage attribution without evidence, new telemetry, AI classification and GitHub publication.

## Execution and acceptance record — 2026-10-05

- Production implementation was completed by Software Engineer; independent, read-only Quality Engineer review returned **passed**, with no unresolved P0/P1/P2 findings.
- Final focused parser/extractor verification: **106 tests, 0 failures**. History/decoder/persistence verification: **71 tests, 0 failures**. Independent integration verification: **156 tests, 0 failures**, plus **128 adversarial grammar cases**.
- Full `./scripts/verify.sh`: **1,075 tests, 3 existing skips, 0 failures and 0 unexpected failures**. Public/history audit and universal Release build passed. No dependency, database schema, capability-package format or preference-key change was introduced.
- A bounded synthetic pressure corpus produced 50,000 observations from 50,000 wrappers in **4.17 seconds** (mean **0.083 ms/wrapper**, maximum RSS approximately **7.1 MB**, no swaps). This is parser pressure evidence, not a main-window latency or full-index performance guarantee; the broader grammar costs more than the old recognizer.
- Verified and installed **1.5.1 (35)**, parser **1.4.1**, for macOS 26+, containing **arm64 and x86_64** with an ad-hoc signature. The previous application bundle was moved to a unique, recoverable Trash location. Installed and built bundles matched exactly.
- The installed App completed its normal shared refresh over **1,906 files**, retaining cached presentation during the one-time recent-history replay. **279** checkpoints now use parser 1.4.1; older unchanged checkpoints remain deferred. The recent files total approximately **7.3 GB**, so initial replay was substantial; no fast-refresh claim is made from the synthetic benchmark.
- A read-only comparison using one fixed local-natural-day interval and cutoff found attributed observations for all five previously missed target capabilities. A second normal refresh preserved both their counts and normalized evidence IDs exactly. Database integrity checks returned `ok`.
- Folder memberships, evaluation/classification preferences and the sampled source files matched their immediate pre-install hashes after both refreshes. Target stable resource IDs and configuration ownership were unchanged. One externally updated Brief observed earlier in the task was preserved, not reverted.
- Private validation used consistent local database snapshots and aggregate comparisons only. No private handoff, raw session content or real capability body was copied into the public tree. No source logs, capability definitions, global Codex configuration or live database were manually edited.
- No staging, commit, push, PR, merge, Tag or GitHub Release was performed. General JavaScript remains intentionally unsupported; recorded observations remain a conservative lower bound and do not prove capability effectiveness.
