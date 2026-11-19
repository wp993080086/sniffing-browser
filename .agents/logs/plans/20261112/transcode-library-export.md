> 记录路径：.agents/logs/plans/20261112/transcode-library-export.md

# 计划：Android 转码产物「找不到」的修复路径

- 日期：2026-11-12
- 现象：真机点「转为 MP3」后提示转换完成，但音乐 App / 文件管理器里没有文件。
- 排查结论：不是转换失败，是**落点不可见**。产物写在
  `Android/data/<包名>/files/SniffingBrowser/downloads/`，Android 11+ 禁止浏览该目录，
  媒体库也不扫描。MP4 之前能看到，是因为用户额外点了「保存到相册」。

## 备选方案

| 方案 | 取舍 |
| --- | --- |
| 转换时直接写公共目录 | 需要 `MANAGE_EXTERNAL_STORAGE` 或 SAF 授权，太重，也不符合两阶段策略（见 5.5） |
| 转换完成后自动入库一份（选中） | 复用已有 `MediaExporter` 与 `MediaStore + IS_PENDING`，零新权限，桌面端零改动 |
| 只加一个「保存到音乐目录」入口 | 用户已经表达了「找不到」，再加一步手动操作没有解决问题 |

## 落地顺序

1. `TranscodeJob` 增加 `exportMessage` / `exported`，作为 UI 唯一事实来源。
2. `TranscodeQueue` 成功路径先入库再标 completed，失败不影响终态。
3. UI 状态行直接写落库目录，避免用户再去猜。
4. 补 7 条单测（注入 `LibraryExporter`，不依赖平台通道）。
5. 文档 / 规则 / 记忆同步。
