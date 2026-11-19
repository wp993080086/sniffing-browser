> 记录路径：.agents/logs/changes/20261111/rules-cleanup.md

# 重写 .agents/rules 六份项目规则

- 日期：2026-11-11
- 任务：清除「像素工坊」遗留规则，改为符合 sniffing-browser 的事实
- 内容：
  - 01：项目定位改为跨端媒体嗅探下载器；文档指向 README / docs/tech-design.md / pubspec.yaml；补当前状态与能力边界
  - 02：目标端收敛为 Windows / Android / HarmonyOS NEXT，删 Web 与微信小程序；按实测状态排优先级；平台判定统一走 PlatformInfo
  - 03：删「API 面控制在 3.41」「3.44.9+ohos canary」「纯 Dart image 包架构铁律」；改为 SDK `>=3.9.0 <4.0.0`、鸿蒙 3.35.8-ohos + `br_v6.1.5_ohos`；铁律改为 CDP 嗅探、权限回调必返有效响应、系统 ffmpeg、`.part` + 流式合并
  - 04：按 lib/ 实际目录重画，注明 tech-design 第 7 章为设计稿
  - 05：保留 4 条基本命令，代理写法对齐 README（`NO_PROXY`），补 3 条端到端验证命令与 NuGet / WebView2 / ffmpeg / 鸿蒙前提
  - 06：删 `.gitattributes`、ARB 本地化、PRD 九.2、能力矩阵、`AppLogger` + name/data 等不存在的约定；日志改为 AppLog / `logXxx(tag, message)` / bump 计数器；错误处理改为三重全局捕获 + 中文提示 + 保留中间文件
  - `AGENTS.md` 未改：索引描述为概括性表述，重写后仍成立
- 结果：旧项目关键词检索无残留（仅 02 中「不在本项目范围内」的否定说明）；16 个引用路径逐项确认存在；计数器名与 `TranscodeUnsupportedSource` 均与代码一致；自查修正 2 处表述（01 DASH 边界、04 分层约定）
