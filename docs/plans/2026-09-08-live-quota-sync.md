# Codex Director 1.1.1: Live Current-Quota Synchronization

## Goal

Keep the Home current-allowance rings synchronized with the menu-bar account
reading without changing the historical weekly chart, source files, SQLite
schema, or presentation-cache schema.

## Data contract

- The sanitized Codex app-server snapshot is the preferred current value for
  the canonical `codex` source when it is at least as recent as the indexed
  value for that window.
- Five-hour and weekly windows are reconciled independently. A newer live
  snapshot that omits one window makes that window unavailable instead of
  retaining an older indexed value.
- The seven-day weekly chart remains derived exclusively from same-source
  indexed observations. Live account values are never appended to historical
  evidence or written into source data.
- A failed account read keeps the last unexpired sanitized snapshot. A future,
  invalid, missing, or expired value never becomes an inferred zero or 100%.
- Other indexed quota sources remain unchanged and selectable.

## Refresh behavior

- With the menu bar enabled, the main Refresh data action requests quota,
  directory, and account-usage domains through the existing app-scoped
  coordinator.
- An automatic account-only menu-bar refresh republishes the Home current
  rings immediately through the shared observable model; it does not scan
  sources or read SQLite.
- With the menu bar explicitly disabled, main-window refresh does not start
  the Codex account process, preserving the existing opt-out boundary.

## Compatibility and validation

- Version: `1.1.1` (build `23`).
- Keep presentation cache schema v1 and `.codexpack.zip` manifest v1.
- Test live-newer, indexed-newer, single-window, source-isolation, refresh-domain
  gating, cache compatibility, expiry, and the existing visual/accessibility
  matrix.
