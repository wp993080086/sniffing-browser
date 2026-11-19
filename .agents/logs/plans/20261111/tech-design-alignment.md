> 记录路径：.agents/logs/plans/20261111/tech-design-alignment.md

# 校准 docs/tech-design.md 与实现

- 日期：2026-11-11
- 任务：草案 v2（1365 行）与真实代码不一致，按章节精准校准；同时复核 AGENTS.md 索引与 6 份规则引用
- 内容：
  - 核对方式：只读比对 pubspec.yaml / pubspec.lock / README.md / lib 全部模块 / test / tools / windows/runner/main.cpp / android
  - 保留：所有实测记录、设计推演、风险表条目（这些是踩坑资产，不删）
  - 校准范围：文档头状态 + 新增「当前实现状态」、1 章能力边界、2.2 插件表注记、3.1 版本锁定、3.2 依赖清单与平台判定、3.3 状态管理、3.4 FFmpeg、4 章架构图、5.1/5.2/5.3/5.4/5.5/5.6/5.7 各节实现差异、6 章数据模型、7 章目录结构、8 章阶段状态、9 章风险表过时项
  - 关键事实：桌面调系统 ffmpeg 进程（无 ffmpeg-kit 依赖）；4 个 ChangeNotifierProvider 单例；分片并发 6；任务队列未持久化；`TranscodeKind` 含 dashMerge；`ohos/` 未生成；移动端导出与 FFmpeg 未实现
  - 复核：`.agents/rules/01~06` 对本文的引用（01 文档优先级、04 第 7 章提示、05 命令）与 `AGENTS.md` 索引表
- 结果：已按计划执行完毕；章节 0–10 完整、代码块成对、残留检索通过，规则 01/04 与 AGENTS.md 索引 01 行已同步；未动代码与 README/pubspec
