> 记录路径：.agents/logs/plans/20261124/feature-batch-p0-p4.md

# 五项功能批量落地（P0~P4）

- 日期：2026-11-24
- 任务：按 P0 完成后动作 → P1 嗅探预览 → P2 删除/多选删除/多选转码 → P3 重启恢复队列 → P4 轨选择 顺序实现并逐项验证。

## 执行方案

| 项 | 落点 | 验收 |
|---|---|---|
| P0 | `AppSettings` 新增 `afterDownload`；`DownloadQueue` 注入取值回调，任务落定后按设置导出 / 转码 | 单测：完成动作按类型分派、不重复触发、伴生任务不触发 |
| P1 | 新增 `MediaPreviewPage`：图片走 `Image.network`，音视频走 WebView HTML5，流媒体只显示元信息 | `flutter analyze` + Widget 测试预览模式判定 |
| P2 | `DownloadQueue.removeWithFile`（只删私有目录内文件）；`LibraryPage` 多选模式 | 单测：路径越界不删、多选集合增删 |
| P3 | `AppSettings.autoResume`；`restore()` 未完成任务重新排队并 `_pump` | 单测：开启后续跑、关闭后标中断 |
| P4 | `M3u8Parser` 变体选择、`MpdParser` 语言轨与轨道枚举；下载前弹选择框 | 单测：变体/轨道枚举与指定选择 |

## 约束

- 三端可编译；平台差异只走 `PlatformInfo`
- 不引新依赖
- 每项完成后跑 `flutter analyze` 与相关测试
