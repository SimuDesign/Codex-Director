# Changelog

All notable public changes will be documented here.

The project follows semantic versioning for public releases.

## Unreleased

- Prepare Codex Director for a privacy-reviewed open-source release.
- Add public release auditing and open-source governance documents.
- Add read-only CI and a pinned, attested, draft-prerelease workflow for universal unnotarized community builds.
- Add stripped app, package, checksum, dependency, provenance metadata, and archive round-trip verification.
- Add reproducible synthetic startup gates and database/cache failure coverage for the public release baseline.
- Reduce quota-history query sorting while preserving seven-day, source, predecessor, and deterministic tie semantics.

## 1.0.0

- Prepared the first public open-source release with a clean 1.0.0 application identity.
- Unified Settings action sizing across localized labels and kept capability project-group boundaries 20pt apart.
- Unified the three Settings actions on a shared 176pt content width and 48pt outer height; the internal build remains 21 while the visible version is 1.0.0.
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
