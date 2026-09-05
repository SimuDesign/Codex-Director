# Codex Director Project Instructions

## Scope

These rules apply only within the `Codex Director` repository. Preserve all read-only, privacy, source-data, and approval boundaries in `HANDOFF.md`.

## Product goal — approved 0.2 redesign

Codex Director 是个人 Agent 与 Skill 的能力盘点和使用反馈工具。帮助用户了解自己已经开发、安装了哪些能力，各自能解决什么问题，近期在哪些项目中实际使用，以及哪些能力值得进一步验证和优化。通过清晰的能力清单、可追溯的调用记录和轻量人工评价，支持持续迭代；不把文件存在、调用频次或执行完成直接等同于能力有效。

- 首页回答额度还剩多少、能力规模多大、最近主要用了什么；能力页回答用途、近期调用与使用项目；详情提供调用证据和人工评价。
- 区分能力配置归属、实际使用项目、调用证据与人工评价。项目级数量是能力数量，不是项目个数；`AGENTS.md` 是项目说明，不是 Agent。
- 一级导航固定为：首页、自定义 Agent、自定义 Skill、安装 Skill、安装插件、设置。旧任务、审查、用量、数据状态仅可作为详情或设置内容，不恢复独立入口。
- 近 7 天为当前时区今天及前 6 个自然日，截至当前时刻；首页、清单、详情共享口径。调用频次和执行完成不代表有效性。
- 额度是账户报告的重置周期比例，不是 Token 换算值；首页每日周额度使用按同一来源相邻账户快照的周期感知增量计算。缺测、跨缺测日、重置证据不完整、过期、未观察到和无法统计必须区别呈现，不得补零或伪造每日消耗。
- 所有单选控件闭合时显示当前选中项，不得退化为只有图标。
- 保留中文默认、双语即时切换、稳定资源 ID、评价与分类修正；不改写源能力文件、会话日志或全局 Codex 配置。
- 0.2 的批准范围、数据契约与验收清单见 `docs/plans/2026-08-28-capability-centered-redesign.md`。该计划取代旧页面规划，不放宽 `HANDOFF.md` 的隐私或写入边界。

## Startup and refresh contract — approved 0.2.1 repair

- 启动优先可用：先显示小型本地缓存，数据库初始化、索引和统计不得阻塞窗口或导航。不能在视图计算中重建全量历史统计。
- 自动更新默认30分钟，跨重启复用成功检查时间；有效期内重启不扫描源、不重算额度。过期先显示上次结果，再后台合并更新；保留手动更新入口。
- 有缓存时后台失败不清空内容；没有计算结果时不显示确定的0。记录时间、统计截至时间、检查时间和索引完成时间分别表达。
- 页面/语言/窗口变动不触发源索引。多窗口共享调度，同域单一进行中任务；取消、超时和删除后的旧结果不得污染当前数据。
- 仍遵守周期过期、缺测、多来源隔离、稳定ID、评价和分类修正契约。修复不提高解析器版本，不清空真实数据。
- 执行和性能门槛以 `docs/plans/2026-08-28-startup-performance.md` 为准；目标0.2.1(4)。未经新快照性能与独立验收，不声明完成。覆盖安装和GitHub操作另需授权。

## Local application deployment

- The user has authorized successful Codex Director application builds to be installed to `/Applications/Codex Director.app` by default after relevant tests and build verification pass, unless the user explicitly asks for build-only or test-only work.
- Before replacement, quit the running app and move the previous bundle to the user's Trash with a unique recoverable name. Never replace the installed app with a failed or unverified build.
- After installation, verify the installed bundle against the build artifact, relaunch it, and perform proportionate runtime validation for the change.

## Visual design routing

- Approved Home-only0.2.2 refresh and Top10 cache compatibility: `docs/plans/2026-08-28-home-visual-refresh.md`. It supersedes Home Top5 presentation only; six-page navigation and startup/privacy boundaries remain. The current allowance ring stays cumulative, while the daily chart uses the 2026-09-05 reset-aware observed-increase contract.

- Use the project Skill `.agents/skills/director-visual-system/SKILL.md` for any main-window, menu-bar, Liquid Glass, topology, timeline, workflow, visualization, iconography, motion, accessibility, or desktop-pet design or review task.
- Read `.design/codex-director/DESIGN_SYSTEM_V1.md` before proposing or implementing visual changes.
- Use `.design/codex-director/VALIDATION_PLAN.md` before declaring visual work complete.
- Do not trigger the visual Skill for JSONL parsing, SQLite, resource discovery, telemetry, backend-only work, or unrelated projects.

## Authority

1. Use current Apple documentation as the source of truth for macOS behavior and framework APIs.
2. Use the project design system as the source of truth for Codex Director tokens, semantics, and component contracts.
3. Use the project Skill as the design and review workflow.
4. Treat third-party Skills as background references only; do not install, copy, or allow them to override the first three layers without explicit approval.

## Boundaries

- Do not create or install a global design Skill from this project.
- Do not modify global Codex configuration.
- Do not copy Apple UI kits, third-party Skill folders, or proprietary assets into the repository.
- Keep menu-bar, desktop-pet, notification, preview, and screenshot content privacy-safe by default.
