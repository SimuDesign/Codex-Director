# Architecture

Codex Director separates local source discovery from Director-owned projections and presentation.

## Layers

- **DirectorCore** discovers local resources, parses allowlisted evidence, coordinates refresh, persists projections and evaluations, and builds capability packages.
- **DirectorUI** renders the seven primary destinations, detail flows, settings, export flow, themes, localization, and accessibility states.
- **CodexDirectorApp** owns application composition, dependency injection, windows, and app-level shared stores.

## Data authority

Agent, Skill, project instruction, plugin, and session files remain source-owned and read-only. SQLite accelerates presentation and stores Director-owned classifications and evaluations; it is not authoritative for capability file content.

Skill purposes come from top-level frontmatter descriptions, including folded
and literal block scalars. Markdown-only manifests may supply a bounded opening
prose paragraph immediately after the title; later sections, lists and code are
not purpose sources. Malformed or empty declarations remain unknown, and newly
extracted text is checked against the persistence privacy allowlist.
Chinese purposes are reviewed offline presentation copy, bound to resource ID,
kind, name and the normalized source SHA-256. Unknown or changed declarations
fall back to their current original text. The catalog does not translate future
capabilities automatically and never changes source files or folder membership.

## Refresh and concurrency

Application surfaces share one refresh coordinator. Source scanning and projection are distinct phases. Cached results appear before background refresh, failures retain the last valid projection, and late or cancelled work cannot overwrite newer state. The enabled menu bar has one app-scoped account-only scheduler: after startup grace it uses five-minute wakes while the aggregate session is active and 30-minute wakes after 30 minutes idle, backs off failed reads at 5/15/30 minutes, and pauses on lock, sleep or Low Power Mode. Its bounded wake-up never starts capability indexing or reads SQLite.

The sanitized app-server snapshot is also composed into Home as the current five-hour and weekly allowance for the canonical Codex source when it is at least as recent as that window's indexed observation. This is a presentation-only merge: indexed observations remain the sole input to the seven-day weekly chart, and live account values are never inserted into session evidence or SQLite history. The account DTO and indexed projection remain separate fields in presentation-cache schema v1 so old caches stay readable.

## Codex runtime boundary

`CodexRuntimeLocator` resolves an executable in this order: an explicit Director preference, known Codex application locations, then absolute directories from `PATH`. It invokes the executable directly without a shell, applies a timeout and output cap to version probing, and exposes source, compatibility, and execute-permission state. Director never installs Codex, changes `PATH`, edits global Codex configuration, or stores Codex account information.

If no usable runtime is available, filesystem inventory continues without runtime discovery. Capability export records plugin inventory as incomplete instead of claiming that zero plugins are installed.

Runtime discovery timestamps are sampled on each discovery pass. Production
plugin inventory uses the located Codex executable's short-lived, read-only
app-server `plugin/installed` request, not the CLI marketplace catalog. The
response is accepted as complete only when it has no marketplace-load errors,
valid canonical installed IDs, and a remote-marketplace witness. Codex can
otherwise suppress remote-fetch errors and return a success-shaped local-only
response. Incomplete reads keep last-observed rows and show an unknown current
plugin count rather than a false zero. A verified plugin identity without a
validated local package path remains countable as a plugin, but its child Skill
inventory is unknown; any last-observed children remain warnings and the Home
combined installed-Skill total stays unknown. The independently installed
Skill count remains visible. Capability export uses the same completeness
rule, and an incomplete list cannot be marked complete in `plugins.json`.
Settings diagnostics retain their last valid result during a source refresh
and reload when that index pass completes.

Rollout parser v1.3.0 recognizes the current top-level `token_usage_record`
and `inter_agent_communication_metadata` envelopes. Token totals use the
record's cumulative `thread_token_usage`, never its per-response or per-turn
value, and do not add it to legacy `token_count` totals. Legacy rate-limit
windows remain a separate evidence stream. On parser upgrade, unchanged 1.2.0
rollouts older than the 30-day ranking window are left at their existing
checkpoint; recent files and any subsequently changed older file are reparsed.
This bounds one-time historical work without altering source files.

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

Installed Skills is the independent-install category. The catalog retains
plugin-provided Skill resources and their parent attribution for folder and
plugin evidence, but excludes them from Installed Skills totals, library rows,
and seven/thirty-day rankings. A versioned Home-ranking scope marker makes
older plugin-inclusive cache rows pending until a bounded background upgrade;
the independent count remains available from the compatible cache field.

## Capability folders

Capability Folders is a presentation-only projection over the current Agent and
Skill directory. Global and project folders are derived from configuration
ownership; plugin-provided Skills are included in Global while plugin packages,
system capabilities, instructions, MCP, tools, and stale caches are excluded.
The independent `CapabilityFolderStore` persists only custom folder definitions
and many-to-many stable resource-ID memberships under its dedicated UserDefaults
key. New installs create an empty Self Training folder; existing memberships
remain unchanged across refreshes and upgrades. There is no automatic
classification, implicit membership, network access, or source-file write.

Entry search filters localized folder display names in DirectorUI and preserves
folder order. Interior and import search use the existing capability projection.
Shared native search/menu fields own full painted hit geometry without adding
queries, preference writes or indexing work.

Custom folders can be renamed, deleted, reordered, searched, and populated from
the current eligible directory through one validated atomic preference write.
Each folder exposes Agent & Companion Skills, Agent, and Skill presentation tabs. Explicit
declarations and near-seven-day co-observation evidence are separate, and a
related capability outside the current folder is preview-only. Memberships may
contain resources that are temporarily absent so a later directory projection
can restore them. Folder preferences survive derived-index deletion and are not
included in manifest v1 capability packages. Legacy capability-grouping
preferences are discarded only after the new folder document is successfully
written.

Global Agent discovery pairs a top-level `<role>.toml` with a uniquely matching
`<role>/agent.md` Brief as one stable resource. The resolver reads both local
documents for explicit declarations while retaining TOML-only and Brief-only
compatibility. Relationship history is a separate batch projection: the App
Model materializes indexed invocations once per seven-day snapshot and maps
distinct-session co-observation to relation IDs; co-observation never proves
that an Agent invoked a Skill.

## Home usage ranking periods

Home usage rankings expose recent-seven and recent-thirty local natural-day
views without changing the seven-day library, detail, relationship, or quota
contracts. One bounded thirty-day SQLite read conditionally aggregates both
periods per stable resource ID. Both Top 10 projections are published and cached
atomically; changing the selected period is therefore an in-memory presentation
operation and cannot start indexing, refresh work, account reads, or a new
database query.

The schema-v1 presentation cache keeps its original ranking fields as the
seven-day compatibility payload and adds an optional thirty-day ranking set.
`nil` means the older cache has not computed that projection, while a present
empty set means the query completed with no observed calls. The selected period
is a separate app-owned UserDefaults value containing only `7d` or `30d`; it
defaults to seven days and contains no resource metadata or usage evidence.
