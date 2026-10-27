# Capability Change History — 1.6.0 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. In this workspace use the available local executing-plans Skill; unavailable superpowers tools are not required. The user approved local implementation on 2026-10-22; publication of 1.6 remains separately gated.

**Goal:** 在本机记录 Agent / Skill 的可验证文档变化，提供可浏览的时间线，并辅助查看观察到变化之后的调用和已有人工评价；不自动改写能力，不自动判断效果。

**Architecture:** 复用唯一的能力扫描与刷新链路，增加有完整性证明的观察批次、纯函数变更检测器和独立的本地历史 Store。历史 Store 用单个版本化、限量、原子替换的 JSON 文件共同保存基线与事件，不存正文，也不与可删除的 SQLite 派生索引混放。详情及变更清单惰性读取；调用证据仍查询现有 SQLite 只读投影，评价仍以现有人工评价 Store 为准。

**Tech Stack:** Swift 6、Foundation、现有 SHA-256 能力、既有 SwiftUI/AppKit 组件、现有 SQLite 只读查询及 XCTest；无新第三方依赖、网络服务、脚本执行或第二套索引器。

---

## 0. 状态、依据与权限

- 用户已同意三项功能：记录新增/修改/不再发现、能力详情时间线、变化后的调用与人工评价摘要，并已批准按本计划开始实施。
- 目标版本：**1.6.0 (36)**。若实施前构建号已增长，重新选择更大的构建号并同步全部版本来源；本轮不修改现有 1.5.1 (35)。
- 规划核对基线：公共工作区提交 **867061a**。实施基线为该内容的 main squash 提交 **9b42f02**；两者已核对为相同代码树。不修改私人档案工作区，不读取生产数据库、真实会话或能力正文来制作测试。
- 开发前只读确认 1.5.1 的 PR/CI/main 状态；从包含该修复的公共 main 创建 **codex/capability-change-history-1.6.0**。若 main 尚未包含修复，先确认合流/开发基线，不擅自合并旧 PR、重写分支或绕过 CI。
- 用户已单独批准旧 PR #9 合并；1.6 的提交、推送、PR、合并、Tag、Release 仍需相应授权。
- 依据：AGENTS.md、HANDOFF.md、README.zh-CN.md、docs/ARCHITECTURE.md，以及 .design/codex-director/DESIGN_SYSTEM_V1.md。本功能是现有盘点/反馈工作的延伸，不改变产品定位，不引入第三方产品或资产。

### 当前代码事实

1. ResourceScanner 的资源指纹与 modified 标记不构成历史；modified 还是累计状态，不能作为“本次改变”的判据。
2. 全局配对 Agent 已混合配置与 Brief 指纹；项目 Agent 当前主要指纹只覆盖 TOML，需补齐历史观察的 Brief 输入。
3. 现有 Skill 指纹只覆盖 SKILL.md，不覆盖 scripts/assets。
4. DiscoveryOutput 没有足够的分范围完整性证明。部分目录枚举/读取错误被吞为 [] / 空字符串或跳过；索引完成不等于能力扫描完整。
5. replaceResourceInventory 会替换目录；不能把替换后的旧项缺失直接当删除。
6. 当前人工评价按 invocationID 存储，updatedAt 是评价编辑时间，不是调用时间，不能据此划分“变化后”的评价。

以上已由真实 Software Engineer 只读核查；没有进行实现或软件验收。

## 1. 首版功能范围

### 1.1 纳入与排除

- 纳入全局及项目自定义 Agent、自定义 Skill、独立安装 Skill；同一稳定 ID 仅记录一次，与文件夹成员无关。
- Agent 跟踪原生 TOML 和已批准目录内的配套 Brief；TOML-only / Brief-only 保留现有身份规则。
- Skill 首版只跟踪完整 SKILL.md 文档。明确提示：**本版不追踪脚本、图片、二进制资源及其他辅助文件变化**，不得把它叫完整能力包版本。
- 排除系统能力、插件本体、插件提供的 Agent/Skill、AGENTS.md、MCP、工具、运行时对象、缓存、会话和 Director 自身数据。
- 不递归哈希整个 Skill 目录；不跟随越界符号链接，不增加网络读取。
- 不记录手动文件夹操作、界面翻译、显示排序、分类修正或 parser 升级为能力内容变化。
- 暂不记录配套关系拓扑的独立事件、正文差异、历史正文、版本回滚、历史导出、跨设备同步、自动修改或自动评测。

### 1.2 事件定义

| 内部事件 | 用户文案 | 生成条件 |
| --- | --- | --- |
| added | 新发现 | 所属范围已有可靠基线之后，首次验证到新 ID |
| modified | 已跟踪文档发生变化 | 相同 ID 的配置/Brief/SKILL.md 签名与上次可靠基线不同 |
| missing | 连续两次完整扫描未发现 | 同一仍受监测且可访问的范围连续两次完整扫描均无该 ID |
| reappeared | 再次发现 | 已确认不再发现的同一 ID 再次被可靠观察到 |

- 初次运行/新增项目或扫描范围：只建立基线，不把全部旧能力标为新增。
- 同一变化重复刷新不重复记；A→B→A 若分别被可靠扫描到则是两次变化。
- 第一次未发现仅进入待确认状态；正向发现会撤销待确认。中途失败/不完整扫描中断连续确认，不累计为第二次。
- 整个项目根目录离线、权限拒绝、范围被用户停用、未知目录结构或解析失败，都不是移除证据。父范围可验证且能力子目录明确不存在时，才可形成该子范围的完整空观察。
- “不再发现”不等于物理删除，更不证明能力不能再运行。不会删除源文件、已有文件夹成员或评价。
- 路径移动可能产生旧 ID 不再发现和新 ID 出现；首版不凭名称或相同内容自动合并身份，不迁移现有稳定 ID。
- 同 ID 再次发现且内容不同，记录一条 reappeared 并带变更字段，不同时制造两条同义事件。

### 1.3 时间与覆盖

- observedAt 是 Director 成功验证当前文档状态的时刻，不是文件真实修改时间。
- 保存 previousConfirmedAt，表达可能变化区间；mtime 仅是辅助信息，不能代替变化时间。
- UI 固定说明：**两次扫描之间的多次修改可能无法逐次记录。**
- 扫描中内容/对象状态变化、UTF-8 解码失败或文档超限时，保持该项旧基线并报告覆盖限制；不得用空文本、旧缓存或猜测值构造新签名。
- 本机时钟回退时保持递增提交序列；显示时间异常提示，禁止负时长或倒置区间统计。

## 2. 产品与界面契约

### 2.1 入口

- 不新增一级导航，不改首页三个模块或菜单栏。
- 能力文件夹入口页增加原生次级“变更记录”按钮，打开本机变更清单 Sheet，保证不再发现的能力仍有入口可查。
- 当前 Agent/Skill 详情增加默认收起的“变更记录”区，位于身份、用途、归属/配套信息之后，调用证据之前。
- 首次基线在下一次正常能力刷新时建立，可使用已有“刷新数据”提前触发；不能为历史初始化绕过缓存启动、后台宽限或原刷新周期。
- 全局清单默认近 30 天，提供近 7/30 天与全部保留记录；按提交序列由新到旧，支持全部/Agent/Skill 及事件类型筛选。此处时间选择仅保存在窗口会话，不改首页或调用排行偏好。
- 详情默认展示最近 10 条，可按 20 条分页加载更早记录；不在每行启动统计查询。
- 当前存在的能力可打开既有能力详情。不再发现的项目只打开历史摘要，不恢复为活跃能力，不提供导出、成员修改或恢复源文件操作。
- 设置页隐私段提供“清除能力变更记录”，经明确确认后清空事件并重新建立基线；不连带清空评价、文件夹或派生索引。删除派生索引的说明同步注明历史会保留。

### 2.2 展示与交互

- 时间线只显示安全名称、Agent/Skill、配置范围、事件类型、观察时间和固定变更字段。
- 文档标签用“Agent 配置 / Agent 方法文档 / Skill 说明文件”，不显示路径或正文；内容指纹留在技术数据层，不拿长哈希充当主要信息。
- 选中一条可统计的事件时才加载其观察摘要；切换、关闭或返回会取消旧请求，旧结果不得覆盖新选择。
- 保留加载、首次建立基线、没有记录、筛选无结果、部分覆盖、暂时不可读、记录失败、文件损坏、不支持版本和保留期截断的独立状态。失败时保留上次有效记录。
- 原有搜索、三个 Tab、成员、排序、展开与详情返回位置保持不变。Sheet 关闭/Escape 将焦点还给入口。
- 当前视觉契约已解决主视觉方向：复用 DirectorTypography/Spacing/Color、现有原生折叠与 Sheet、次级按钮、描边控件和分页方式；不新增图标资产、颜色、卡片体系、内容玻璃或循环动画。
- 实施前 UI Designer 只补充新时间线局部状态契约；Frontend Developer 按该契约实现。若需改变导航/信息优先级，先返回 Product Designer，不在代码中自行决定。

## 3. 观察后的调用与评价口径

- 只称 **“观察到变化后的已记录调用”**，不称精确版本归因、成功率或优化收益。
- 可选事件的区间是 [event.observedAt, nextEvent.observedAt)；最后一项在当前有效统计截止时间上使用包含边界，避免漏掉恰好等于截止时间的调用。新增/修改/再次发现可查询；missing 不生成“修改后效果”指标。
- 为保证有界查询，摘要只统计该区间与所选近 7/30 个本地自然日的交集；默认近 30 天，并明确显示实际起止时间。交集为空时提示“不在本次统计范围”，不伪造 0。
- “全部保留记录”只扩大时间线范围；摘要仍默认近 30 天，可选近 7 天，不自动发起无限历史聚合。
- 使用现有去重 capability_usage_calls 口径：排除委派请求和继承/冗余证据，继续保留推断、部分覆盖、未知与真正已计算零值的区别。
- 相邻观察窗口用半开区间，边界调用只属于一侧。不能直接复用现有闭区间查询后重复计算，也不能用减一秒等近似处理。
- 评价通过 **调用 ID → 实际调用时间、资源 ID → 当前人工评价** 关联。绝不能按评价 updatedAt、全部历史评价或当前资源总评价数充当区间评价。
- 摘要显示调用数、已评价调用数及有效/无效/不确定数量，包含“未评价”；不计算综合分、评价增长率或自动效果结论。
- 只有与所选区间内有效调用对应的评价才纳入；孤儿评价、没有可靠调用时间或错误资源关联的记录不混入分母。
- 数据尚未索引或索引被清除时，历史时间线仍可读，调用/评价摘要显示不可用或待统计；不触发历史重解析来补摘要。
- 有效统计截止早于事件观察时间时显示“调用数据尚未更新至该观察时间”，不能当作已计算零值或普通筛选无结果。

## 4. 架构决定

### ADR-CH-01：历史独立于可清空的派生索引

**Status:** Accepted — 用户已批准按本计划实施。

- 选择：一个 CapabilityHistoryStore actor 管理版本化 JSON 文件，基线和事件同文件提交。放在 Director 自有 Application Support 目录，目录 0700、文件 0600；不放 UserDefaults 大字典或源能力目录。
- 理由：这些观察历史无法从当前源文件重建，不能随“删除派生索引”消失；本版有明确容量上限，不需要增加第二个 SQLite 数据库。
- 替代：放现有 SQLite 可取得目录/事件同事务，但需要改变派生索引销毁语义；新增独立 SQLite 则增加数据库和迁移负担。两者留给历史规模确实增长后再评估。
- 代价：目录和历史不是跨存储原子事务。历史只能承诺可靠观察记录，不承诺每次修改完整捕获，也不承诺断电零丢失。

### ADR-CH-02：记录提交与失败处理

- 共享刷新完成一个能力目录批次，先提交经完整性合并的目录，再把同批次的真实观察交给历史协调器；不能把为保留旧内容而合并回来的缓存资源当成新观察。
- 不要求后续全部会话解析成功才记录已成功的能力目录观察；额度域更新不能写历史。
- 历史 actor 在一次串行提交中验证输入、计算差异、更新基线/确认状态、裁剪事件并写同目录临时文件，成功原子替换后才发布新 revision。
- 复用既有原子写入经验，但不要原样复制缓存 Store 的错误吞掉行为。写入失败保留旧文件与旧基线，报告历史域错误，不破坏已经成功的索引/账户刷新。
- 崩溃发生在目录提交后、历史提交前：下一次验证以独立旧历史基线重试；不因为目录已更新就丢失当前仍可观察到的差异。不补造中途已经消失的瞬态变化。
- App 级单一 writer，使用 revision/会话 token 防止取消、清除后或旧请求晚到回写；写入者持有进程生命周期内的独占文件锁租约，获取有超时。另一实例只能只读历史并提示重试，不能拿自己的旧缓存覆盖文件；不能依赖 actor 提供跨进程互斥。取消发生在原子提交点前则不提交，已经完成提交的可靠观察不伪装成已回滚。
- 清除历史先撤销旧写许可，在同一个 writer 中原子提交空历史与新 epoch。之后的首次可靠扫描仅建立基线，旧异步结果不得复活记录。
- 损坏、未知 schema、超限或权限不足不能被当作“空历史”覆盖；允许重试，重建/清除必须用户确认。
- 观察中断保持明确提示；恢复后只记录能验证的当前差异，不能宣称补齐了缺失变化。

### ADR-CH-03：隐私、兼容与保留

- 仅保存固定版本、稳定 ID、校验过的短显示名、配置范围、签名、固定变更类型/字段、观察时间、提交序列与覆盖状态；不保存说明全文、Prompt、正文、diff、脚本、原始异常、绝对/相对文件路径、账号或凭证。
- 首版历史签名单独使用 SHA-256 与明确的签名算法版本，复用扫描阶段已安全读取的配置/Brief/SKILL.md；**不更换现有资源 ID/FNV 指纹算法**，不让历史功能把所有旧资源标为 modified。
- 历史签名算法或跟踪范围变化时建立新的局部基线，不把算法升级当内容修改。
- 建议默认保留最近 **180 天**、每能力最多 **100 条**、全局最多 **20,000 条**事件；保留当前基线，裁剪范围在 UI 明示。缺失项墓碑同样有界；过期后再出现只能标为新发现，不能假装保留了无限历史。
- 文件硬上限 **16 MiB**，单个已跟踪文档上限 **2 MiB**。超限/无法安全裁剪基线时保留旧文件、显示记录受限，不能静默丢弃当前跟踪关系来凑预算。路径/结构超限用固定问题码。
- 删除派生索引保留历史，但新的索引内容仍以源文件为准。历史不成为恢复正文、配置归属或文件夹成员的事实源。
- 保持 SQLite schema v6、rollout parser 1.4.1、presentation cache v1、codexpack manifest v1；新增独立 history schema v1。无自动历史回放或 schema 降级。
- 历史不进入能力包，不上传。数据文件和任何恢复/失败副本均不进入 Git。

平台依据：Foundation 的 [atomic 写入选项](https://developer.apple.com/documentation/foundation/nsdata/writingoptions/atomic)作为实现前 API 核对入口；[SQLite 官方事务文档](https://www.sqlite.org/lang_transaction.html)说明数据库事务不能替代上述独立文件提交协议。执行时用当前 SDK 核对 API 与故障测试，不把原子替换等同于来源真实性或完整断电持久性。

## 5. 新增接口建议

以下是实施合同，不是已存在接口；具体 Swift 可见性与项目模式保持一致。

~~~swift
enum CapabilityChangeKind: String, Codable, Sendable {
    case added, modified, missing, reappeared
}

enum CapabilityTrackedDocument: String, Codable, Sendable {
    case agentConfiguration, agentBrief, skillManifest
}

enum CapabilityHistoryCoverage: String, Codable, Sendable {
    case complete, partial, unavailable, unstable
}

struct CapabilityChangeEvent: Codable, Sendable, Identifiable {
    let id: String
    let resourceID: String
    let kind: CapabilityChangeKind
    let changedDocuments: Set<CapabilityTrackedDocument>
    let observedAt: Date
    let previousConfirmedAt: Date?
    let sequence: Int64
}
~~~

同时新增：

- CapabilityHistoryObservation：现有稳定身份、安全显示元数据、跟踪签名、观察时间；不包含正文/路径。
- CapabilityHistoryScanBatch：范围完整性、经过验证的正向观察及 scope/算法版本，区分缓存回填与真实读取。
- CapabilityHistoryStateV1：完整状态、初始化标记、基线、待确认、保留边界、事件、epoch/revision。
- CapabilityChangeDetector：纯函数，输入上次状态和观察批次，输出候选新状态与固定问题码。
- CapabilityHistoryStore：生产 URL、纯内存和故障注入构造器；序列化、校验、原子提交、锁和清除。
- CapabilityHistoryCoordinator：共享刷新对接、写许可、暂停/失败与投影更新，不启动扫描器。
- CapabilityChangeUsageQuery / Summary：有界观察区间、统计截止、调用与评价覆盖、缓存身份。
- CapabilityHistoryViewModel：只管理历史页面会话和惰性查询，不在 SwiftUI body 中读取文件/SQLite。

## 6. 分批开发步骤

### Task 1 — 扫描完整性与历史观察输入（Software Engineer）

**Files:**
- Modify: Sources/DirectorCore/Discovery/FileSystemClient.swift
- Modify: Sources/DirectorCore/Discovery/ResourceScanner.swift
- Modify: Sources/DirectorCore/Indexing/IndexingCoordinator.swift
- Create: Sources/DirectorCore/Discovery/CapabilityHistoryObservation.swift
- Test: Tests/DirectorCoreTests/Discovery/ResourceScannerTests.swift
- Create: Tests/DirectorCoreTests/Discovery/CapabilityHistoryObservationTests.swift
- Test: Tests/DirectorCoreTests/Indexing/IndexingCoordinatorTests.swift

1. 先添加失败测试：枚举拒绝、读失败、非法编码、缺失根、真正空目录、项目 Brief 单独变化、扫描期间变化、越界链接；保证不能生成空文本签名或移除证明。
2. Run: swift test --disable-sandbox --scratch-path /tmp/codex-director/build --filter 'ResourceScannerTests|CapabilityHistoryObservationTests|IndexingCoordinatorTests'
   Expected: 新回归断言先失败；已有边界测试继续成立。
3. 为 FileSystemClient 增加保留错误分类的只读枚举/读取接口，兼容现有调用者；本批不修无关会话收集器、CLI 或解析器。
4. 给扫描结果增加分范围及必要的单项完整性；项目 Agent 的历史签名输入配对 Brief。复用已读取字节，补明确读取竞态检查。
5. 合并目录时，完整范围可替换；失败范围保留上次有效内容；部分范围可更新可靠正向记录但不能删除未观察项。不把整个索引 .completed 当完整性证明。
6. 重跑相同命令，Expected: 全部通过；比较原有稳定 ID、目录范围、调用计数及源文件哈希不变。

**Gate:** fake Home、至少两个项目及独立安装 Skill 都通过；插件/系统排除，已有成员不变。未过此门不开始事件记录。

### Task 2 — 纯函数事件检测与本地持久化（Software Engineer）

**Files:**
- Create: Sources/DirectorCore/Domain/CapabilityChangeHistory.swift
- Create: Sources/DirectorCore/Discovery/CapabilityChangeDetector.swift
- Create: Sources/DirectorCore/Persistence/CapabilityHistoryStore.swift
- Modify: Sources/DirectorCore/Privacy/PersistenceAllowlist.swift
- Create: Tests/DirectorCoreTests/Domain/CapabilityChangeHistoryTests.swift
- Create: Tests/DirectorCoreTests/Persistence/CapabilityHistoryStoreTests.swift
- Test: Tests/DirectorCoreTests/Privacy/PersistenceAllowlistTests.swift

1. 先写状态机与 I/O 故障测试，确认当前不存在实现导致失败。
2. 实现首次按范围建立基线、新发现、文档变化、两次完整确认缺失、再次发现、A→B→A、同内容重复刷新及中断连续确认。
3. 将基线与事件编码到同一 history schema v1；增加隐私 allowlist、版本/数量/大小/字段约束与稳定排序，不改旧 ID 或源数据。
4. 故障注入覆盖磁盘不足、权限、写临时文件后失败、替换前后崩溃恢复、锁冲突、未知版本和损坏文件；完整旧状态或完整新状态均可，但不允许半文件、部分基线或静默重置。
5. 增加裁剪、墓碑到期、超限、时钟回退、算法升级、清除后旧写许可等测试。
6. Run: swift test --disable-sandbox --scratch-path /tmp/codex-director/build --filter 'CapabilityChangeHistoryTests|CapabilityHistoryStoreTests|PersistenceAllowlistTests'
   Expected: 全部通过；序列化内容无正文、路径、账户字段或凭证。

**Gate:** 此 Store 可独立于 SQLite 删除/重建保留；生产、内存与故障注入构造器明确隔离。

### Task 3 — 唯一刷新链路与生命周期集成（Software Engineer）

**Files:**
- Create: Sources/DirectorCore/Indexing/CapabilityHistoryCoordinator.swift
- Modify: Sources/DirectorCore/Indexing/IndexingCoordinator.swift
- Modify: Sources/CodexDirectorApp/AppContainer.swift
- Modify: Sources/DirectorUI/AppShell/DirectorAppModel.swift
- Test: Tests/DirectorCoreTests/Indexing/IndexingCoordinatorTests.swift
- Create: Tests/DirectorCoreTests/Indexing/CapabilityHistoryCoordinatorTests.swift
- Test: Tests/DirectorUITests/AppModelLibraryIntegrationTests.swift

1. 先写测试证明只有能力目录批次可提交历史；缓存启动、语言、Tab、搜索、排序、额度轮询及文件夹成员操作不能创建事件或启动历史写任务。
2. 共享唯一 Store/Coordinator，在可靠目录提交后提交原始观察批次；失败仅影响历史域。主窗口关闭和多窗口不创建额外 writer。
3. 加入 epoch/revision、取消、清除、晚到结果、恢复正常刷新、只读数据源与会话解析失败隔离测试。
4. 测试目录已提交/历史写入失败后重试，不依赖新目录指纹丢掉差异；另测失败期间先修改后还原只能报告记录缺口，不能补造事件。
5. 测试派生索引删除后历史保留且统计暂不可用；下一次扫描不把所有能力报成新增。显式清除历史才重新建立历史基线。
6. Run: swift test --disable-sandbox --scratch-path /tmp/codex-director/build --filter 'CapabilityHistoryCoordinatorTests|IndexingCoordinatorTests|AppModelLibraryIntegrationTests'
   Expected: 全部通过；现有刷新调度、缓存启动、源文件零写入及偏好保持。

**Gate:** 不新增文件 watcher、后台定时器、Codex 进程读取或第二套索引器。

### Task 4 — 观察区间统计与人工评价关联（Software Engineer）

**Files:**
- Modify: Sources/DirectorCore/Domain/CapabilityQuery.swift
- Modify: Sources/DirectorCore/Persistence/DatabaseStore.swift
- Modify: Sources/DirectorCore/Persistence/Repositories.swift
- Modify: Sources/DirectorUI/Capabilities/CapabilityDetailModel.swift
- Create: Tests/DirectorCoreTests/Persistence/CapabilityChangeUsageTests.swift
- Test: Tests/DirectorCoreTests/Persistence/DatabaseStorePrivacyBoundaryTests.swift
- Test: Tests/DirectorUITests/CapabilityDetailTests.swift

1. 先造边界恰好同刻、评价晚于调用编辑、孤儿评价、无调用时间、缺失索引、相同名字不同 ID 与跨项目调用的合成失败测试。
2. 实现资源/区间/截止时间有界的只读批量查询，复用 capability_usage_calls；半开区间不能重复边界调用。
3. 一次选中事件只发一个摘要任务。对评价关联用分块 ID 批查，不为每条评价或每行时间线查询 SQLite，也不加载完整历史调用列表来计数。
4. 摘要从实际区间内的调用 ID 合并现有评价；沿用原评价 Store，不增加第二份评价数据、不使用 updatedAt 替代调用时间。
5. 缓存键包含资源 ID、事件/区间、数据库 epoch/generation、统计截止及评价 revision；切换/关闭/删除/更新后旧结果失效。
6. Run: swift test --disable-sandbox --scratch-path /tmp/codex-director/build --filter 'CapabilityChangeUsageTests|CapabilityDetailTests|DatabaseStorePrivacyBoundaryTests'
   Expected: 全部通过；区间内计数/评价一致，未知不显示确定 0，不触发重解析。

**Gate:** 结果不称版本效果；切换时间线元数据、全局过滤和翻页不逐行查询统计。

### Task 5 — 局部界面与隐私控制（Frontend Developer）

**Files:**
- Create: Sources/DirectorUI/Capabilities/CapabilityHistoryViewModel.swift
- Create: Sources/DirectorUI/Capabilities/CapabilityChangeHistoryView.swift
- Modify: Sources/DirectorUI/Capabilities/CapabilityDetailView.swift
- Modify: Sources/DirectorUI/Capabilities/CapabilityFoldersView.swift
- Modify: Sources/DirectorUI/DataStatus/SettingsView.swift
- Modify: Sources/DirectorUI/Resources/zh-Hans.lproj/Localizable.strings
- Modify: Sources/DirectorUI/Resources/en.lproj/Localizable.strings
- Create: Tests/DirectorUITests/CapabilityHistoryTests.swift
- Test: Tests/DirectorUITests/CapabilityDetailTests.swift
- Modify: .design/codex-director/DESIGN_SYSTEM_V1.md
- Modify: .design/codex-director/VALIDATION_PLAN.md

1. UI Designer 先补局部时间线/清单/状态合同，保持既有 Scheme A、间距、字阶、控件热区与详情优先级；若无需新令牌不新增。
2. Frontend Developer 先写默认收起、加载、分页、近 30 天默认、无结果、移除项、错误保留、返回焦点和清除确认的契约测试。
3. 接入稳定历史投影，行中只显示安全字段。当前存在项复用详情，不再发现项显示独立历史摘要。
4. 清除操作需要确认，说明不可重建早期历史；成功后只清历史，取消不写任何文件。不把清除历史绑定到删除派生索引。
5. 用纯内存历史 Store 与合成 fixtures 展示 zh/en、Light/Dark、720×480、1280×800、长名称、截断、待确认及统计不可用。
6. Run: swift test --disable-sandbox --scratch-path /tmp/codex-director/build --filter 'CapabilityHistoryTests|CapabilityDetailTests|DirectorSchemeATests|Localization'
   Expected: 通过命中测试；测试筛选必须核对实际测试数量，不能把 0 项视作通过。
7. 进行真实键盘、Escape、焦点返回、VoiceOver 朗读和 Increase Contrast / Reduce Motion / Reduce Transparency 验证；AX 树检查和实际朗读分别报告。

**Gate:** 既有文件夹成员、三个 Tab、排行默认值、主题及刷新交互不回归；没有新一级导航或全局视觉改版。

### Task 6 — 性能、文档、独立验收与交付（Quality Engineer + root）

**Files:**
- Create: Tests/DirectorCoreTests/Persistence/CapabilityHistoryPerformanceTests.swift
- Test: Tests/DirectorUITests/InteractionPerformanceTests.swift
- Modify: README.md、README.zh-CN.md、CHANGELOG.md、CHANGELOG.zh-CN.md、PRIVACY.md
- Modify: docs/ARCHITECTURE.md、docs/PERFORMANCE.md、docs/RELEASE.md
- Modify: project.yml、CodexDirector.xcodeproj/project.pbxproj
- Modify: Sources/DirectorUI/DataStatus/SettingsView.swift 及既有版本契约测试

1. 在同一机器/Release/合成数据上记录 1.5.1 基线与新版本：2,000 个能力、20,000 条历史、文件预算边界。比较扫描增量耗时、存储、列表交互和内存；不伪造已通过数值。
2. 冷/热历史读取与原子写放后台；普通四清单切换不得新增历史 I/O 或 SQLite 调用。任何新增 MainActor 连续阻塞 ≥100ms 都阻止交付；普通 Tab 响应不得出现明显回退。
3. 用故障注入重跑磁盘不足、权限、损坏、锁冲突、取消、晚到、时钟回退、部分扫描、目录已提交但历史未提交及清除测试。
4. 同步中英文说明、隐私、保留期、跟踪文档范围、时间/证据限制、schema 兼容和新版本。测试与截图仅用合成数据，不需要另一台设备。
5. Run: ./scripts/verify.sh
   Expected: 完整测试及版本/公开/发布/性能契约通过；分别报告跳过、失败及未覆盖门槛。
6. Run: ./scripts/audit-public-release.sh --all
   Expected: 当前树和公开历史通过；另检查新未跟踪文件，确认没有历史 JSON 或临时副本进入仓库。
7. Run: ./scripts/build-local-app.sh
   Expected: 1.6.0、正确单调构建号、macOS 26+、arm64+x86_64、ad-hoc 签名；不作 Developer ID/Apple 公证宣称。
8. Quality Engineer 使用未参与实现的真实 reviewer，只读检查行为、数据保留、故障、技术无障碍与发布证据。实现者不得自签独立验收；返修后重新复验。
9. 独立验收通过后，按项目规则覆盖安装：退出 App，旧包移到唯一可恢复废纸篓位置，核对新包版本/架构/签名/哈希后启动，做比例适当的运行验证。
10. 未单独获准，不提交/推送、创建/合并 PR、创建 Tag 或 GitHub Release。

**Gate:** 任一数据丢失、误报删除、正文/路径泄露、旧结果复活、明显交互退化、核心测试/审计/构建/独立验收失败，均停止交付。

## 7. 执行顺序与责任

- 根任务：产品/架构、范围审批、计划、集成协调、证据核对及最终交付。
- Software Engineer：Task 1→2→3→4，核心持久化/一致性风险按全局模型升级规则处理；不会由通用 worker 冒充 native 配置。
- UI Designer：Task 5 开始前补最小局部视觉合同；不重复整产品设计。
- Frontend Developer：核心读接口稳定后做 Task 5。早期可并行准备合成 fixtures，但不得自行决定核心数据语义。
- 独立 Quality Engineer：Task 6 只读验收；不验收自己的生产修复。
- 同一文件只有一名写入者；各角色共享工作区，必须保留其他贡献者修改。核心接口未稳定前，不同时修改 AppModel/详情整合点。
- 每批先写失败测试，再最小实现，再聚焦验证。可以形成局部检查点；Git 提交只有在用户授权时进行，本计划不自动授权每批提交。

## 8. 最终验收摘要

- [x] 首次建立基线不刷屏；新增、文档变化、两次确认未发现和再次发现都准确且幂等。
- [x] Agent TOML/Brief 全局与项目均被跟踪；Skill 只跟踪 SKILL.md 的限制明确可见。
- [x] 部分/失败/竞态扫描不冒充完整，不吞成空文件，不清空上次内容或误报移除。
- [x] 不再发现的能力仍能从全局变更清单查看；不被恢复成活跃成员。
- [x] 历史重启可读、清派生索引后保留，清历史后不复活；损坏与未知版本不被覆盖。
- [x] 区间调用不重复计数，评价按真实调用时间关联；未知、零、推断和部分覆盖区分。
- [x] 现有文件夹成员、评价、稳定 ID、源文件及 manifest v1 不变。
- [x] 无新后台轮询、CLI/网络读取、全目录递归哈希、正文存储或自动改写。
- [x] 完整测试、隐私/历史审计、Release 与独立验收通过；未测项明确列出。

最终证据与局限见[验收记录](../validation/2026-10-23-capability-change-history-1.6.0.md)。
1.6.0 (36) 已覆盖安装并完成运行核对，旧版可从废纸篓恢复。
完整测试 1,200 项（含 3 项既有 opt-in 跳过），0 失败；独立 Quality Engineer 验收及安装一致性检查通过。
遵照用户选择，不修改系统设置；真实 VoiceOver、完整键盘激活和受控 OS 无障碍模式矩阵仍为未验证，不作通过声明。
2,000 文件合成基准中后台完整扫描约增加 2.5 秒；普通导航基准的标记不代表 input-to-paint，也不代表所有既有卡顿已消除。
本轮未提交、推送、创建 PR、Tag 或 GitHub Release。

## 9. 实施检查点 — 2026-10-22

- PR #9 已在核对准确 head 与成功 CI 后正常 squash 合并，未绕过保护；main 为 9b42f02。未创建 Tag 或 Release。
- 本地 main 已快进同步，独立分支 codex/capability-change-history-1.6.0 已建立；规划文件保留，旧功能分支未被重写。
- 合并后 main 的 CI 已通过（run 39777003426）；该结果只覆盖已合并的 1.5.1，不覆盖本地 1.6 工作区。
- Task 1 已派给真实 Software Engineer，负责指定 Discovery/Indexing 文件及合成测试；当前仅有未提交的部分实现，未进入历史持久化、UI 或部署。
- 聚焦测试已解除依赖/缓存环境阻碍，但编译失败：FileSystemClient 的 @Sendable 闭包捕获非 Sendable FileManager（5 个唯一位置）。测试断言执行数为 0，不能将已写测试称为通过的 RED/GREEN 验证；git diff --check 通过。
- Software Engineer 已停止写入，并指出稳定读取、扫描完整性和新旧目录保留涉及数据一致性/并发风险，需要按既定规则升级至 gpt-5.6-sol/xhigh。当前原生角色预设锁定为 gpt-5.6-luna/xhigh，未擅自用通用代理冒充；继续生产实现前需解决执行路由。
- 本地改动保持原样，未提交、未推送、未安装。后续须补稳定文件身份与竞态验证，并重新完成 Task 1 测试及独立检查，不能以 size+mtime 相同证明读取稳定。
- 用户已明确批准执行路由例外：由 gpt-5.6-sol/xhigh 执行代理遵循 Software Engineer Brief 继续 Task 1，明确不宣称它使用了原生角色预设；独立 Quality Engineer 保持只读验收。
- 本批边界仍为 Task 1 扫描基础及其聚焦回归，不进入 Task 2 持久化、事件生成、UI 或覆盖安装。完整 1.6 功能尚未完成。
- 执行路由升级后已取得实际 RED：78 个测试执行，12 条断言失败（不是 12 个失败测试的证明）；覆盖缓存回填、缺少文档字节、不安全名称、越界链接、文档超限和系统能力排除。
- 中断后的续跑已清除编译阻塞。第一轮完整聚焦复测为 78 个测试、77 通过、1 失败：testIncompleteCapabilityDirectoryRetainsPreviousInventory 的 partial/unavailable 状态断言。仍需核对覆盖语义、补齐验收 fixture 并交独立复验，Task 1 尚未验收。
- 后续按真实语义修正旧断言：根目录整体读取失败为 unavailable，不为了通过测试降格为 partial。补齐双项目与独立 Skill、源文件哈希不变、类型化目录错误、配对重验、去重、非普通文件及不完整目录保留等用例。
- Task 1 实现自测最终执行 88 个 XCTest：ResourceScannerTests 44、CapabilityHistoryObservationTests 6、IndexingCoordinatorTests 38；88 通过、0 失败、exit 0。总耗时 97.7 秒，主要为既有两个大日志用例；未以此声称新版本性能验收。
- 实现者已暂停写入，独立 Quality Engineer 正在检查最终 diff 并复跑；尚未取得独立通过结论。全仓测试、完整 verify.sh、Release 构建、功能 UI 和部署均未在本批完成。
- 修复后 audit-public-release.sh --all 通过；另已检查三个新增文件的个人路径/凭证模式，合成 Home 示例使用公开审计允许的 example。新增文件未暂存或提交，普通审计的 tracked 范围没有被误称为包含未跟踪文件。
- 独立 Quality Engineer 首次复验：核心 88/88、相邻回归 31/31 均通过，但代码审查结论 blocked。三个返修项为相对路径名称过滤（P1）、成功验证后才生成观察时间（P2）、不完整目录合并对重复运行时 ID 的抗崩溃处理（P2）。已交原执行代理定向修复，未进入 Task 2，不能把测试全绿当作独立验收通过。
- 三项定向返修已完成：路径式名称回退固定安全名称；验证完成后才生成正向观察及批次时间；资源 ID 到来源根使用抗重复的集合分组，不引入新的来源优先级。新增相对路径、确定性时钟及重复 MCP ID 用例。
- 返修后完整 Task 1 核心回归：90/90 通过、0 失败、exit 0（扫描 45、观察 6、索引 39）。日志位于本次临时工作目录，未加入 Git；120.095 秒仅是该次测试耗时，不是产品性能结论。
- 独立 Quality Engineer 返修复验：影响范围 8/8、相邻回归 31/31 均通过，git diff --check 通过，原三个阻断项全部解除。最终结论 passed，仅接受 Task 1；没有未解决的本批 P0/P1/P2。
- Task 1 状态：已完成并通过独立复验。Task 2–6 尚未完成；历史事件/持久化/生命周期/统计/界面及完整发布门仍待后续批次。本批没有完整全仓测试、Release 构建、提交、推送或安装，现有文件夹偏好和源文件写入边界保持不变。

## 10. 连续完成授权 — 2026-10-23

- 用户要求连续完成整个功能，不再在分批检查点暂停等待确认；Task 2–6 继续执行到完整验收与默认授权的本地安装。原有安全、隐私、独立验收和发布门不减少。
- 核心历史与区间查询分配给两名经批准的 gpt-5.6-sol/xhigh 执行代理，均遵循 Software Engineer Brief，明确不是原生角色预设。原生 UI Designer 已交付局部视觉合同，原生 Frontend Developer 负责生产界面；最终仍由独立 Quality Engineer 只读验收。
- 公开版本来源统一为 1.6.0 (36)，普通界面只显示 1.6.0。不会改写历史版本条目、解析器、schema v6、cache v1 或 manifest v1。
- Git 提交、推送、PR、Tag 和 Release 没有获得本轮新增授权，继续保持独立门禁。下列验证记录区分已通过、失败、待验证和证据局限，不以实现进度替代验收。
