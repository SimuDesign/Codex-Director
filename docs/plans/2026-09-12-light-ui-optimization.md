# Light UI Optimization Implementation Plan

**Goal:** 修复 2026-09-12 UI review 中 01–08 的全部高/中优先级问题。

**Architecture:** 保持六个主页面、数据/选择模型、证据加载、原生键盘与 AX 语义不变，在 DirectorUI 的语义颜色、按钮、原生列表选择外观和布局层修复。Software Engineer 按用户明确委派执行界面实现，同时遵循 Frontend Developer Brief 的运行验证方法；独立 Quality Engineer 审核。

**Tech Stack:** SwiftUI、必要时使用公开 AppKit API 的局部 bridge、XCTest、现有 synthetic UIValidationHost；不新增依赖。

**Authorization:** 用户于本轮明确要求制定计划并让开发角色完成所有高到中问题。直接执行，无需再询问是否实施。沿用现有 `ui-optimization` 支线；保留工作区中能力文件浏览计划与原型等无关工作。无提交/推送/PR 授权。项目已授权验证成功后安装本机应用。

**Source of truth:** `docs/design/2026-09-12-light-ui-review.md`、`.design/codex-director/DESIGN_SYSTEM_V1.md`、`.design/codex-director/VALIDATION_PLAN.md`、AGENTS.md、HANDOFF.md。本计划是本轮有限视觉合同补充，覆盖原“全部渐变控件黑字”要求；其余边界保持。

## 范围和已确定的设计合同

| Review | 修复合同 |
| --- | --- |
| 01 | 四类能力行在选中/失焦/抽屉打开时保留可读文字；选择外观不溢出内容 gutter；保留 native List selection、键盘与 AX |
| 02 | 来源、启停状态、时间、计数单位使用可读 supporting 文本，tertiary 不承载必读信息；不改状态含义 |
| 03 | Light 主操作白字及白图标配更深不透明渐变；Dark 保留现有亮渐变黑字；操作/品牌图表/导航语义解耦 |
| 04 | 侧栏选中只呈现一套背景，不出现系统蓝色厚外圈加内层渐变；同一状态图标文字同色；原生焦点与失焦可辨 |
| 05 | 刷新图标与 spinner 共用约 14pt 占位，spinner 使用小尺寸；中英 idle/loading/disabled 的外框不跳动，设置相邻动作实际等高 |
| 06 | 真实宽度不足时搜索独占一整行，菜单位于下一行；统一外层与内层换行判定；保留选中值可见 |
| 07 | 查看/收起证据使用同一按钮几何；只改变文案和主次强调，保留 lazy request 与原状态 |
| 08 | 小字号图表百分比、同类强调文字使用可读 dataText，而不是复用渐变填充端点 |

不包含 09（标题/卡片密度）；不改标题 52/36pt、卡片高度和信息优先级。不改 Core、数据库、索引、缓存版本、配额计算、刷新调度、能力源文件、全局配置。不引入内容玻璃、装饰图片或自定义图标。

### Color contract

- 新操作填充 Light stops：`#0065B3 → #00738B → #087765`，foreground `#FFFFFF`。白字端点对比约 5.98/5.49/5.47:1，正式验证需采样完整渐变而不仅端点。
- Dark stops 保持现有 `#159DFF → #49CAFF → #79EAD8`，foreground `#000000`。
- Light hover/pressed 用不透明背景上的轻微加深；不能通过降低整块背景 opacity 把白字对比冲淡。Dark 保留或使用不削弱黑字对比的反馈。
- Disabled 可降低强调但仍可辨；processing 保持 active 可读性和不可重复激活语义。
- 小字号 data text Light 使用已有 `#006B83` 或等效更高对比语义 token，Dark `#5FD7EE`。不连带改变 Home 品牌标题、柱体、环或大数字。
- 新 metadata/supporting token 若动态 secondary 在真实浅底上不足 4.5:1，可使用明确的 Light/Dark 配对并在增加对比度时加强。优先语义用途而非全局加深所有 secondary。
- Sidebar 可以复用专属 navigation-selected 语义配对，但不能依赖主操作 token 的后续变化；保持原渐变身份，选择和焦点区分。

## Task 1 — 可读性与语义颜色（01、02、03、08）

**Files:** `Sources/DirectorUI/DesignSystem/DirectorColor.swift`、`DirectorSchemeA.swift`，`Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift`、`Sources/DirectorUI/Home/QuotaOverviewView.swift`、小字号强调色实际消费者，相关 `Tests/DirectorUITests/*`。

1. 查阅已有 theme/contrast 单测及 consumer；确认图表/品牌 gradient 与 action gradient 的调用点。
2. 定义独立 action/data/supporting/navigation 语义；更新调用点，不改变数据含义。
3. 给能力名称和必要元信息显式的可读前景；修正原生选择和自绘背景相冲突的根因，避免仅掩盖名称而留下 gutter 蓝色外溢。
4. 增加有意义的颜色对比验证：Light/Dark、完整渐变采样、hover/pressed 组合，目标正常文本至少 4.5:1。更新旧“全局黑字”断言，不能删除仍有意义的检查。
5. 用 synthetic Host 验证选中前后和四类清单/首页，保存对照证据。

## Task 2 — 原生选中态一致性（04）

**Files:** `Sources/DirectorUI/AppShell/DirectorRootView.swift`；必要时新建 `Sources/DirectorUI/Components/` 内有界的 AppKit bridge；相关 tests。

1. 查阅 Apple 当前公开 API，优先标准 SwiftUI 外观控制。
2. 消除 native row selection fill 与自绘渐变的叠加，同时保留 selection model、箭头键、焦点、VoiceOver。
3. 如 SwiftUI 无公开机制，允许有界、幂等、可清理的 AppKit 表格外观适配。禁止私有 API、依赖全局 appearance proxy、重建 List 或全局移除焦点。
4. 验证 selected/unselected/focused/inactive 与打开详情后的状态。

## Task 3 — 控件几何与状态（05、07）

**Files:** `Sources/DirectorUI/Components/DirectorRefreshButton.swift`、`Sources/DirectorUI/DesignSystem/DirectorSchemeA.swift`、`DirectorSpacing.swift`、`Sources/DirectorUI/Capabilities/CapabilityDetailView.swift`。

1. 统一 icon/spinner 占位，限制隐藏加载标签对高度的影响；保留两份文字的稳定宽度。
2. 明确 standard/settings/toolbar 各尺寸的外框规则，设置 primary 和 destructive secondary 实际等高。
3. 查看与收起证据分别使用共享主、次按钮样式，同宽同高同基线。
4. 通过真实运行界面验证中英文 idle/loading/disabled 和展开/收起；记录实际几何，不能仅凭 minHeight 相等通过。

## Task 4 — 筛选栏响应布局（06）

**Files:** `Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift`，必要的纯布局 helper 及对应 tests。

1. 根据内容宽度与控件最小可读宽度选择整行/分行布局。外层整行时菜单必须也在一行。
2. 分行时搜索满宽置顶，下面菜单可以顺序换行；插件状态不会将搜索压到第二行。
3. 对 720/1280/1600 的产品视口以及中英双语验证；长选中值保留可识别文本和 AX 完整值。

## Task 5 — 文档、回归与交接

**Files:** `.design/codex-director/DESIGN_SYSTEM_V1.md`、`VALIDATION_PLAN.md`、`docs/design/evidence/2026-09-12-light-optimization/`、本计划的实施记录。

1. 更新当前生效的旧黑字/选择/按钮合同，保留历史记录但标记被本计划替代；不把新实现描述为已验收。
2. 先运行 relevant focused XCTest；颜色数学、布局断点、状态语义为必要检查，避免只新增源码字符串匹配的镜像测试。
3. `scripts/verify.sh` 完整 SwiftPM 测试与 build 应通过；运行在隔离 scratch/build 路径，禁止读写真实数据。
4. 构建全新 Debug Host：`DERIVED_DATA_PATH="$PWD/.build/ui-optimization-validation" scripts/build-ui-validation.sh`。使用 CUA 做界面操作；只保存模拟数据截图。
5. 代表矩阵：Light zh 六页默认宽度；四类清单的 selected；详情展开/收起；Settings 和插件 en/zh 720/1280/1600；Dark 相关控件/行/首页；加载/disabled；键盘选中、Tab/Return/Escape；Increase Contrast、Reduce Transparency、Reduce Motion 与 VoiceOver 必须区分实测、AX 检查及未测。
6. Software Engineer 交接实现、测试、截图和明确剩余项；Quality Engineer 只读独立复核，未解决 P1/P2 退回实施者修复。
7. 最终代码冻结后 `DERIVED_DATA_PATH="$PWD/.build/ui-optimization-release" scripts/build-local-app.sh` 验证 Release。保留 0.3.1(16)，本轮无版本号变更请求。
8. 质量门槛通过后由 root 检查安装兼容性：**预检发现正式应用已为 1.3.0 (25)，本支线仍为 0.3.1 (16)，因此当前不能按默认安装流程覆盖正式版。** 已向用户提出交付选择；缺省交付隔离验证版，保留新版正式应用。只有确认兼容的整合版本后，才先退出正式应用、把旧包移到唯一可恢复 Trash 路径、复制 verified build，签名与完整文件比对后重新启动。用 CUA 做 UI 操作，正式应用不保存含真实数据的截图。

## Rollback

不动用户的其他未提交文件。实现异常仅撤回本次自有 diff；安装异常恢复 Trash 内上一版本，不改真实数据库或源资源。

## Execution record

- Plan ready; Software Engineer `ui_implementation` dispatched using configured gpt-5.6-luna/xhigh.
- Deployment preflight: installed 1.3.0(25), source branch 0.3.1(16); default delivery is isolated candidate rather than downgrading installed application. Implementation and independent acceptance pending.
- First handoff: 33 focused tests passed and isolated Debug Host built. Two attempts to change table-wide `NSTableView.selectionHighlightStyle` caused SwiftUI OutlineList reconstruction crashes. The unsafe adapter was unhooked; 01/04 remain unaccepted at this point.
- Per project two-failed-cycle escalation, remaining implementation and runtime validation reassigned to Software Engineer method with gpt-5.6-sol/xhigh (`ui_remediation`). It must preserve previous valid edits, remove unused unsafe code and prove a safe selection treatment. Independent Quality Engineer retains its pending findings until the final source freeze.
- Remediation source/tests frozen on 2026-09-12. The safe adapter scopes selection painting to public `NSTableRowView` instances; structural rows remain non-selectable while native capability selection and embedded controls remain available. Final sidebar symbols and labels explicitly share one foreground.
- Developer verification: 35 focused tests passed; full `scripts/verify.sh` executed 660 tests with 3 skipped and 0 failures, followed by a successful Debug build. Synthetic runtime evidence and its exact coverage are in `docs/design/evidence/2026-09-12-light-optimization/README.md`.
- Root Release build passed `scripts/build-local-app.sh` with identity, signature, hardened-runtime and packaging checks. Artifact: `.build/ui-optimization-release/Build/Products/Release/Codex Director.app`; log: `.build/ui-optimization-release-build.log`. Source/tests/package/project hashes remained unchanged during the build; only the expected design-document updates continued.
- Independent final quality review **passed for issues 01–08**; see `docs/design/2026-09-12-light-ui-quality.md` and its AX evidence. This is scoped acceptance, not a claim of complete VoiceOver or alternate system-accessibility coverage. Installed 1.3.0(25) remains untouched; the 0.3.1(16) candidate is isolated and is not a production installation or newer-source integration.
- Remediation source freeze: the failed table-wide adapter was replaced with a public, row-scoped `NSTableRowView.selectionHighlightStyle` adapter that restores the original row style and never writes the containing table. Structural List rows are selection-disabled. Mouse selection, Escape/arrow selection, expanded evidence, repeated Stress scrolling and post-scroll selection ran in the fresh isolated Debug Host without native blue gutter spill, table reload or crash. Sidebar selection now draws one gradient; its explicit monochrome SF Symbol and label share the same foreground while the emphasized row keeps a separate focus boundary.
- The Light action rail is `#0065B3` → `#00738B` → `#087765` with white content; Dark retains the bright rail with black content. Hover, pressed and opaque neutral disabled rails are separate states. Resolved-color tests sample each complete rail and the actual canvas/panel text roles. Metadata, small chart/ranking data, refresh progress sizing, evidence action geometry and measured filter composition were updated within DirectorUI only.
- Focused remediation suite: 35 tests passed with no failures. A fresh Debug Host build succeeded with bundle ID `com.peiweitang.CodexDirector.Validation`; staged/fresh debug dylib SHA-256 matched at `6ba1406903331d76264517951eb2b4d3e08eac100145c5f4d1997091eaf62989`. Full `scripts/verify.sh` completed against the frozen source: `Executed 660 tests, with 3 tests skipped and 0 failures (0 unexpected)`, followed by a successful Debug build. Existing non-fatal warnings are recorded in the evidence README.
- Runtime evidence uses synthetic fixtures only. Standard Light/Dark, 720/1280/wide requested widths, zh-Hans/English, pointer, Escape/arrow AX flow, evidence expansion, stress scroll/select and refresh loading were exercised proportionally. AX inspection is not VoiceOver speech. Increase Contrast, Reduce Transparency, Reduce Motion and actual VoiceOver remain explicit independent/release gates unless separately exercised. The excluded P3 density item 09 was not implemented.
