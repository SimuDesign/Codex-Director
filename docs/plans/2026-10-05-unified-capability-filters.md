# Unified Capability Filters Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Use the installed local equivalent; unavailable tools are not required.

**Goal:** Give Capability Folders and the four capability libraries one independent usage-period/sort interaction and consistent native control geometry.

**Architecture:** Reuse the existing seven/thirty-day in-memory projections and app-shared period preference. Keep the existing preference key for compatibility, synchronize library presentation models, and do not alter Core queries, database/cache formats, parser, source files or folder memberships. Legacy period-specific sort values remain compatible for existing clients but are no longer menu options.

**Tech Stack:** SwiftUI/AppKit, Combine, existing Scheme A controls and XCTest; no dependencies.

## Approved UX/UI contract

- User approved the preceding recommendation: search → applicable scope → independent Last 7/30 days → sort; plugin status follows sort where relevant.
- Usage descending, Usage ascending and Name A–Z have identical localized names everywhere. Modified descending stays available only in custom libraries.
- Period survives name/modified/ascending sort, search, scope and destination changes. Reuse the existing app-shared remembered period; Home rankings remain independent.
- All filter fields use a 36pt outer height, 12pt gaps, one native search editor, one disclosure chevron, full painted hit bounds, and neutral outlined Scheme A styling. The usage selector is 232pt, sort 176pt. Narrow layouts wrap without hiding selected values.
- Folder ownership is already fixed by its enclosing folder; do not add a redundant ownership selector. Retain all library scope, activity and plugin status behavior. Summary metrics retain their explicit fixed periods.
- Keep 1.5.0; increment only the internal build to 34. No automatic commit, push, PR mutation, Tag or Release. Work in the current clean public branch; preserve the private archive.

## Task 1 — Tests and presentation state

Files: `Tests/DirectorUITests/UnifiedCapabilityFilterTests.swift`, `Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift`, `Sources/DirectorUI/AppShell/DirectorAppModel.swift`.

1. Write tests for opposite period orders; ascending/name/modified retaining thirty days; pending vs zero and plugin unknown-last; legacy sort compatibility; cross-model synchronization without queries/refresh/member changes.
2. Run `swift test --disable-sandbox --scratch-path /tmp/codex-director/build --filter UnifiedCapabilityFilterTests` and observe the expected missing-state failure.
3. Add independent presentation-only period state, include it in projection/text cache keys, and synchronize through the existing period store. Normalize legacy period-specific sort only when using the new explicit period setter.
4. Repeat focused tests and neighboring library/folder state tests.

## Task 2 — Shared controls and responsive layout

Files: `Sources/DirectorUI/DesignSystem/DirectorCapabilityUsageControls.swift`, `DirectorSpacing.swift`, `DirectorSchemeA.swift`, both capability views, `DirectorRootView.swift`, bilingual strings, layout/source-contract tests.

1. Reuse one shared period picker and sort vocabulary. Allow the native segmented control to use a scoped 36pt fitting height without changing the three folder tabs or Settings controls.
2. Add the period field to all four library ribbons; remove period-in-sort options. Unify field height, widths/gap tokens, padding/chevron hit targets and responsive fitting using actual inner widths.
3. Keep native focus, keyboard, AX selected values, Increase Contrast and opaque Reduce Transparency; no custom motion or glass content.
4. Test shared consumers, labels, widths/breakpoints, period-specific row text, language keys and absence of new data reads.

## Task 3 — Documentation, verification and local install

Files: design system/validation plan, bilingual README/CHANGELOG, release docs, `project.yml`, generated Xcode version and tests.

1. Supersede the old period-in-sort contract for all capability libraries; retain contextual filters and fixed metric periods.
2. Run focused tests, full `./scripts/verify.sh`, `./scripts/audit-public-release.sh --all`, and Release `./scripts/build-local-app.sh`.
3. Exercise synthetic native library/folder screens at zh/en, Light/Dark and narrow/default widths; verify period/menu hit targets, keyboard, counts and responsive geometry. Record AX separately from actual VoiceOver; do not claim untested matrices or independent QA.
4. After relevant gates pass, quit the installed app via native UI, move the previous exact bundle to recoverable Trash, install and compare/signature/version/architecture/hash, relaunch and inspect runtime. No capability data or folder preference reset.

## Evidence limits

Initial implementation was authored in the root task. After the user explicitly requested actual production delegation, a real Software Engineer took ownership of the existing implementation and completed engineering verification. A separate real Quality Engineer performed read-only scoped acceptance. Do not imply the original code was authored by the delegated engineer or that untested accessibility matrices passed.

## Execution evidence — 2026-10-05

- Software Engineer: seven focused tests, 71 neighboring tests, and the full verification passed: 1021 tests, three skipped, zero failures. An earlier full run stalled in runtime-command tests; the process was safely terminated, the isolated five-test group passed, and the full rerun completed successfully.
- Independent Quality Engineer: seven focused, 64 UI/layout/folder/library, and 60 state/integration/localization tests passed. Scoped acceptance passed with no unresolved P0/P1/P2 findings.
- Public tree/history audit and additional privacy checks for new untracked text files passed; `git diff --check` passed. Release identity, macOS 26 minimum, arm64/x86_64 and ad-hoc signature verified.
- Author native synthetic checks covered Chinese/Dark at the default width and English/Light at 720×480, cross-page period retention, name sort without period reset, pending/unavailable semantics, search-edge hit bounds and menu-edge hit bounds. These are not independent full visual-matrix evidence.
- Formal VoiceOver speech, complete keyboard matrix and full contrast/transparency/motion appearance matrix remain unverified. The independent review's Validation Host binding timed out; scoped acceptance does not claim those checks passed.
- Installed 1.5.0 build 34 after scoped acceptance, moving the previous exact bundle to recoverable Trash. Installed and built bundle contents and executable SHA-256 matched; relaunch confirmed independent period/sort controls and the remembered 30-day choice. Folder preferences matched their pre-install checksum.
- No Git commit, push, PR mutation, Tag or Release was performed. No private archive, source capability, parser, schema or folder membership changes.
