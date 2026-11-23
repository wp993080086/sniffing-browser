> 记录路径：.agents/logs/plans/20261123/feature-batch-01.md

# 四项功能实施计划（通知栏进度 / 下载库 / 批量解析 / 站点规则）

- 日期：2026-11-23
- 任务：按用户指定顺序实现四项功能，DASH 单独立项不在本轮。

## 约束（来自勘察）

- 字节进度不进 `notifyListeners()`，由任务内 `progress`/`speed` ValueNotifier 驱动 UI —— 通知栏进度必须另开通道，不能靠 watch 队列。
- `DownloadStatus.paused` 已存在但从未接线，队列无 pause/resume。
- 通知栏是全局 UI，只能做全局操作（暂停全部/继续全部/取消全部），单任务操作留在 App 内。
- `StoragePaths.uniqueFile` 同名文件会加 ` (1)` 后缀，暂停续传必须复用同一个 target，否则 .part 对不上。

## 步骤与验收

1. **通知栏进度**（task 14）
   - Dart 侧给 `DownloadForegroundService` 加 `update(progress, speed, done, total)`，从队列进度回调节流推送（1s）。
   - Kotlin 侧通知改 `setProgress`，加暂停/继续/取消三个 action，经桥接回调 Dart。
   - 队列加 `pauseAll()` / `resumeAll()`，复用 CancelToken；暂停时保留 .part，恢复走 Range。
   - 验收：`flutter analyze` 干净；新增队列暂停/恢复单测；Kotlin 编译通过。
2. **下载库**（task 15）
   - 新页面按 completed 任务分组（图片/音频/视频），搜索 + 打开/分享/导出/删除。
   - 顶栏加入口。验收：widget 测试覆盖分组与空态。
3. **批量解析**（task 16）
   - 抖音 hook 收集多条 aweme，解析页列出多选，批量入队去重。
   - 验收：扩展 douyin_hook_test 覆盖多条提取与去重。
4. **站点规则**（task 17）
   - 按域名存 UA/Referer/额外头，下载时按 URL 匹配覆盖；设置页加管理入口。
   - 验收：规则匹配/合并顺序单测。

每步完成即写 `.agents/logs/changes/20261123/`，跑 analyze + 相关测试后再进下一步。
