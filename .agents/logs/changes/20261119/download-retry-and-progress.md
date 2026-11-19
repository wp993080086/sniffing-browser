> 记录路径：.agents/logs/changes/20261119/download-retry-and-progress.md

# 下载：超时退避、分片总数、删记录清临时目录

- 日期：2026-11-19
- 任务：修复用户反馈的「HLS 中途超时后重试无效」，并补上分片总数显示与临时目录回收
- 内容：
  - `file_downloader.dart`：新增 `_backoff`，超时类（连接 / 发送 / 接收）退避放宽到 2s / 6s，其余错误保持 300 / 400ms 线性；新增 `_logTimeout`，最终失败时记 `请求失败 <type> <host>`，此前只有 403 有日志；超时文案补「稍后重试，或回原页面重新嗅探」
  - `download_task.dart`：`totalSegments` 由 `final` 改为可变，`updateSegments` 写入总数，UI 才能显示 `206/430`
  - `download_queue.dart`：`remove` / `clearFinished` 调 `StoragePaths.cleanTemp`，回收 `tmp/<taskId>/`；失败与取消路径不动，保住续传依据
  - 单测：新增 `download_task_test.dart`（3 条）、`download_queue_cleanup_test.dart`（2 条，含「不误删别的任务目录」）；`download_tile_test.dart` 补 1 条断言 `206/430 分片 · 48%`
  - 文档：`docs/tech-design.md` 5.3 更新退避描述、新增 5.3.2「重试为什么常常点了没效果」、5.4 补分片总数与清理时机
- 结果：`flutter analyze` 无问题；`flutter test` 180 通过 / 8 跳过；`flutter build apk --release` 成功（118MB）。
  安装时设备已断开（`adb devices` 为空），APK 已就绪待装。未提交。
- 追加（17:52）：`download_tile.dart` 的流任务状态文案改为 `206/430 分片 · 48%`，百分比按 `done/total` 四舍五入并 clamp 到 0~100。
