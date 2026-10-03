# Codex Director 1.4.3：菜单栏自适应额度刷新开发计划

> **Implementation owner:** Software Engineer. Execute the tasks below in this session, then hand off to a separate, read-only Quality Engineer. The user has authorized development and the project's verified local installation workflow. No GitHub push, Tag or Release is part of this task.

**Goal:** 常驻菜单栏额度根据 Codex 前台使用、离开后的缓冲、其他应用使用和电脑闲置自动采用 1／2／5／30 分钟节奏，不要求打开弹窗。

**Architecture:** 继续使用 App 级 `AccountUsageRefreshScheduler` 与唯一共享刷新协调器，只读取账户额度。用 `NSWorkspace` 前台应用身份及聚合 HID 闲置时长驱动一个可注入、可确定性测试的策略；所有前台与离开时间状态仅保存在内存中。调度保持单一有界唤醒，系统信号、快照发布和策略切换不能重置失败退避或制造重复读取。

**Tech Stack:** Swift 6、macOS 26+、AppKit `NSWorkspace`、Foundation、现有本地 Codex app-server 和 Swift XCTest。不新增依赖、数据库、权限或界面控件。

---

## Approved behavior

| Priority | State | Account read interval |
| --- | --- | --- |
| 1 | 菜单栏关闭 | 不观察、不计时、不读取 |
| 2 | 锁屏、睡眠、低电量模式 | 暂停被动读取 |
| 3 | 聚合键鼠闲置至少 30 分钟 | 30 分钟，即使 Codex 仍是前台应用 |
| 4 | 已确认 Codex 是前台应用 | 1 分钟 |
| 5 | 已确认离开 Codex、未满 10 分钟 | 2 分钟 |
| 6 | 已确认其他应用在前台、无缓冲或缓冲已结束 | 5 分钟 |
| Fallback | 前台身份未知，电脑尚未闲置 | 2 分钟，不猜测 Codex 或其他应用 |

- “前台”是系统报告的接收键盘事件的应用，不是窗口可见、进程存在或 CPU 使用率。
- 当前安装的运行时宿主经本地 `Info.plist` 验证：Bundle ID 为 `com.openai.codex`。其安装目录和 Bundle 名称虽包含 ChatGPT，不能因此扩大匹配到其他聊天应用。按已确认 Bundle ID 精确匹配，不按名称、路径片段或窗口标题模糊匹配。
- `Codex -> other` 的确认切换才开始 10 分钟缓冲。切换其他应用之间不延长缓冲；切回 Codex 立即结束缓冲。启动时其他应用在前台不伪造最近离开记录；未知状态不制造离开事件。
- 暂停、电脑闲置和缓冲计时使用实际时间；重新解锁不重新开始缓冲。关闭功能或重新启动应用不保留前台／离开记录。时钟倒退时不将未来离开时间当作永久有效缓冲，沿用保守未知和缓存回退。
- 后台是否在执行 Codex 任务仍为未知。不调用线程恢复、任务操作或读取会话正文来判断，不把前台状态描述为后台任务状态。
- 打开弹窗继续对缺失、过期或至少 2 分钟前的数据合并一次账户读取。手动“刷新数据”继续执行已批准的完整手动刷新。所有入口共用同一协调器。
- 最早有效重置时间仍可提前触发正常读取；失败保留旧值并采用 5／15／30 分钟退避。自动策略／系统通知不得越过退避；明确手动操作保持现有强制读取语义。

## Current baseline and preservation

- Public workspace baseline is `main` plus the already implemented local 1.4.2 changes; preserve all of those edits, tests and existing folder memberships.
- Work on `codex/menu-bar-adaptive-refresh-1.4.3`. Version becomes `1.4.3 (31)`; parser, presentation-cache schema v1 and capability-package manifest v1 remain compatible.
- Do not touch the private archive workspace, source Agents/Skills, Codex configuration, sessions or user folder preferences. Do not stage, revert, commit or push another owner's changes.

## Task 1 — Deterministic activity policy

**Files:** `Sources/DirectorUI/AppShell/AccountUsageRefreshScheduler.swift`; optionally a focused adjacent policy file; `Tests/DirectorUITests/AccountUsageRefreshSchedulerTests.swift`.

1. Add meaningful tests for all policy rows, 10-minute and 30-minute boundaries, startup without departure history, unknown identity and clock rollback. Use injected dates and synthetic identity only.
2. Extend the small system-state DTO with safe foreground state and in-memory last confirmed departure state. Keep the existing initializer compatible with conservative defaults.
3. Implement pure cadence and next-policy-boundary calculations using an injected `now`, not a hidden `Date()` inside the policy. Keep a single definition for each interval and threshold.
4. Run the focused scheduler tests and verify policy transitions before integrating the OS adapter.

## Task 2 — Native foreground adapter

**Files:** `Sources/DirectorUI/AppShell/AccountUsageRefreshScheduler.swift`; adapter-focused tests in `Tests/DirectorUITests/AccountUsageRefreshSchedulerTests.swift` or an adjacent file.

1. Inject an initial frontmost identity reader and a notification seam. Read `NSWorkspace.frontmostApplication` and observe `NSWorkspace.didActivateApplicationNotification` on the workspace's notification center.
2. Immediately seed the actual current foreground state after enabling. Capture only a safe enum and last departure time. App identity may be compared transiently; never retain lists of other apps, app paths, window titles, key events or task contents.
3. On confirmed Codex-to-other transitions record departure once; other-to-other transitions leave it unchanged; returning to Codex ends the grace period. Treat nil/unrecognized identity conservatively.
4. Preserve lock/sleep/power observation and correctly remove all observers on stop. A delayed notification from an earlier monitoring generation must not republish state after disable or contaminate a later start.
5. Test exact bundle identity, same-name impostors, unknown state, initial state, observer cleanup and delayed notification safety.

## Task 3 — One scheduler, stable deadlines

**Files:** `Sources/DirectorUI/AppShell/AccountUsageRefreshScheduler.swift`; `Sources/DirectorUI/AppShell/DirectorAppModel.swift` only if necessary for existing integration; scheduler/refresh tests.

1. Anchor normal account deadlines to the latest successful snapshot's capture time, using the current policy. Foreground activation may bring a stale read forward; it must not read again when the snapshot is still within the new interval.
2. Maintain a distinct next account-read deadline and next local wake deadline. A local wake can recheck aggregate idle state or a grace boundary without launching Codex. Use one one-shot wake, with local activity checks at most once per minute when needed to recover the fastest cadence, and no additional repeating timer.
3. At every wake, reevaluate the current policy before starting an automatic account request. Switching to a slower interval must not let an older, earlier wake force a premature read. Expiring the 10-minute grace period changes policy without itself forcing a process start.
4. Anchor failure retry deadlines to the failure result. Repeated foreground, power or cache notifications must neither restart the 5／15／30-minute wait nor bring it forward. Successful reads reset backoff. Preserve explicit manual behavior.
5. Preserve initial startup grace, earliest reset handling, generation-based cancellation, final eligibility gate and shared request coalescing. Missing/expired snapshots must not create a zero-delay loop.
6. Test foreground one-minute reads with the popover closed, rapid switching, earlier/later policy transitions, grace expiry, anchored retry under repeated notifications, idle no-read checkpoints, reset deadlines, stop/re-enable and multiwindow/manual merge behavior.

## Task 4 — Version and public documentation

**Files:** `project.yml`, `CodexDirector.xcodeproj/project.pbxproj`, version fallback/metadata consumers, `Tests/DirectorUITests/DirectorSchemeATests.swift`, `README.md`, `README.zh-CN.md`, both CHANGELOG files, `PRIVACY.md`, `docs/ARCHITECTURE.md`, `docs/RELEASE.md`, `.design/codex-director/DESIGN_SYSTEM_V1.md`, `.design/codex-director/VALIDATION_PLAN.md`.

1. Set production identity to `1.4.3 (31)` and synchronize current version sources. Keep historical entries and intentionally frozen synthetic fixture versions unchanged.
2. Describe the four cadences, ten-minute grace, unknown fallback and foreground-versus-background limitation in bilingual product notes. Preserve simple visible version formatting.
3. Document transient foreground identity comparison and in-memory departure time. State that no window, task, event contents or activity history are persisted.
4. Update current validation contracts without introducing visual changes or altering historical performance evidence.

## Task 5 — Implementation verification and handoff

完整验证发现既有账户读取进程存在退出竞态：读取回调可能在管道关闭后访问 `FileHandle`，触发不可捕获的 Foundation 异常。独立验收还识别出启动与立即取消的相邻竞态。作为本轮可靠性发布门，批准仅在 `Sources/DirectorCore/MenuBar/CodexAccountUsageReading.swift` 串行化启动／取消和读取／关闭，并在获得相关锁后重新检查结束状态；协议、输出和数据契约不变。`CodexAccountUsageReadingTests` 增加有界并发退出和立即取消回归，独立重复验证，并由 Quality Engineer 检查锁顺序、取消界限、超时和无遗留进程。

验收同时要求补测双窗口较早重置的精确边界及启动时单窗口已过期的补读，不能因另一窗口仍可用而漏读，也不能产生快速读取循环；聚合闲置读取必须平衡 Create-rule 的 Core Foundation 对象所有权，避免持续检查累积泄漏。这些修正限于现有账户读取与调度文件，不改变业务数据契约或索引范围。

Run from the public workspace:

```sh
swift test --disable-sandbox --scratch-path /tmp/codex-director/build --filter 'AccountUsageRefreshSchedulerTests|MenuBarRefreshTests|MenuBarContractTests|DirectorSchemeATests'
swift test --disable-sandbox --scratch-path /tmp/codex-director/build --filter 'CodexAccountUsageReadingTests'
./scripts/verify.sh
./scripts/audit-public-release.sh --all
./scripts/build-local-app.sh
git diff --check
```

Expected: focused and required checks pass; complete Swift tests report zero failures; optional heavy benchmarks may retain documented skips; privacy audit passes; Release bundle verifies `1.4.3 (31)`, arm64 and x86_64, ad-hoc signature and no production private paths. Inspect the new plan as well as tracked files for public-data boundaries.

Return the final diff, exact test results, output log paths, unverified runtime limits and the minimal reviewer handoff. Do not install or approve the implementation yourself. If the native foreground seam cannot meet the contract, return the specific gap to the parent rather than silently broadening identity or reading content.

## Task 6 — Independent acceptance and local installation

- A separate Quality Engineer directly reviews the final source and tests, reruns proportionate focused checks, verifies the preserved contracts and issues `passed` or `blocked`. It does not edit production code or self-approve remediation.
- After acceptance, the parent uses `./scripts/install-local-app.sh`: quit the installed app, retain the previous verified bundle in a unique Trash location, install and verify the matching Release artifact, then relaunch.
- Validate actual foreground identity and at least two approximately one-minute account cache updates with the popover closed. Unit tests cover the 10-/30-minute boundaries without making the user wait for real long idle periods. Confirm folder preference identity is unchanged and do not expose real capability or account content in evidence.
- GitHub publication, Tag and Release require their own task; no remote action is implied here.

## Execution record — 2026-10-02

- Software Engineer 已完成生产实现，独立 Quality Engineer 最终判定 `passed`，无未解决 P0／P1／P2。
- 最终组合测试 78／78 通过；完整 XCTest 执行 979 项，976 项通过、3 项可选性能测试跳过、0 失败。独立验收另完成账户读取 25／25 和竞态重复 20／20。
- 公共历史／隐私审计、版本／依赖／许可契约、`git diff --check` 和 Release 验证通过；产物为 `1.4.3 (31)`、macOS 26、arm64＋x86_64、ad-hoc 签名。
- 已按批准流程覆盖安装，旧版保留在可恢复的废纸篓位置；安装后可执行文件与验证产物一致，文件夹偏好哈希与安装前一致。
- 真实运行中确认 Codex 前台且菜单弹窗关闭，连续两次账户缓存更新间隔为 64.4 秒、62.2 秒；期间本地源检查时间未变，符合仅账户读取契约。
- 10／30 分钟边界、锁屏／睡眠／低电量、未知身份和失败退避使用合成状态验证；不将这些测试描述为真实长时间 OS 验证。未提交、推送、创建 Tag 或 Release。

## Primary references

- [Apple: frontmostApplication](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication)
- [Apple: didActivateApplicationNotification](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification)
- [Codex app-server](https://learn.chatgpt.com/docs/app-server): existing read-only allowance boundary; thread lifecycle events belong to loaded/subscribed server threads and are not evidence that a separate desktop app is running a task.
