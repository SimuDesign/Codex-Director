# Codex Director 1.0 Open-Source Release Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在不加入 Apple Developer Program 的前提下，把 Codex Director 发布为一个隐私边界清晰、可从源码构建、可验证下载来源，并具备稳定核心体验的 macOS 开源 1.0 产品。

**Architecture:** 保持现有 SwiftUI、DirectorCore、SQLite 和只读源数据边界。1.0 新增的菜单栏只复用 App 级模型、缓存和刷新协调器，不创建第二套索引链路；Codex 运行时发现由独立服务负责，不再依赖单一硬编码路径。GitHub 是源码与 Release 的发布面，应用不实现自动下载或安装更新。Release 二进制使用临时 CI 环境构建、ad-hoc 签名、SHA-256 与 GitHub artifact attestation 验证，并明确标注“未使用 Developer ID、未公证”。

**Tech Stack:** Swift 6、SwiftUI、Swift Package Manager、XcodeGen、SQLite、ZIPFoundation 0.9.20、XCTest、GitHub Actions、GitHub Releases、GitHub Artifact Attestations。

---

## 1. 1.0 产品定义

### 1.1 必须成立的用户承诺

1. 用户能够看懂自己已拥有的 Agent、Skill、插件和近期使用证据，并知道数据是否新鲜、缺失或不可用。
2. 用户无需把本地能力内容、会话、Token 或 Cookie 上传到任何服务。
3. 用户可以导出标准 `.codexpack.zip` 能力包，通过任意存储方式迁移；1.0 继续使用辅助恢复说明，不承诺 Director 内一键恢复。
4. 用户可选开启菜单栏入口，快速查看当前额度和下次重置时间；菜单栏不得展示提示词、任务名、项目路径、命令参数或能力正文。
5. 用户可以从公开仓库审阅并构建源码，也可以下载一份来源可验证但未经 Apple 公证的社区构建。
6. 应用找不到或不兼容 Codex 运行时时，必须给出可行动的诊断，不能静默显示为零数据。

### 1.2 1.0 明确不做

- 不接入 GitHub OAuth、GitHub App、云备份、定时备份或后台上传。
- 不实现静默更新、自动下载、自动替换应用或 Sparkle 更新链路。
- 不实现 Director 内确定性恢复、项目冲突合并编辑器或自动安装插件。
- 不扩展到 macOS 26 以下、Windows 或 Linux 的完整应用支持。
- 不注册登录项；“登录时启动”推迟到 1.1，避免把未公证应用的系统集成和首发风险绑在一起。
- 不为了 1.0 重写数据库或索引架构；只有新的性能证据证明必要时才做局部优化。

## 2. 关键决策

### 2.1 开源仓库策略

当前仓库匿名访问返回 404，至少尚不可公开访问；当前 Git 历史只有少量提交，适合在公开前完成一次干净基线处理。审计已发现：13 个被跟踪文件包含个人 Home 绝对路径，17 个文件包含私有临时目录路径，仓库还包含多张体积较大的设计与验证图片。

推荐策略：保留现有 GitHub 仓库地址，但在仓库仍为私有时完成清理；先创建可恢复的本地 Git bundle，再将公开分支重建为一条经过审计的初始提交。历史重写和远端强制更新属于破坏性动作，必须单独取得用户明确批准后执行。

备选策略：保留当前仓库为私有档案，从净化后的工作树创建一个新的公开仓库。若任何历史、媒体授权或个人信息无法确定，必须采用此方案。

禁止策略：只在最新提交删除敏感内容后直接把现有仓库设为公开。旧提交仍可被访问，不满足公开边界。

### 2.2 许可策略

默认建议采用 MIT License，与 ZIPFoundation 的许可模型一致，降低个人项目的使用和贡献门槛。公开前必须由用户确认版权主体应写个人法定姓名还是 `SimuDesign`。

如果用户要求所有衍生发行也保持开源，则改用 GPL-3.0-only；该选择会改变下游使用边界，不在实施时自行推断。

代码许可和素材许可分开处理：

- `LICENSE` 覆盖自有源代码。
- `THIRD_PARTY_NOTICES.md` 保留依赖许可。
- `ASSETS_LICENSE.md` 逐类声明 logo、截图、示意图和字体的来源及许可。
- 无法证明可公开的图片、真实数据截图或参考素材从公共仓库移除，不以“已生成”代替授权判断。

### 2.3 发布策略

采用“源码优先 + 可选社区构建”的混合方案：

- GitHub 仓库是源码、构建说明、隐私说明和问题追踪的事实源。
- GitHub Release 提供 universal macOS ZIP，文件名固定为 `Codex-Director-<version>-macOS-26-unnotarized.zip`。
- Release 同时提供 `SHA256SUMS.txt`、`BUILD-INFO.json`、依赖锁文件和 artifact attestation。
- 二进制继续使用 hardened runtime + ad-hoc 签名。ad-hoc 签名只保证包内代码完整性，不代表 Apple 身份或公证。
- README、安装文档和每个 Release 都必须明确说明 Gatekeeper 警告以及 macOS“仍要打开”的官方处理路径。
- 不指导用户全局关闭 Gatekeeper，也不提供宽泛的递归 `xattr` 绕过命令。
- 1.0 应用内只提供用户主动触发的“查看 GitHub Releases”，交给浏览器打开 Release 页面；不做后台版本探测，保持“应用本身不联网”的承诺清晰。

### 2.4 菜单栏策略

菜单栏功能值得进入 1.0，但必须是主应用的轻量投影，而不是第二个产品：

- 使用原生 `MenuBarExtra` 和模板图标；可附带短额度状态。
- 用户在设置中主动开启，默认关闭，避免升级后突然常驻菜单栏。
- 弹窗只展示当前来源、额度剩余比例、数据状态、下次重置倒计时、刷新和打开主窗口。
- 关闭主窗口后，菜单栏读取现有缓存并在本地更新倒计时；不得持续重建拓扑、统计或全量索引。
- 弹窗打开且数据过期时只发起额度域刷新；能力索引仍遵循主应用的共享刷新协调器。
- 无来源、缺测、过期、刷新中和失败必须是不同状态；未知值不得显示为 `0%`。

## 3. 里程碑

| 里程碑 | 版本建议 | 目标 | 发布形态 |
| --- | --- | --- | --- |
| M0 | 不发版 | 公共边界、许可、历史和媒体审计 | 仓库保持私有 |
| M1 | 0.4.0 (17) | 运行时发现、诊断、性能与故障基线 | 私有测试构建 |
| M2 | 0.6.0 (18) | 菜单栏薄客户端与设置项 | 私有测试构建 |
| M3 | 0.9.0 (19) | 开源文档、CI、Release Candidate | GitHub prerelease |
| M4 | 1.0.0 (20) | 关闭阻断项并公开发布 | GitHub public release |

如中间增加候选版本，`CURRENT_PROJECT_VERSION` 必须继续单调递增，不能为了匹配表格回退构建号。

## 4. 实施任务

### Task 1：建立公共发布审计门

**Files:**

- Create: `scripts/audit-public-release.sh`
- Create: `Tests/Scripts/test-audit-public-release.sh`
- Modify: `.gitignore`
- Modify: `scripts/verify.sh`

**Step 1: 先写失败测试**

测试脚本创建隔离 fixture，覆盖真实个人 Home 路径、私钥头、常见 Token/Cookie、`.env`、本地数据库、能力包、会话、Xcode 用户状态，以及允许的 `{{HOME}}`、`/Users/example` 和合成测试标记。

**Step 2: 运行测试确认失败**

Run: `bash Tests/Scripts/test-audit-public-release.sh`

Expected: FAIL，因为审计脚本尚不存在。

**Step 3: 实现最小审计脚本**

脚本只扫描 Git 跟踪内容和 Git 历史对象，不遍历用户 Home；输出隐私安全的仓库相对路径。至少检查：

- 真实用户名绝对路径和私有临时路径。
- 私钥、GitHub Token、Cookie、Bearer、`.env`、证书和 provisioning profile。
- SQLite、日志、会话、导出包、崩溃报告和 Xcode 用户状态。
- 图片 EXIF、文件名和清单中的个人信息。
- 超过阈值的大文件，要求进入人工素材审查清单。

高熵或关键字扫描只生成候选项，不把代码中的普通 `token` 字段误判为泄漏；阻断规则应基于更具体的格式和 allowlist。

**Step 4: 接入本地验证**

`scripts/verify.sh` 在单元测试前运行工作树审计；Git 历史扫描单独由公开发布工作流运行，避免日常开发重复高成本操作。

**Step 5: 验证**

Run:

```bash
bash Tests/Scripts/test-audit-public-release.sh
./scripts/audit-public-release.sh --tracked
./scripts/verify.sh
```

Expected: fixture 测试通过；仓库审计在尚未清理时明确失败并给出相对路径。

### Task 2：净化公开工作树与历史

**Files:**

- Modify: `HANDOFF.md`
- Modify: `docs/plans/**`
- Modify: `docs/releases/**`
- Modify: `docs/prompts/**`
- Review/Remove: `docs/design/**`
- Create: `docs/public-asset-inventory.md`

**Step 1: 生成待处理清单**

Run:

```bash
./scripts/audit-public-release.sh --tracked --report docs/public-release-audit.txt
git ls-files -z | xargs -0 du -h | sort -h
```

报告只在私有准备阶段使用，完成后不得提交包含真实路径或密钥候选值的原始报告。

**Step 2: 替换或移除私人事实**

- 文档中的 Home 与项目路径改为 `{{HOME}}`、`{{PROJECT}}`、`{{TMP}}`。
- 把个人安装记录、机器哈希、内部备份路径和账号状态改为通用说明或移出公共仓库。
- 测试 fixture 使用合成姓名、项目和目录。
- `HANDOFF.md` 仅保留通用贡献边界；私人操作日志迁出仓库。

**Step 3: 逐张审查媒体**

在 `docs/public-asset-inventory.md` 记录每个保留媒体的来源、自有/第三方状态、是否含真实能力名或路径、是否含 EXIF，以及保留理由。大尺寸重复草图和无发布价值的验证截图移出公共仓库，降低当前约 39 MiB Git pack 的历史负担。

**Step 4: 验证当前树**

Run:

```bash
./scripts/audit-public-release.sh --tracked
git diff --check
```

Expected: 无个人路径、凭证、私有数据或未登记大文件阻断项。

**Step 5: 历史处理审批门**

在用户确认后才执行以下二选一操作：

1. 推荐：先创建本地 Git bundle 作为私有可恢复档案，再把同一远端的公开分支重建为一条净化后的初始提交。
2. 保守：保留当前远端为私有档案，将净化快照推到一个新的公开仓库。

未经明确批准，不重写历史、不 force push、不切换仓库可见性。

### Task 3：补齐开源治理与用户文档

**Files:**

- Create: `LICENSE`
- Create: `README.zh-CN.md`
- Rewrite: `README.md`
- Create: `PRIVACY.md`
- Create: `SECURITY.md`
- Create: `CONTRIBUTING.md`
- Create: `CHANGELOG.md`
- Create: `ASSETS_LICENSE.md`
- Create: `docs/INSTALL.md`
- Create: `docs/BUILDING.md`
- Create: `docs/ARCHITECTURE.md`
- Create: `docs/RELEASE.md`
- Create: `.github/ISSUE_TEMPLATE/bug_report.yml`
- Create: `.github/ISSUE_TEMPLATE/feature_request.yml`
- Create: `.github/pull_request_template.md`

**Step 1: 确认许可与版权主体**

默认 MIT；若用户选择 GPL-3.0-only，则同步调整 README、贡献指南和素材说明。版权主体必须由用户确认。

**Step 2: 以用户风险为中心重写 README**

中英文 README 首屏说明：产品用途、macOS 26+、本地只读边界、截图、源码构建、社区构建、未公证警告、验证下载、问题反馈。不要把“开源”表述成 Apple 已验证。

**Step 3: 写安装与构建文档**

安装文档分别覆盖：

- 从源码构建。
- 下载 GitHub Release、校验 SHA-256 与 attestation。
- 首次打开遇到 Gatekeeper 警告时使用 macOS 官方“仍要打开”流程。
- 完全删除应用和本地 Director 数据的方法，明确不会删除源 Agent、Skill 或会话。

**Step 4: 写安全与隐私披露**

- 安全问题使用 GitHub private vulnerability reporting；不要要求在公开 Issue 粘贴日志。
- Issue 模板默认提醒移除用户名、项目路径、会话、Token 和能力正文。
- 隐私文档区分应用读取内容、本地存储、导出包、插件命令和用户主动打开 GitHub 的行为。

**Step 5: 验证链接与双语一致性**

Run: `./scripts/verify.sh`

Expected: 所有仓库内链接存在；中英文对安全边界、系统要求和未公证状态没有冲突。

`CODE_OF_CONDUCT.md` 可在出现外部贡献者或社区管理需求时补充，不作为 1.0 阻断项。

### Task 4：消除版本与构建脚本漂移

**Files:**

- Modify: `project.yml`
- Modify: `scripts/build-local-app.sh`
- Create: `scripts/read-project-version.sh`
- Create: `Tests/Scripts/test-version-contract.sh`

**Step 1: 写版本契约测试**

覆盖 marketing version、build number、Info.plist、Release 文件名和 tag 的一致性，以及 build number 必须大于当前发布值。

**Step 2: 从项目配置读取版本**

删除 `build-local-app.sh` 内硬编码的 `0.3.1 (16)` 检查，由脚本从 `project.yml` 和构建产物读取并交叉验证。不要新增第二个可编辑版本事实源。

**Step 3: 验证**

Run:

```bash
bash Tests/Scripts/test-version-contract.sh
./scripts/build-local-app.sh
```

Expected: 构建脚本能发现版本漂移；生成应用仍通过 bundle ID、架构、资源、许可、隐私路径和签名检查。

### Task 5：实现 Codex 运行时发现与兼容诊断

**Files:**

- Create: `Sources/DirectorCore/Discovery/CodexRuntimeLocator.swift`
- Create: `Sources/DirectorCore/Discovery/CodexRuntimeStatus.swift`
- Create: `Tests/DirectorCoreTests/CodexRuntimeLocatorTests.swift`
- Modify: `Sources/CodexDirectorApp/AppContainer.swift`
- Modify: `Sources/DirectorUI/Settings/SettingsView.swift`
- Modify: `Sources/DirectorUI/Localization/LocalizedText.swift`

**Step 1: 写失败测试**

覆盖发现优先级：用户选择路径 > 已知应用 bundle > `PATH`；同时覆盖不存在、不可执行、版本不可解析、版本不兼容、权限不足和多候选冲突。

**Step 2: 实现只读 locator**

locator 返回路径、来源、版本和状态，不启动安装、不修改 Codex 配置。用户自定义路径只保存在 Director 专用 UserDefaults 键中，不保存账号或凭证。

**Step 3: 替换硬编码路径**

`AppContainer` 通过注入的 locator 建立运行时客户端；测试和验证 Host 使用内存实现，不读取生产偏好。

**Step 4: 增加设置诊断**

设置页展示当前来源、版本、最后成功检查时间和可行动错误。路径显示使用隐私安全折叠形式；复制完整路径必须是明确用户动作。

**Step 5: 验证**

Run:

```bash
swift test --filter CodexRuntimeLocatorTests
./scripts/verify.sh
```

Expected: 运行时缺失不会导致崩溃或伪零数据；用户能定位问题且源配置零写入。

### Task 6：关闭性能和可靠性证据缺口

**Files:**

- Modify: `Sources/DirectorCore/App/DirectorAppModel.swift`
- Modify: `Sources/DirectorCore/Persistence/**`
- Modify: `Tests/DirectorCoreTests/StartupPerformanceTests.swift`
- Modify: `Tests/DirectorCoreTests/QuotaPerformanceTests.swift`
- Create: `Tests/DirectorCoreTests/FailureRecoveryTests.swift`
- Update: `.design/codex-director/VALIDATION_PLAN.md`

**Step 1: 固定基线**

保留现有约 626 项测试与性能样本，新增首个可交互像素、主线程长任务和从用户动作到刷新状态可见的严格测量。当前约 100–117 ms 的输入反馈尾部应降至目标内，或通过原生即时 loading 状态消除不可感知空档。

**Step 2: 增加故障测试**

覆盖数据库损坏、磁盘满、权限拒绝、Codex CLI 超时、进程取消、源文件竞态、旧请求晚到、多窗口合并和导出中断。失败不得清空上次有效数据。

**Step 3: 只按证据优化**

优先移除主线程 I/O、重复统计和不必要全量读取；数据库 schema、索引版本或缓存格式只有在现有优化不足时才变化，并附迁移与回滚测试。

**Step 4: 验证门槛**

- 有缓存窗口可用 p95 ≤ 700 ms。
- 无缓存完成首轮可用索引 p95 ≤ 1.8 s（合成标准样本）。
- 主窗口关闭、菜单栏未展开时平均 idle CPU ≤ 0.2%。
- 100 万行配额样本查询不得阻塞 UI；性能退化超过已记录基线 20% 时失败。
- 所有超时、失败和取消均有确定状态，且不会留下半成品。

### Task 7：建立菜单栏共享状态契约

**Files:**

- Create: `Sources/DirectorCore/MenuBar/MenuBarPreferences.swift`
- Create: `Sources/DirectorCore/MenuBar/MenuBarPresentation.swift`
- Create: `Sources/DirectorCore/Refresh/RefreshDemand.swift`
- Create: `Tests/DirectorCoreTests/MenuBarPresentationTests.swift`
- Create: `Tests/DirectorCoreTests/RefreshDemandTests.swift`
- Modify: `Sources/DirectorCore/App/DirectorAppModel.swift`

**Step 1: 先定义纯值状态**

`MenuBarPresentation` 只接受已有配额快照、来源、新鲜度和当前时间，输出短状态、主值、重置文案和操作可用性。测试覆盖有效、缺测、过期、刷新、失败、来源切换和跨日倒计时。

**Step 2: 持久化用户偏好**

独立 UserDefaults 键保存菜单栏是否开启和选中的配额来源；缺失或非法值回退到安全默认。提供生产、内存和注入式构造器。

**Step 3: 引入活动表面需求**

定义 `.mainWindow`、`.menuBarPopover`、`.menuBarPassive`、`.none`：

- 主窗口可请求现有完整刷新。
- 菜单栏弹窗只请求配额刷新。
- 被动菜单栏只读取缓存并更新本地倒计时。
- 无活动表面不触发新工作。

继续使用共享 actor 合并请求；不得增加第二个 SQLite 实例或独立轮询器。

**Step 4: 验证**

Run:

```bash
swift test --filter MenuBarPresentationTests
swift test --filter RefreshDemandTests
```

Expected: 多表面不会重复刷新；关闭主窗口后菜单栏仍可显示缓存；被动状态不触发能力索引。

### Task 8：实现菜单栏与设置体验

**Files:**

- Modify: `Sources/CodexDirectorApp/CodexDirectorApp.swift`
- Create: `Sources/DirectorUI/MenuBar/MenuBarStatusView.swift`
- Create: `Sources/DirectorUI/MenuBar/MenuBarSettingsSection.swift`
- Modify: `Sources/DirectorUI/Settings/SettingsView.swift`
- Modify: `Sources/DirectorUI/Localization/LocalizedText.swift`
- Create: `Tests/DirectorUITests/MenuBarContractTests.swift`

**Step 1: 使用原生结构**

在 App 根部增加条件启用的 `MenuBarExtra`，共享同一 `DirectorAppModel`、主题 Store 和语言 Store。菜单栏图标使用 SF Symbol 模板渲染和可选短状态，不自制彩色常驻图标。

**Step 2: 实现隐私安全弹窗**

信息顺序固定为：额度主值 → 重置时间/数据状态 → 来源选择 → 刷新 → 打开 Codex Director。不得出现提示词、任务标题、路径、参数或能力正文。

**Step 3: 设置项**

在设置页增加“在菜单栏显示”开关和内容预览说明。关闭时立即移除菜单栏项；不提供登录时启动。

**Step 4: 可访问性与视觉验证**

覆盖中文/英文、Light/Dark、Increase Contrast、Reduce Motion、键盘和 VoiceOver。所有截图使用合成数据。弹窗遵循原生材质，只在主容器使用玻璃层，不嵌套无内容玻璃卡片。

**Step 5: 性能验证**

主窗口关闭后分别测量菜单栏未展开和已展开状态的 CPU、内存、数据库访问与刷新次数；确认未初始化拓扑渲染器。

### Task 9：建立无 Apple 账号的 CI 与 Release 流程

**Files:**

- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/release.yml`
- Create: `scripts/package-release.sh`
- Create: `scripts/verify-release.sh`
- Create: `Tests/Scripts/test-release-package.sh`
- Modify: `docs/RELEASE.md`

**Step 1: PR/Push CI**

CI 使用 macOS 26 runner，执行：

1. 检查 Xcode/Swift 版本。
2. 运行公共发布审计和完整测试。
3. Release 构建。
4. 验证 bundle ID、最低系统、资源、第三方许可、ad-hoc 签名和 universal 架构。
5. 上传测试结果，不上传含用户数据的日志。

所有第三方 Actions 使用完整 commit SHA 固定；默认权限仅 `contents: read`；不使用 `pull_request_target`；不需要 Apple 证书或个人 GitHub Token。

**Step 2: 证明 universal 构建路径**

在 CI 先验证单个 macOS 26 runner 能以 `ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO` 构建，并用 `lipo -archs` 断言双架构。若 runner 无法交叉构建，先暂停 Release 流程并设计可验证的双 runner 合并方案，不直接拼接两个 App bundle。

**Step 3: Tag 驱动 Release**

只接受 `v*` tag；工作流验证 tag 与 `MARKETING_VERSION` 一致。先生成 draft/prerelease，不自动公开。

Release workflow 只增加必要权限：`contents: write`、`id-token: write`、`attestations: write`。构建后：

- 使用 `ditto` 生成 ZIP。
- 写入 `BUILD-INFO.json`，包含 commit、toolchain、SDK、依赖锁和架构，不含 runner 用户路径。
- 生成 `SHA256SUMS.txt`。
- 为 ZIP 生成 artifact attestation。
- 运行 `scripts/verify-release.sh` 回读并验证全部内容。

**Step 4: 验证发布包**

Run:

```bash
./scripts/package-release.sh --version 1.0.0
./scripts/verify-release.sh dist/Codex-Director-1.0.0-macOS-26-unnotarized.zip
gh attestation verify dist/Codex-Director-1.0.0-macOS-26-unnotarized.zip --repo SimuDesign/Codex-Director
```

Expected: 哈希、attestation、双架构和包内 ad-hoc 签名均通过；验证输出明确说明没有 Developer ID 和 notarization。

“可重建”在 1.0 指相同源码、锁定依赖和记录的 toolchain 可生成等价应用，不承诺 ZIP 字节级完全一致；Xcode 时间戳等非确定性需要另立工作项才能承诺 reproducible build。

### Task 10：完成 0.9 RC 与 1.0 发布

**Files:**

- Modify: `project.yml`
- Modify: `CHANGELOG.md`
- Create: `docs/releases/1.0.0.md`
- Update: `README.md`
- Update: `README.zh-CN.md`

**Step 1: 先发 0.9 prerelease**

在仓库已净化且许可确认后发布 0.9.0 prerelease。至少邀请不同机器上的用户验证：源码构建、GitHub ZIP、Gatekeeper 流程、Codex 路径发现、首次索引、能力包导出和菜单栏。

反馈不得要求提交真实会话或能力正文；诊断导出必须继续经过隐私过滤。

**Step 2: 关闭阻断项**

1. 崩溃、数据损坏、源文件写入、隐私泄漏、安全扫描失败。
2. 无法从干净 checkout 构建。
3. Release 哈希、attestation、架构或许可不一致。
4. 缺失/过期额度被误报为确定值。
5. 菜单栏后台引入持续高 CPU、重复刷新或隐私内容。
6. 键盘或 VoiceOver 无法完成核心浏览、刷新、导出和设置。

**Step 3: 1.0 发布前人工清单**

- 从干净 checkout 运行 `./scripts/verify.sh`。
- 在两种窗口尺寸、两种主题和中英文下执行视觉矩阵。
- 执行一次真实但已脱敏的最小能力包往返。
- 检查仓库当前树和完整 Git 历史。
- 审阅所有公开图片、Issue 模板、Release notes 和产物内容。
- 下载 CI 产物，在另一台 Mac 上独立校验 SHA-256 与 attestation。
- 确认 Release 页面明确标注“未公证”，并链接 Apple 官方打开说明。
- 由用户手动批准 GitHub Release 和仓库公开状态。

## 5. 1.0 发布门

### P0：不满足就不能公开

- 许可证和版权主体已确认。
- 当前树和完整历史无真实凭证、Cookie、个人路径、会话、数据库、能力包和私人能力内容。
- 所有媒体有可解释来源与公开许可，或已移除。
- 干净 checkout 可构建，依赖精确锁定，完整测试通过。
- Release ZIP、SHA-256、BUILD-INFO 和 attestation 相互一致。
- 未公证状态、Gatekeeper 预期和源码构建路径清晰可见。
- 无源 Agent、Skill、会话或全局 Codex 配置写入回归。

### P1：1.0 应完成

- Codex 运行时发现和诊断不依赖单一安装路径。
- 严格启动、主线程、故障恢复和大数据性能证据完成。
- 可选菜单栏额度入口满足隐私、共享刷新、性能和可访问性约束。
- 中英文 README、安装、构建、隐私、安全、贡献和发布文档完整。

### P2：可进入 1.1

- 登录时启动。
- Director 内确定性恢复与冲突 UI。
- 用户主动选择的 GitHub/Dropbox/iCloud 备份适配器。
- 后台版本检查或自动更新框架。
- macOS 旧版本、Windows 或 Linux GUI。
- 字节级可复现构建。

## 6. 风险与控制

| 风险 | 后果 | 控制 |
| --- | --- | --- |
| 未签名/未公证发行 | Gatekeeper 阻止首次打开，用户信任下降 | 源码优先、CI 构建、SHA-256、attestation、清晰官方流程 |
| 公开旧 Git 历史 | 永久暴露个人路径、日志或素材 | 公开前全历史审计；经批准重建历史或新建公共仓库 |
| 菜单栏变成第二刷新器 | CPU、内存、SQLite 竞争和数据不一致 | App 级共享模型、RefreshDemand、单 actor 合并、被动只读缓存 |
| Codex 安装位置变化 | 应用显示空数据或启动失败 | 独立 runtime locator、版本诊断、用户选择路径 |
| 公开截图含私人信息 | 隐私和信任事故 | 合成数据、媒体清单、EXIF 清理、人工逐张审核 |
| 开源贡献扩大兼容范围 | 维护成本失控 | 1.0 明确 macOS 26+ 与范围边界，新增平台先经架构决策 |
| “哈希”被误解为可信身份 | 用户把完整性当作来源认证 | 文档区分 SHA-256、attestation、ad-hoc 签名与 Apple notarization |

## 7. 验收矩阵

### 功能

- 首页、Agent、Skill、插件、设置与详情口径不回归。
- 自动/手动刷新合并正常，失败保留上次结果。
- 能力包格式保持 manifest v1，不因开源发布改变。
- 菜单栏开启/关闭、来源选择、倒计时、刷新和打开主窗口正常。
- “查看 GitHub Releases”只在用户点击后打开浏览器。

### 性能与可靠性

- 冷/热启动、100 万行配额、160k 调用、导出、取消和损坏恢复通过门槛。
- 菜单栏被动状态不初始化拓扑，不全量索引，不持续增长内存。
- 多窗口与菜单栏共享状态，无重复数据库初始化和刷新风暴。

### 视觉与无障碍

- zh/en、Light/Dark、720×480、1280×800。
- Increase Contrast、Reduce Motion、键盘、VoiceOver。
- 菜单栏使用模板图标和原生弹窗，不出现隐私内容或新视觉语言。
- 主按钮黑色文案和现有渐变继续达到既定对比度。

### 开源与发布

- 匿名用户可以阅读仓库、许可、构建和隐私文档。
- Fork 后无需私密配置即可运行测试和构建。
- PR 默认最小权限；Release 权限只在 tag 工作流开放。
- 下载者可以独立验证 SHA-256 与 GitHub attestation。
- Release 页面不声称 Apple 签名、公证或官方背书。

## 8. 实施顺序与批准点

严格顺序：

1. 用户确认许可证与版权主体。
2. 完成公共树、媒体和历史审计。
3. 用户批准“重写现有私有历史”或“创建新公共仓库”。
4. 完成运行时发现、性能和菜单栏实现。
5. 完成 CI、Release 工具和开源文档。
6. 发布 0.9 prerelease 并收集跨机器验证。
7. 关闭 P0/P1，用户人工批准 1.0 Release 和公开仓库。

本计划不授权历史重写、force push、修改仓库可见性、创建 GitHub Release 或替换用户已安装应用；这些动作应在对应里程碑单独确认并执行。

## 9. 参考依据

- [Apple Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)：Developer ID 与 notarization 是 App Store 外分发获得 Gatekeeper 身份验证的标准路径。
- [Apple：Safely open apps on your Mac](https://support.apple.com/en-us/102445)：未识别或未公证应用应通过系统提供的“仍要打开”流程由用户明确确认。
- [GitHub：Managing releases](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)：Release 支持附加二进制、校验材料、草稿和 prerelease。
- [GitHub：Artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations)：artifact attestations 为公开仓库产物提供可验证的构建来源，但不替代 Apple notarization。
- [GitHub：Licensing a repository](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository)：无开源许可证时，默认版权不会授予他人使用、修改和分发权利。
- 项目设计系统：菜单栏必须使用隐私安全的短状态、原生材质和可关闭设置。
- 项目验证计划：菜单栏必须单独验证主窗口关闭时的内存、idle CPU、刷新和可访问性。
