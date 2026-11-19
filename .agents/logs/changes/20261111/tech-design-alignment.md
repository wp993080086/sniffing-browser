> 记录路径：.agents/logs/changes/20261111/tech-design-alignment.md

# 校准 docs/tech-design.md 与实现

- 日期：2026-11-11
- 任务：草案 v2 与真实代码大面积不一致，按章节精准校准；同步规则与索引引用
- 内容：
  - `docs/tech-design.md`：状态改为「实现同步版」，新增第 0 章当前实现状态；1 章能力边界加「实现」列；2.2 插件表标注回调仅移动端；3.1 改为双版本线（3.44.9 / 3.35.8-ohos，SDK `>=3.9.0 <4.0.0`）；3.2 换成实际 pubspec 依赖与 `AppPlatform` 平台判定；3.3 改为 4 个 `ChangeNotifierProvider` + `ListenableBuilder`；3.4 整章改为桌面系统 ffmpeg 进程 + 移动端 MethodChannel 占位；4 章架构图补 CDP 与桌面导出分支
  - 5 章：5.1 加「仅移动端」与实现校准、删 `CookieManager` 示意代码；5.2 枚举补 `other` 与 `media_validator`；5.3 改 `.part`/线性退避/无单文件续传；5.4 并发 4→6 并补实际文件清单；5.5 补实现状态、实际存储路径、真实 `MediaExporter` 接口；5.6 状态图改 `completed`/`paused`、标注队列未持久化；5.7 执行模型改为 `Process.start` + `process.kill(sigkill)`
  - 6 章数据模型按实际字段重写（含 `TranscodeKind.dashMerge`、`mergedAudio`、`M3u8Playlist`）；7 章换成实际目录并标注 `ohos/` 未生成；8 章加阶段状态总览表并改 6 处过时条目；9 章改 7 条过时风险、新增 4 条未实现项
  - `.agents/rules/01-项目概述.md`：文档定位改为「已按实现校准」，说明「设计/待实现」不是现状
  - `.agents/rules/04-目录结构.md`：第 7 章不再是设计稿，改为「已同步为实际目录」
  - `AGENTS.md`：索引 01 行描述「项目定位、需求文档」→「项目定位、文档位置」
  - 未动 `pubspec.yaml`、`README.md`、`lib/`、`test/`
- 结果：章节 0–10 完整、1469 行、代码块围栏 56 个成对、mermaid 1 块；过时断言检索残留均为「早期草案错在哪」的校准说明；`git diff --stat` = 437 增 / 333 删（仅 docs/tech-design.md）
