# Codex Director 1.3.0 — Capability Folders

## Scope

Capability Folders replaces the unpublished Capability Groups experiment. The
feature is a local browsing and organization surface for indexed Agents and
Skills. It does not classify, rewrite, execute, upload, or install anything.

- The primary navigation entry is **Capability Folders**, immediately after
  Home.
- First initialization creates one empty custom folder with the stable ID
  `self-training`. Its display name is localized until the user renames it;
  existing memberships are preserved during upgrades and no catalog load adds
  members implicitly.
- Users may create, rename, delete, reorder, and search custom folders. A
  resource may belong to multiple custom folders.
- Global and Project folders are derived from read-only configuration
  ownership. Plugin-provided Skills are shown in Global; plugin packages,
  system capabilities, instructions, MCP, tools, and stale caches are omitted.
- The page uses one native `List`, a Hero, global search, custom-folder cards,
  derived Global/Project cards, and recent usage/name sorting. Every folder
  contains the fixed tabs `Agent & Companion Skills`, `Agent`, and `Skill`;
  existing capability detail sheets remain the detail surface.
- Custom cards use the shared responsive 4/2/1 grid and native drag-and-drop;
  keyboard and VoiceOver users can use the folder menu's Move up/Move down
  actions. Each window retains the entry search plus per-folder search, type,
  sort, and scroll-position state for the lifetime of the session.
- Every Agent/Skill row and detail sheet exposes a multi-select folder menu;
  folder pages additionally offer a direct Remove from folder action.
- Every custom folder also exposes an **Add existing capabilities** sheet with
  search, Agent/Skill filtering, staged multi-selection, and one atomic save.
- Explicit Agent/Skill companion declarations are resolved from project
  registry metadata, Agent TOML/Brief `$skill` directives, and Skill
  `Use through`/`需通过` frontmatter. Historical co-observation is shown as
  separate evidence and never creates a relationship.

## Persistence contract

`CapabilityFolderStore` stores version-one JSON under
`com.peiweitang.CodexDirector.capabilityFolders.v1`. It contains only:

- `initialized`
- optional `selfTrainingSeedVersion` retained only for decoding unpublished
  earlier builds; it is never used to seed new memberships
- ordered custom folder definitions (stable IDs and optional user names)
- many-to-many `(folderID, resourceID)` memberships

It never stores paths, capability text, project paths, prompts, sessions, or
statistics. Stale resource IDs remain so a later directory projection can
restore memberships. Folder preferences survive derived-index deletion and are
not included in `.codexpack.zip`.

New Self Training remains empty until the user explicitly imports capabilities.
Global and project folders expose their read-only eligible members directly;
plugin-provided Skills appear in Global. Custom folders can import eligible
Agents and Skills through the explicit import sheet. Instructions and system
resources are never eligible for folder membership or import. Existing
membership edges from an earlier unpublished build are preserved verbatim.

The old `capabilityGrouping.v1` document is treated as legacy data only. The
new Self Training document is written successfully before the legacy key is
removed; failed writes leave legacy bytes untouched. Old categories and
assignments are intentionally not migrated.

## Interaction and privacy rules

- Global and Project folders are immutable derived views; custom folders are
  the only valid membership targets.
- Folder names are trimmed, limited to 1–40 characters, and unique under
  case/diacritic-insensitive comparison.
- Deleting a custom folder removes only that folder and its membership edges;
  capability files and index data are unchanged.
- Project display names are localized and duplicate names receive a short
  stable ID. Absolute paths are never presented or persisted.
- Missing statistics render as `—` and sort after known values; they are not
  treated as zero.
- Folder operations do not start indexing, quota/account reads, statistics
  queries, network requests, or source-file writes.
- Batch import validates every selected stable resource ID before one
  preference write; an invalid ID or persistence failure leaves the whole
  selection unapplied.

## Verification

Core tests cover first-use initialization, empty Self Training compatibility,
one-way legacy cleanup, failed-write preservation, validation,
multi-membership, atomic batch import, default ownership projection, duplicate
project names, stale IDs, safe deletion, exact declaration resolution, scope
precedence, and separate co-observation evidence. UI validation covers the
native list, seven-entry navigation, bilingual copy, Light/Dark themes, three
folder tabs, import selection, folder/search/filter/sort behavior, detail
sheets, reverse Agent links, keyboard/VoiceOver ordering, and empty/error
states. Release gates remain the full Swift test suite,
`./scripts/verify.sh`, public audit, and Release build.
