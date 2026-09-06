# Privacy

Codex Director is designed for local, read-only inspection of a user's Codex capability system.

## Data read locally

Depending on the features used, the app may read Agent and Skill definitions, project instructions, plugin inventory output, local Codex session metadata, and local quota reports. Session content is parsed only to derive allowlisted evidence fields; raw prompts, arguments, outputs, tokens, cookies, and credentials must not be persisted.

When the menu-bar surface is enabled (the default for new installs), the app
starts the locally selected Codex executable on demand and requests only the read-only account
allowance endpoint. It keeps a sanitized weekly remaining percentage, reset
time, reset-card count, and capture time. Account IDs, model-specific buckets,
reset-card identifiers, credentials, and other account metadata are discarded;
the app does not log or display them. With the menu bar disabled, this reader
is not started. When enabled, a bounded account-only schedule may run after
startup: it reads only aggregate system idle duration, never event contents,
and adapts between five and thirty minutes. It pauses while the Mac is locked,
asleep, or in Low Power Mode, and does not poll, read the Director database,
or index capability files.

## Data stored locally

Director-owned SQLite data contains normalized inventory, privacy-safe usage evidence, cache metadata, user classifications, and manual evaluations. Application preferences use Director-specific UserDefaults keys. Removing Director data does not remove source Agents, Skills, plugins, projects, or Codex sessions.

## Exports

Capability packages are unencrypted local ZIP files written only to a location selected by the user. Export preflight blocks recognized credentials and unredacted personal paths. Binary resources may be included but are marked as not content-scanned. Users are responsible for protecting exported packages and restoring only trusted packages.

The menu-bar cache is part of the existing local presentation cache and remains
on the device. It is not a second account database and is never uploaded by
Codex Director. Users can disable the menu-bar surface in Settings; that
preference is local and does not contain account information.

## Network behavior

Core inventory, indexing, evaluation, and export do not require a Director cloud service. A user-initiated “View GitHub Releases” action opens the project page in the default browser. Codex commands invoked by the app may have their own behavior and policies; Director does not store Codex account credentials.

## Diagnostics and issues

Do not attach raw databases, sessions, capability packages, prompts, Agent or Skill bodies, credentials, cookies, usernames, or private project paths to a public issue. Reproduce problems with synthetic data whenever possible.
