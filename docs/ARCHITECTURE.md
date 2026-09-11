# Architecture

Codex Director separates local source discovery from Director-owned projections and presentation.

## Layers

- **DirectorCore** discovers local resources, parses allowlisted evidence, coordinates refresh, persists projections and evaluations, and builds capability packages.
- **DirectorUI** renders the seven primary destinations, detail flows, settings, export flow, themes, localization, and accessibility states.
- **CodexDirectorApp** owns application composition, dependency injection, windows, and app-level shared stores.

## Data authority

Agent, Skill, project instruction, plugin, and session files remain source-owned and read-only. SQLite accelerates presentation and stores Director-owned classifications and evaluations; it is not authoritative for capability file content.

## Refresh and concurrency

Application surfaces share one refresh coordinator. Source scanning and projection are distinct phases. Cached results appear before background refresh, failures retain the last valid projection, and late or cancelled work cannot overwrite newer state. The enabled menu bar has one app-scoped account-only scheduler: after startup grace it uses five-minute wakes while the aggregate session is active and 30-minute wakes after 30 minutes idle, backs off failed reads at 5/15/30 minutes, and pauses on lock, sleep or Low Power Mode. Its bounded wake-up never starts capability indexing or reads SQLite.

The sanitized app-server snapshot is also composed into Home as the current five-hour and weekly allowance for the canonical Codex source when it is at least as recent as that window's indexed observation. This is a presentation-only merge: indexed observations remain the sole input to the seven-day weekly chart, and live account values are never inserted into session evidence or SQLite history. The account DTO and indexed projection remain separate fields in presentation-cache schema v1 so old caches stay readable.

## Codex runtime boundary

`CodexRuntimeLocator` resolves an executable in this order: an explicit Director preference, known Codex application locations, then absolute directories from `PATH`. It invokes the executable directly without a shell, applies a timeout and output cap to version probing, and exposes source, compatibility, and execute-permission state. Director never installs Codex, changes `PATH`, edits global Codex configuration, or stores Codex account information.

If no usable runtime is available, filesystem inventory continues without runtime discovery. Capability export records plugin inventory as incomplete instead of claiming that zero plugins are installed.

## Capability packages

Exports use manifest v1 with checksums, logical roots, path placeholders, plugin inventory, dependency inventory, and bilingual recovery instructions. Packages are local and unencrypted. The app verifies the completed ZIP before moving it to the user-selected destination.

Restore uses the same manifest v1 verifier but keeps the package in an isolated
temporary extraction owned by an app-scoped `CapabilityRestoreCoordinator`.
Global roots are fixed to the current user's approved Agent, Skill, and
instruction locations; each project requires an explicit in-memory folder
mapping. Preflight classifies each entry as create, identical skip, or
conflict, treats an existing `AGENTS.md` as a conflict, and groups Agent
configuration/Brief pairs and Skill directories atomically. The coordinator
shares a migration lock with export and rechecks the archive and targets before
writing. Target access is anchored to the approved Home/project directory file
descriptor; every descendant is traversed with no-follow `*at` operations. An
operation-scoped mode-0700 quarantine is prepared under every approved root
before the first target write. Files, directories, and symlinks receive a
pre-create journal record under unpredictable same-directory staging names;
creation is then followed by descriptor binding and exclusive
`renameatx_np(RENAME_EXCL)` publication. Relative
symlink targets are resolved again through the approved root descriptor with
no-follow traversal before and after publication. A staged symlink is first
observed with `fstatat(AT_SYMLINK_NOFOLLOW)`, then opened with `O_SYMLINK`; an
immediate `fstat` must match that observation exactly before the FD-derived
identity enters the journal. The staging name is matched to the held FD again
before publication, and the final name plus target are matched again after
publication. Rollback records close-on-
exec parent/object descriptors, inode, hash, type, mode, and placeholder path
for every created item. Production cleanup contains no destructive unlink.
Cancellation, failure, and in-session Undo move verified unchanged objects
atomically from their logical names into the operation quarantine and preserve
them there; changed, replaced, moved, nonempty, or uncertain objects stay in
place and are reported. If post-create descriptor binding itself fails, the
unpredictable staging name is left in place and reported because its current
pathname cannot safely prove object ownership. A final rename race is verified after movement and any
replacement is returned to its original name when possible. Quarantine content
is never automatically destroyed. Its raw local URL remains in memory only for
the explicit Finder reveal action. A generation
guard defers sheet-close discard and migration-lock release until active
restore/undo cleanup has reached a terminal state. No
raw target path or restore receipt is persisted. Package content is never
executed, merged, uploaded, or used to install plugins/dependencies. Conflict
review shows capped redacted text differences or binary metadata only, plus
the concrete read-only plugin and dependency checklists.

## Privacy boundary

Only allowlisted normalized evidence reaches persistence. Prompts, arguments, raw outputs, credentials, cookies, session bodies, and unredacted personal paths are excluded.

## Capability grouping

Capability Groups is a presentation-only projection over the current Agent and
Skill directory. `CapabilityGroupingClassifier` uses versioned deterministic
name and declared-purpose rules without AI, network access, or source writes.
`CapabilityGroupingStore` persists only user-created category names and manual
stable-resource-ID overrides under its dedicated UserDefaults key. Automatic
results are recomputed after each directory projection, disappearing IDs retain
their manual override, and deleting a custom category moves its assignments to
the immutable Uncategorized group. Grouping preferences survive derived-index
deletion and are not included in manifest v1 capability packages.
