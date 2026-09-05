# Architecture

Codex Director separates local source discovery from Director-owned projections and presentation.

## Layers

- **DirectorCore** discovers local resources, parses allowlisted evidence, coordinates refresh, persists projections and evaluations, and builds capability packages.
- **DirectorUI** renders the six primary destinations, detail flows, settings, export flow, themes, localization, and accessibility states.
- **CodexDirectorApp** owns application composition, dependency injection, windows, and app-level shared stores.

## Data authority

Agent, Skill, project instruction, plugin, and session files remain source-owned and read-only. SQLite accelerates presentation and stores Director-owned classifications and evaluations; it is not authoritative for capability file content.

## Refresh and concurrency

Application surfaces share one refresh coordinator. Source scanning and projection are distinct phases. Cached results appear before background refresh, failures retain the last valid projection, and late or cancelled work cannot overwrite newer state.

## Codex runtime boundary

`CodexRuntimeLocator` resolves an executable in this order: an explicit Director preference, known Codex application locations, then absolute directories from `PATH`. It invokes the executable directly without a shell, applies a timeout and output cap to version probing, and exposes source, compatibility, and execute-permission state. Director never installs Codex, changes `PATH`, edits global Codex configuration, or stores Codex account information.

If no usable runtime is available, filesystem inventory continues without runtime discovery. Capability export records plugin inventory as incomplete instead of claiming that zero plugins are installed.

## Capability packages

Exports use manifest v1 with checksums, logical roots, path placeholders, plugin inventory, dependency inventory, and bilingual recovery instructions. Packages are local and unencrypted. The app verifies the completed ZIP before moving it to the user-selected destination.

## Privacy boundary

Only allowlisted normalized evidence reaches persistence. Prompts, arguments, raw outputs, credentials, cookies, session bodies, and unredacted personal paths are excluded.
