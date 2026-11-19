> 记录路径：.agents/logs/plans/20261111/rules-cleanup.md

# 清理并重写 .agents/rules 项目规则

- 日期：2026-11-11
- 任务：6 份规则来自「像素工坊」项目，与 sniffing-browser 不符，核对后逐份重写
- 内容：
  - 核对依据：pubspec.yaml、README.md、docs/tech-design.md、lib/ 实际目录、analysis_options.yaml、.gitignore、git log、lib/core/logging/app_log.dart
  - 处置原则：保留 6 个编号文件（AGENTS.md 索引引用，删文件会留悬空引用），删除文件内不适用条款，按本项目事实重写
  - 01 项目定位与文档位置；02 三端目标与验证状态；03 SDK 约束、鸿蒙切换、架构铁律；04 实际 lib 目录；05 命令、E2E、本机前提；06 提交、风格、AppLog、错误处理
  - 不改 AGENTS.md（索引描述为概括性表述，重写后仍成立）；不动 docs/tech-design.md（草案，不属本次范围）
- 结果：已按计划执行完毕；逐份回读、检索旧项目关键词无残留，16 个引用路径与代码符号核对通过；自查另修正 01、04 各一处表述
