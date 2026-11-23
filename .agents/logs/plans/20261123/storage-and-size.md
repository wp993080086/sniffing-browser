> 记录路径：.agents/logs/plans/20261123/storage-and-size.md

# 存储管理与下载大小显示

- 日期：2026-11-23
- 任务：设置页新增存储管理；下载进度显示已下载 / 总大小（HLS/DASH 为估算值）。

- 内容：
  1. 新增 `StorageManager`，扫描 `downloads/` 与 `tmp/`：区分被任务/转换记录引用的产物、断点续传 `.part`、无主文件、可安全清理的临时目录；只删无主文件与非在用临时项，已导出到 MediaStore 的副本不在扫描范围内。
  2. 设置页加入「存储管理」入口，页面展示占用分类和路径，清理动作带二次确认并反馈释放量。
  3. `DownloadTask.updateSegments` 接收累计字节，按分片完成比例估算总大小；HLS/DASH 分片缓存命中时返回已有字节，避免续传后大小偏低；队列速度采样用首帧做基线，避免续传瞬间虚高。
  4. 下载项状态行下方新增「已下载 X / 总大小」一行，普通下载显示准确值，HLS/DASH 显示“约”。
  5. 补单测：存储分类与清理边界、分片字节估算；更新 README / tech-design；按功能拆两次提交。

- 结果：已按计划落地。`flutter analyze` 无问题；`storage_manager_test.dart` /
  `download_task_test.dart` / `download_tile_test.dart` 共 12 例通过；全量测试与提交见
  `.agents/logs/changes/20261123/storage-management-and-size-display.md`。
