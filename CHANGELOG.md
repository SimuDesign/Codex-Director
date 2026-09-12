# Changelog

All notable public changes will be documented here.

The project follows semantic versioning for public releases.

## Unreleased

- Replaced the unpublished Capability Groups experiment with Capability Folders: a local, user-controlled browser with Global/Project projections, an empty Self Training folder, atomic existing-capability import, multi-membership, ordering, search, and three folder-internal Agent/Skill tabs. Explicit Agent/companion-Skill declarations are separated from co-observation evidence; folder preferences store only stable IDs and never modify source files.
- Companion evidence now comes from one indexed batch projection, while paired global Agent TOML/Brief files remain one logical Agent and both declaration sources are inspected. Explicit negative directives and ambiguous matches fail closed.

- Add a guided local-safe restore flow for trusted manifest v1 capability packages. It verifies the isolated package, requires manual project mappings, creates missing files only, reports conflicts, and supports an in-session undo without persisting target paths.
- Prepare Codex Director for a privacy-reviewed open-source release.
- Add public release auditing and open-source governance documents.
- Add read-only CI and a pinned, attested, draft-prerelease workflow for universal unnotarized community builds.
- Add stripped app, package, checksum, dependency, provenance metadata, and archive round-trip verification.
- Add reproducible synthetic startup gates and database/cache failure coverage for the public release baseline.
- Reduce quota-history query sorting while preserving seven-day, source, predecessor, and deterministic tie semantics.

## 1.3.0

- Added a Capability Folders destination with Global and Project folders, plus an empty Self Training folder that preserves user-selected memberships across refreshes and upgrades.
- Added custom folder create, rename, delete, reorder, multi-membership, atomic existing-capability import, global search, folder search, project Agent/Skill tabs, and recent/name sorting. Folder preferences contain only stable IDs and names; no paths or capability content.
- Removed the unpublished automatic category classifier and eight preset categories. Plugin-provided Skills are visible in Global; system capabilities, plugin packages, instructions, MCP/tools, and stale plugin caches remain excluded.

## 1.2.0

- Added local restoration of trusted `.codexpack.zip` packages through a staged verify, project mapping, preflight, and final confirmation flow.
- Existing files are never overwritten or merged. Identical entries are skipped; conflicting capabilities can be excluded while the package remains available for review.
- Restore writes are anchored to approved directory descriptors, reject symlink ancestry and target races, journal every type before exclusive atomic publication, and preserve executable bits plus descriptor-verified relative symlinks.
- Failed/cancelled restore and one-session undo never delete restored objects. Every approved root receives a private mode-0700 quarantine before writes; verified unchanged objects move there and remain available through an in-memory Finder reveal action, while replaced, moved, or user-modified objects stay in place and are reported. Sheet-close discard keeps the shared migration lock until active cleanup finishes.
- Conflict review shows capped redacted text differences and metadata-only binary details. Plugins and external requirements are concrete read-only checklists; restore never executes content, installs dependencies/plugins, modifies Codex configuration, or uses the network.
- Added bilingual restore UI, privacy copy, manifest v1 round-trip tests, and a shared export/restore migration lock.

## 1.1.1

- Synchronized Home's current five-hour and weekly allowance rings with the sanitized live account reading used by the menu bar.
- Kept the seven-day weekly chart on indexed same-source history and left presentation-cache schema v1 unchanged.
- Added account usage to the main Refresh data action while the menu-bar account feature is enabled; an explicit opt-out still starts no Codex account process.
- Updated the Home timestamp to reflect a newer account-only refresh and added regression coverage for source isolation, missing windows, and stale-cache ordering.

## 1.1.0

- Added same-source five-hour allowance projection alongside the existing weekly allowance, without a database migration.
- Home now presents valid five-hour and weekly windows as concentric rings; expired or unavailable windows are hidden independently and the weekly daily chart remains weekly-only.
- Menu-bar status now formats dual windows as `5h 82% w 57%`, or a single bare percentage when only one window is available. The popover lists each available reset independently.
- Updated the local app-server reader, presentation cache compatibility, reset scheduling, bilingual copy, and synthetic coverage for both windows.

## 1.0.0

- Prepared the first public open-source release with a clean 1.0.0 application identity.
- Unified Settings action sizing across localized labels and kept capability project-group boundaries 20pt apart.
- Unified the three Settings actions on a shared 176pt content width and 48pt outer height; the internal build was 21 while the visible version was 1.0.0.
- Removed the trailing ellipsis from the capability-package export action for a stable compact control label.

## 0.6.2

- Added an app-scoped adaptive account-usage schedule for the enabled menu bar.
- Active sessions refresh every five minutes; aggregate idle sessions use a 30-minute cadence, with 5/15/30-minute failure backoff.
- The schedule pauses for lock, sleep and Low Power Mode, and never starts capability indexing or a second database reader.
- Popover reads now refresh missing, expired or older-than-two-minute account data through the shared coordinator.

## 0.6.1

- Fixed live menu-bar insertion and removal by binding `MenuBarExtra` to the shared app-scoped preference store across windows.
- Menu-bar visibility now defaults to enabled for new installs while an explicit user opt-out remains persisted across launches.

## 0.6.0

- Added an opt-in native macOS menu-bar quota summary with weekly remaining allowance, next reset time, reset-card count, data refresh, and a main-window shortcut.
- Reads account allowance through the local Codex app-server only when requested; no account identifiers, credentials, model buckets, or source details are retained or displayed.
- Added a backward-compatible optional account-usage field to the presentation cache and kept menu-bar refreshes on the shared refresh coordinator.

## 0.3.1

- Added application-owned Light and Dark themes.
- Replaced icon-only refresh controls with shared text and loading states.
- Preserved portable capability package manifest v1.

Earlier private development history is retained outside the public repository and is not part of the public changelog.
