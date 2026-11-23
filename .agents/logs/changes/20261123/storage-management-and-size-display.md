> 记录路径：.agents/logs/changes/20261123/storage-management-and-size-display.md

# 存储管理与下载大小显示

- 日期：2026-11-23
- 任务：设置页新增存储管理；下载进度补充已下载 / 总大小。

- 内容：
  - 新增 `lib/features/settings/data/storage_manager.dart`：扫描 `downloads/` 与 `tmp/`，
    区分引用产物、续传 `.part`、无主文件、可清理临时项；`clean()` 只删无主文件
    与非在用临时项，未结束任务的分片与正在合并的输出都在保护名单里。
  - 新增 `lib/features/settings/presentation/storage_page.dart`：占用分类展示、
    路径提示、两条带二次确认的清理动作；`settings_page.dart` 加入口。
  - `download_task.dart`：`updateSegments` 接收累计字节，按分片比例估算总大小。
  - `hls_downloader.dart` / `dash_downloader.dart`：缓存命中的分片返回已落盘字节，
    让续传后的总大小估算不偏低；`download_queue.dart` 速度首帧只做基线。
  - `download_tile.dart`：状态行下新增「已下载 X / 总大小」，流媒体标注“约”。
  - 测试：`test/storage_manager_test.dart`、`download_task_test.dart`、
    `download_tile_test.dart`。

- 结果：`flutter analyze` 无问题；全量 `flutter test` **253 通过 / 9 跳过 / 0 失败**
  （新增存储分类与清理 2 例、分片字节估算 1 例、UI 大小文案 1 例）。未提交、未打包。
