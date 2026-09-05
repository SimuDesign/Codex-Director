# Privacy

Codex Director is designed for local, read-only inspection of a user's Codex capability system.

## Data read locally

Depending on the features used, the app may read Agent and Skill definitions, project instructions, plugin inventory output, local Codex session metadata, and local quota reports. Session content is parsed only to derive allowlisted evidence fields; raw prompts, arguments, outputs, tokens, cookies, and credentials must not be persisted.

## Data stored locally

Director-owned SQLite data contains normalized inventory, privacy-safe usage evidence, cache metadata, user classifications, and manual evaluations. Application preferences use Director-specific UserDefaults keys. Removing Director data does not remove source Agents, Skills, plugins, projects, or Codex sessions.

## Exports

Capability packages are unencrypted local ZIP files written only to a location selected by the user. Export preflight blocks recognized credentials and unredacted personal paths. Binary resources may be included but are marked as not content-scanned. Users are responsible for protecting exported packages and restoring only trusted packages.

## Network behavior

Core inventory, indexing, evaluation, and export do not require a Director cloud service. A user-initiated “View GitHub Releases” action opens the project page in the default browser. Codex commands invoked by the app may have their own behavior and policies; Director does not store Codex account credentials.

## Diagnostics and issues

Do not attach raw databases, sessions, capability packages, prompts, Agent or Skill bodies, credentials, cookies, usernames, or private project paths to a public issue. Reproduce problems with synthetic data whenever possible.

