# 浅色模式 UI Review · 2026-09-12

本轮是评审与优化待办，不是实现或发布验收。基线：`ui-optimization`，HEAD `582067c`，macOS 26.5.1，当前源码构建的 Debug Validation Host，应用版本 0.3.1 (16)。未修改生产代码或安装应用。

> **后续状态（2026-09-12）：** 本文保留为 review 基线和问题证据。01–08 的批准实现合同及验证要求已转入 [浅色 UI 优化计划](../plans/2026-09-12-light-ui-optimization.md)、[DESIGN_SYSTEM_V1](../../.design/codex-director/DESIGN_SYSTEM_V1.md#19-light-ui-optimization--2026-09-12) 与 [VALIDATION_PLAN](../../.design/codex-director/VALIDATION_PLAN.md#13-light-ui-optimization-matrix--2026-09-12)。其中本文 03 引用的“所有主题黑字”旧合同已被浅色深操作轨道/白字、深色亮操作轨道/黑字的动态合同取代。本文不因此改写为验收结果；独立质量结论仍以冻结源码的后续证据为准。09 的 P3 密度探索明确未纳入本轮实现。

## 评审输入与覆盖

- 项目 AGENTS.md、HANDOFF.md、DESIGN_SYSTEM_V1.md、VALIDATION_PLAN.md。
- director-visual-system、UI Designer Brief、ui-design-method；现有颜色、字体、容器、按钮、清单、详情与设置实现。
- 运行界面：浅色、中文、1280×800 产品视口的六个主页面；Agent 详情及展开后的调用证据；720×480 插件与设置页；英文小窗口设置、模拟刷新加载态和导出弹窗第一步。
- 截图来自模拟数据验证版，日期和能力名称均为 fixture。图片包含窗口工具栏，像素尺寸不等于产品内容尺寸；以 Host 的 AX 产品视口值为准。
- AX 树检查不等于 VoiceOver 实测。未完成深色回归、增加对比度、减少透明度/动态效果、完整键盘、空态/压力/失败态矩阵，也没有声明这些项目通过。
- 参考 Apple [Color](https://developer.apple.com/design/human-interface-guidelines/color) 与 [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)：检查背景/内容对比、原生状态和相邻控件的一致性。下列具体结论来自本项目源码及运行界面。

## 按优先级排列的问题

### 01 · P1 · 选中能力后，名称变成浅色，但背景仍然是浅色

**类型：可读性缺陷；已复现。** 打开 Agent 详情，背后的选中行出现原生蓝色选区外溢；条目内部仍绘制浅色 canvas，名称却继承选中态的浅色文字，几乎看不见。即使存在抽屉遮罩，标题相对相邻行的消失也很明显。

- 位置：[CapabilityLibraryView.swift](../../Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift)，`libraryRow`，名称约 555 行、背景及选择覆盖约 605–631 行。
- [截图：详情打开后的选中行](evidence/2026-09-12-light-review/agent-detail-light.png)。
- 建议：统一选中行的背景和前景策略，显式匹配名称颜色；解决原生选区与自绘背景覆盖冲突。保留原生 selection、键盘和 AX 语义。
- 验收：Light/Dark、键盘/鼠标选中、详情打开/关闭时名称和摘要都清楚；蓝色不溢出页面 gutter。

### 02 · P2 · 元信息和调用单位过淡，像不可用内容

**类型：可读性问题；已目视确认，未做系统动态色的像素级对比测量。** 四个能力页的来源、状态、修改时间、最近调用和右侧“次调用”都偏淡，安装插件的“已启用/已停用”也被埋进同一条浅灰元信息。用户不能轻松扫到这些本来有用的信息。

- 位置：[CapabilityLibraryView.swift](../../Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift)，`libraryRow` 575–597 行；`DirectorColor.textTertiary`。
- [截图：安装 Skill](evidence/2026-09-12-light-review/installed-skills-light.png)、[截图：插件](evidence/2026-09-12-light-review/plugins-light.png)。
- 建议：有任务意义的元信息使用可读的 secondary 等级；tertiary 留给非必要装饰。状态可用简短、清晰的文字标记，不靠改变资源类型颜色表达。
- 验收：正常浅色模式下可直接辨认来源、启停状态和计数单位，无需开启增加对比度。

### 03 · P2 · 渐变按钮的黑字需要重新做浅色模式配色

**类型：视觉方向优化；不是现有黑字违反旧规范。** 当前设计系统明确规定纯黑 foreground，所以这不是单个 Button 漏写样式。浅色界面中的“查看调用证据”“导出能力包”“Run preflight”和加载态刷新按钮呈现深蓝/青绿底配黑字，视觉偏闷；用户提出浅色文字的方向适合在这条支线重新定义。

- 位置：[DirectorColor.swift](../../Sources/DirectorUI/DesignSystem/DirectorColor.swift) 54 行；[DirectorSchemeA.swift](../../Sources/DirectorUI/DesignSystem/DirectorSchemeA.swift)，`DirectorGradient.primaryButton`、`DirectorPrimaryActionButtonStyle`。
- [截图：证据按钮](evidence/2026-09-12-light-review/agent-detail-light.png)、[截图：导出弹窗](evidence/2026-09-12-light-review/export-light-en.png)。
- 建议：为浅色模式定义“更深的操作背景 + 浅色文字/图标”，按用途拆开操作填充、图表渐变、标题渐变、导航选中前景；不要让一个全局 foreground 改动连带改变所有表面。
- 对当前不透明 sRGB token 的计算：白字在 `#0879D9`、`#118EAE`、`#148F7E` 上分别约为 **4.42、3.82、3.99:1**。因此不能仅替换为白字；新的背景、hover、pressed 和 loading 都需重新验证。上述是色值计算，不是截图采样。
- 验收：正常/hover/pressed/loading 的小字号文字达到项目 4.5:1 目标，disabled 仍能辨认且能与可操作态区分。

### 04 · P2 · 侧栏选中态出现两层高亮，图标与文案也不一致

**类型：视觉状态冲突；已复现。** 聚焦侧栏时，自绘青蓝渐变外又出现一圈明显的系统蓝色选中底；截图中选中图标偏浅，文字为黑色。进入详情后外层又变为灰色，层次随焦点变化不够统一。

- 位置：[DirectorRootView.swift](../../Sources/DirectorUI/AppShell/DirectorRootView.swift)，`sidebarDestination` 58–84 行。
- [截图：Agent 清单](evidence/2026-09-12-light-review/agents-light.png)。
- 建议：定义一套完整的选中/聚焦/失焦外观，避免两个填充争夺注意力；让相邻图标与文字使用同一前景规则。焦点提示保留独立但克制的表达。
- 验收：点击侧栏、Tab 切换焦点、打开抽屉后，都没有双重厚边框；键盘选中和焦点仍可区分。

### 05 · P2 · 刷新按钮过高，加载图标明显偏大

**类型：组件一致性/规范偏离；已复现。** 设置中的“立即更新”明显高于旁边“删除派生索引”。模拟刷新时，转圈图标比文字和普通刷新图标大很多；idle 时隐藏的加载内容仍参与 ZStack 布局，源码与现象吻合。

- 位置：[DirectorRefreshButton.swift](../../Sources/DirectorUI/Components/DirectorRefreshButton.swift) 35–59 行，非 toolbar 使用 regular ProgressView；[DirectorSchemeA.swift](../../Sources/DirectorUI/DesignSystem/DirectorSchemeA.swift) 的按钮尺寸定义。
- [截图：设置](evidence/2026-09-12-light-review/settings-light.png)、[截图：刷新中](evidence/2026-09-12-light-review/settings-loading-light-en.png)。
- 建议：给图标/转圈定义共同的视觉尺寸及占位，保持现有状态切换不跳宽的能力，统一相邻操作的实际外框高度与基线。
- 验收：中英双语 idle/loading/disabled 均等高，不仅 SwiftUI minHeight 常量相同；转圈与文案比例协调。

### 06 · P2 · 插件筛选栏换行后排列错位

**类型：布局问题；已复现。** 默认 1280 产品宽度下，右侧筛选控件变为两行，左侧搜索框却与第二行对齐，第一行左侧空出一大片。四个清单页因插件额外的状态筛选而失去共同排列规律。

- 位置：[CapabilityLibraryView.swift](../../Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift)，`list` 内 `ViewThatFits` 310–323 行及 `controls` 723 行附近。
- [截图：插件默认宽度](evidence/2026-09-12-light-review/plugins-light.png)。
- 建议：统一外层和内层断点。放不下一整排时，搜索框独占完整一行，下一行放筛选；筛选行再根据真实可用宽度换行。继续显示当前选择值。
- 验收：720/1280/1600 产品宽度、中英双语下，搜索框不再贴到半个两行控件组底部，控件左边界和行间距整齐。

### 07 · P2 · 详情展开/收起证据时，按钮尺寸突然缩水

**类型：状态连续性问题；已复现。** “查看调用证据”是较高的自绘主按钮，点击后替换成很扁的原生“收起调用证据”，按钮高度和内容起点随之改变。

- 位置：[CapabilityDetailView.swift](../../Sources/DirectorUI/Capabilities/CapabilityDetailView.swift)，`evidenceControl` 93–108 行。
- [展开前](evidence/2026-09-12-light-review/agent-detail-light.png)、[展开后](evidence/2026-09-12-light-review/agent-evidence-light.png)。
- 建议：允许主次强调随状态变化，但保持同一位置控件的高度、圆角、文字基线与宽度规则一致。
- 验收：展开/收起过程中控制位置稳定，内容增加之外不发生额外的尺寸跳动。

### 08 · P2 · 图表小字号数据复用填充色，对比度不足

**类型：颜色用途混用；色值计算确认。** 每日柱状图的百分比使用 `accentIce`；浅色值 `#118EAE` 在白色上约 **3.82:1**，在 canvas `#F3F6F8` 上约 **3.52:1**，低于项目用于小字号文字的 4.5:1 目标。

- 位置：[QuotaOverviewView.swift](../../Sources/DirectorUI/Home/QuotaOverviewView.swift) 218–221 行；[DirectorColor.swift](../../Sources/DirectorUI/DesignSystem/DirectorColor.swift) 的 `accentIce`。
- [截图：首页](evidence/2026-09-12-light-review/home-light.png)。
- 建议：增加明确的 dataText/emphasisText 用途规则，小字号数据使用更深的文字色，柱体继续沿用品牌渐变。顺带审计小字号排名索引、链接及推断徽标，不能把这次计算当成所有消费者的实测结论。
- 验收：图表数值无需 hover 即可阅读，并独立验证文本与其真实背景；不改变缺测、零值与额度统计语义。

### 09 · P3 · 小窗口首屏被标题、留白和指标卡占满

**类型：主观密度优化，不是错误实现。** 720×480 的插件页首屏只容纳标题、四张两行指标卡和部分筛选，真实能力列表需要先滚动；默认宽度首页也需要滚动才能读完整汇总和排行。当前尺寸遵循既有视觉合同，但操作工具的浏览效率可以再讨论。

- 位置：[DirectorTypography.swift](../../Sources/DirectorUI/DesignSystem/DirectorTypography.swift) 的 52/36pt 标题；[CapabilityLibraryView.swift](../../Sources/DirectorUI/Capabilities/CapabilityLibraryView.swift) 的页首与指标区；Home Card Atlas 间距规则。
- [截图：小窗口插件](evidence/2026-09-12-light-review/plugins-compact-light.png)、[截图：首页](evidence/2026-09-12-light-review/home-light.png)。
- 建议：在保持既有内容顺序的前提下，试验更紧凑的小窗口标题、上下间距和指标卡内边距。若需要折叠指标或改变信息优先级，应回到 Product Designer 决定，不能借视觉优化擅自改变行为。
- 验收：用相同视口对照真实内容的首屏可见量；数值和菜单可读性不因压缩而下降。

## 建议实施顺序与边界

1. 先修 01、02、08：名称、元信息、图表数值可读性。
2. 再处理 03、04、05、07：明确浅色按钮配色，统一选择态与控件状态尺寸；更新涉及的旧黑字合同。
3. 最后处理 06、09：筛选布局与紧凑窗口密度。

使用 SwiftUI/AppKit 现有组件与 tokens；不引入新内容玻璃，不改六页导航、索引、缓存、额度统计或真实源文件。正式实现后再按项目 Validation Plan 做深浅色及辅助功能回归。此次只保存评审文档和模拟截图，未创建提交或进行安装。
