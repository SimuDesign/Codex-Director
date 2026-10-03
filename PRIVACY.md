# Privacy

Invocation observation stores only fixed evidence provenance values, stable
resource/session IDs and existing normalized timing, status and confidence.
Role names, working directories, manifest aliases, source ordinals and tool
arguments are used transiently for identity resolution, never copied into the
new provenance field. Historical repair changes only Director-owned derived
rows and checkpoints; capability files, Codex logs, folders and evaluations
are not cleared or rewritten.

调用观测仅新增固定类型的证据来源，沿用稳定 ID、时间、状态和可信度。
角色、工作目录、文件别名、原始序号与工具参数仅用于瞬时解析。
历史修复只更新 Director 的派生记录和检查点，不清空或改写能力源文件、
Codex 日志、文件夹及评价。

Codex Director is designed for local, read-only inspection of a user's Codex capability system.

## Data read locally

Depending on the features used, the app may read Agent and Skill definitions, project instructions, plugin inventory output, local Codex session metadata, and local quota reports. Session content is parsed only to derive allowlisted evidence fields; raw prompts, arguments, outputs, tokens, cookies, and credentials must not be persisted.

During an existing source refresh or a user-requested capability export, Director may ask the locally selected Codex executable for its installed-plugin list through the read-only `plugin/installed` app-server method. Director sends no project paths or credentials, does not invoke plugin installation or removal, and discards the raw response after retaining minimal plugin identity and status fields. Codex itself may use its existing account connection or local catalog cache to answer; Director does not make a separate plugin-network request. An incomplete response is not treated as an empty installed list.

When the menu-bar surface is enabled (the default for new installs), the app
starts the locally selected Codex executable on demand and requests only the read-only account
allowance endpoint. It keeps a sanitized weekly remaining percentage, reset
time, reset-card count, and capture time. Account IDs, model-specific buckets,
reset-card identifiers, credentials, and other account metadata are discarded;
the app does not log or display them. With the menu bar disabled, this reader
is not started. When enabled, a bounded account-only schedule may run after
startup. It transiently compares the system-reported frontmost application's
bundle identifier with the exact validated Codex identifier, keeps only a safe
foreground enum and the last confirmed Codex departure time in memory, and
reads aggregate system idle duration. It uses one minute while Codex is
frontmost, two minutes during the ten-minute departure grace or when identity
is unknown, five minutes for another active application outside grace, and
thirty minutes after thirty minutes idle. Foreground identity does not reveal
whether a Codex task is running in the background. The app does not read or
persist window, task or input-event contents or application-activity history.
It pauses while the Mac is locked, asleep, or in Low Power Mode, and does not
read the Director database or index capability files during account checks.

## Data stored locally

Director-owned SQLite data contains normalized inventory, privacy-safe usage evidence, cache metadata, user classifications, and manual evaluations. Application preferences use Director-specific UserDefaults keys. Removing Director data does not remove source Agents, Skills, plugins, projects, or Codex sessions.

Capability folder preferences use a separate Director-owned UserDefaults key
and contain only custom folder names, stable resource IDs, and folder IDs.
They do not contain source paths, capability bodies, prompts, sessions, or
account data. Folder membership is edited locally by the user; no AI service or
network request is used. Folder preferences are retained when derived index
data is deleted and are not added to capability packages.

The separate `com.peiweitang.CodexDirector.capabilityFolders.usagePeriod`
preference stores only `7d` or `30d`. Folder counts reuse existing derived
observations across all usage projects. Changing period or sort starts no
source scan, account read, analytics request or additional database query.
No usage content or project paths are added to this preference.

## Exports

Capability packages are unencrypted local ZIP files written only to a location selected by the user. Export preflight blocks recognized credentials and unredacted personal paths. Binary resources may be included but are marked as not content-scanned. Users are responsible for protecting exported packages and restoring only trusted packages.

## Restore quarantine

Before any restore target write, Codex Director creates an operation-scoped private directory with mode 0700 inside each approved local mapping root. Failure cleanup and in-session Undo never unlink restored objects. They move only objects that can still be verified as created and unchanged into the private quarantine; changed, replaced, moved, or uncertain objects remain in place and are reported. Quarantine contents are never automatically deleted by the app. An in-memory local URL supports an explicit “Reveal in Finder” action, but the raw path is not rendered, logged, cached, written to the package, or persisted as a rollback receipt. Users may inspect and manually delete quarantine contents outside the app when ready.

The menu-bar cache is part of the existing local presentation cache and remains
on the device. It is not a second account database and is never uploaded by
Codex Director. Users can disable the menu-bar surface in Settings; that
preference is local and does not contain account information.

## Network behavior

Core inventory, indexing, evaluation, and export do not require a Director cloud service. A user-initiated “View GitHub Releases” action opens the project page in the default browser. Codex commands invoked by the app may have their own behavior and policies; Director does not store Codex account credentials.

## Diagnostics and issues

Do not attach raw databases, sessions, capability packages, prompts, Agent or Skill bodies, credentials, cookies, usernames, or private project paths to a public issue. Reproduce problems with synthetic data whenever possible.
