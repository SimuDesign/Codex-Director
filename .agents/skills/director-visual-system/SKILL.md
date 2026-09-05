---
name: director-visual-system
description: Govern and review Codex Director's native macOS visual system across the main window, menu bar, Liquid Glass controls, capability topology, invocation timeline, workflow view, health states, and desktop pet. Use for UI or visual design, SwiftUI/AppKit/SpriteKit/WebGL component work, design tokens, motion, accessibility, previews, and visual consistency audits in this repository. Do not use for JSONL parsing, SQLite, resource scanning, telemetry, backend-only work, or other projects.
---

# Director Visual System

Keep Codex Director visually coherent, native to macOS, and faithful to the evidence and privacy boundaries in the project handoff. Treat the project design specification as the product source of truth and Apple documentation as the platform/API source of truth.

## Required intake

1. Locate the repository root containing `HANDOFF.md`.
2. Read `HANDOFF.md` and the root `AGENTS.md` before proposing or changing UI.
3. Read `.design/codex-director/DESIGN_SYSTEM_V1.md` completely.
4. Read `.design/codex-director/VALIDATION_PLAN.md` when implementing, reviewing, or declaring visual work complete.
5. Inspect existing tokens, components, previews, and platform adapters before introducing a new primitive.
6. Consult current Apple HIG or API documentation when a platform behavior or API detail is uncertain. Do not treat a third-party Skill as authoritative.

## Source priority

Resolve conflicts in this order:

1. System, user, and project safety instructions, including `HANDOFF.md`.
2. Current Apple documentation for macOS behavior and framework APIs.
3. `DESIGN_SYSTEM_V1.md` for Codex Director identity, semantics, and component contracts.
4. This Skill for workflow and review procedure.
5. Third-party articles or Skills as non-authoritative background only.

Never copy or install third-party Skills, Apple UI kits, or proprietary assets as part of normal use of this Skill.

## Workflow

### 1. Classify the surface

Identify the target before designing:

- **Main app**: dense operational workspace; prefer SwiftUI system structure and AppKit only where SwiftUI is insufficient.
- **Menu bar**: glanceable, privacy-safe status; use native menu bar patterns and no persistent task text by default.
- **Desktop pet**: optional state avatar; use a native lightweight overlay and never make it the only status channel.
- **Visualization canvas**: topology, workflow, or timeline; use the renderer suited to scale while keeping surrounding controls native.

### 2. Preserve the content/control hierarchy

- Keep data, text, tables, and visualizations in the content layer.
- Reserve Liquid Glass for top-level navigation, controls, transient overlays, and system-provided surfaces.
- Prefer standard SwiftUI/AppKit components so macOS supplies current material, shape, focus, and accessibility behavior.
- Do not create repeated glass cards, decorative blur panels, or a full-screen translucent dashboard.

### 3. Reuse semantic tokens

- Map every visual choice to a token in the design specification.
- Use dynamic system colors and materials for native surfaces.
- Encode status, resource type, and evidence confidence independently.
- Pair color with labels, icons, line patterns, or shape; never make color the only signal.
- Propose a token change in the specification before adding an arbitrary value in implementation.

### 4. Design all states

Cover default, hover, pressed, selected, focused, disabled, loading, empty, success, warning, failure, blocked, and unknown states where applicable. Include Light, Dark, Increase Contrast, Reduce Transparency, and Reduce Motion behavior.

### 5. Protect privacy and attention

- Do not expose prompt text, tool arguments, raw file paths, tokens, or personal data in the menu bar, desktop pet, notifications, screenshots, or previews.
- Keep animation purposeful: show causality, state change, selection, or handoff.
- Pause or simplify nonessential animation when inactive, occluded, on low power, or under Reduce Motion.

### 6. Validate before completion

Use the project validation plan. At minimum:

- verify token and component reuse;
- test keyboard, pointer, focus, and VoiceOver semantics;
- inspect appearance and accessibility variants;
- verify privacy-safe compact surfaces;
- test representative small and large datasets;
- capture previews or screenshots for visual review.

## Surface contracts

| Surface | Primary technology | Required behavior |
| --- | --- | --- |
| Main navigation and inspectors | SwiftUI, AppKit where necessary | Resizable, keyboard accessible, information dense, visually quiet |
| Menu bar | `MenuBarExtra` or `NSStatusItem` | Glanceable state, user-controlled visibility, no sensitive text |
| Desktop pet | SwiftUI/SpriteKit in an AppKit-managed window | Optional, movable, pausable, nonblocking, state-redundant |
| Topology and workflow canvas | WebGL/Canvas or native renderer selected by evidence | Progressive disclosure, zoom/focus, confidence encoding, no global hairball |
| Timeline and tables | Native list/table with virtualization where needed | Stable selection, sortable/filterable, efficient large-data behavior |

## Output contract

For a design proposal, return:

1. Target surface and primary user task.
2. Applicable tokens and existing components.
3. Layout and interaction decision.
4. Liquid Glass decision: where it appears and where it is intentionally absent.
5. State, accessibility, motion, and privacy behavior.
6. Implementation boundary: SwiftUI, AppKit, SpriteKit, or visualization renderer.
7. Validation evidence required.

For a review, report actionable findings in priority order and cite the affected file or component. Distinguish platform violations, project-system violations, accessibility failures, privacy failures, performance risks, and subjective polish suggestions.

## Boundaries

- Do not redesign backend or telemetry behavior under this Skill.
- Do not apply this Skill to unrelated repositories or generic iPhone UI questions.
- Do not invent product metrics, brand assets, user research, or unsupported Apple API behavior.
- Do not reproduce iPhone navigation patterns in a Mac window merely to resemble iOS 26.
- Do not modify global Codex configuration or install global Skills.
- Do not declare completion from a single ideal-state screenshot.

## Completion standard

Finish only when the result uses the project tokens and component grammar, follows current macOS platform behavior, keeps Liquid Glass in the functional layer, communicates state without color alone, protects sensitive data, and has evidence from the required validation matrix.
