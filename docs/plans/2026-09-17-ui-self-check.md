# UI Self-Check Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deliver a verified 1.3.1 (26) presentation repair for inconsistent folder margins, missing vertical rhythm, and system-blue selectors, without changing capabilities or saved membership.

**Architecture:** Keep DirectorCore and application data behavior unchanged. Use native NSSegmentedControl, Button and Menu semantics with scoped design-system geometry. A Product Designer reviewed, and root approved, a local nonselection folder-browser List → native ScrollView/lazy-content exception after repeated native AX failures. Other capability libraries retain List(selection:). The amended UI contract requires full content gutters and unchanged session scroll restoration. A UI Designer owns the repair contract, a Frontend Developer owns implementation, and an independent Quality Engineer owns acceptance.

**Tech Stack:** SwiftUI, AppKit, XCTest, Xcode, synthetic in-memory validation host.

## 1. Audit and baseline

- Read the project visual system, validation plan and approved folder contract.
- Audit all seven pages; repair confirmed defects rather than changing approved width differences.
- Record synthetic entry/interior baseline with the isolated validation build.
- Write exact geometry, selector, accessibility and preservation requirements in `docs/design/2026-09-17-ui-self-check-contract.md`.

## 2. Presentation repair

- Owned by Frontend Developer: `Sources/DirectorUI/Capabilities/CapabilityFoldersView.swift`, applicable design-system presentation helpers, theme selector presentation and focused UI contract tests.
- Give structural headers and content the same full content gutter; use the documented local native ScrollView exception and explicitly define module/control/content spacing.
- Replace affected system-blue segmented selectors with one shared brand-outline selector while retaining bindings and readable current selections.
- Preserve search, three tabs, relations, member menus, sorting, detail navigation and per-window state.
- Update the design system and visual validation contract; do not edit Core, databases, parser versions or capability files.

## 3. Verification and patch documentation

- Root owns version sources, bilingual README and CHANGELOG; version is 1.3.1 (26).
- Run focused layout/interaction contracts, complete Swift tests, `./scripts/verify.sh`, public audit and universal Release build.
- Use synthetic zh/en, Light/Dark and narrow/standard/wide viewports. Recheck native keyboard/AX semantics and report any unexercised system accessibility modes honestly.
- Independent Quality Engineer issues passed or blocked; remediation returns to implementation and is re-reviewed.

## 4. Local deployment

- Only install after independent acceptance and verified Release build.
- Quit installed app, move old bundle to a unique recoverable Trash name, install verified artifact, compare hashes, signature, architectures and version, then relaunch.
- Do not modify preference keys or saved folder members. Do not push GitHub, create a tag or publish a release in this task.
