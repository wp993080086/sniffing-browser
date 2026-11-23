> 记录路径：.agents/logs/changes/20261123/download-library-page.md

# 下载库页面

- 日期：2026-11-23
- 任务：独立的已下载媒体管理页，按类型分组、搜索、打开/分享/导出/移除。

## 内容

- 新增 `lib/features/downloader/presentation/library_page.dart`：
  - `DownloadQueueTasks` 只收 completed 且有 savedPath 的任务（纯逻辑，可单测）；
  - `LibraryGroup`/`groupFor` 按类型分组，HLS/DASH 合并产物归「视频」；
  - 搜索按文件名过滤，空态区分「库为空」和「无匹配」；
  - 每条的菜单：打开、分享（Android）、导出、移除记录。
- `DownloadPage` 顶栏加「下载库」入口。
- **偏差说明**：原计划复用 `ThumbnailService` 出缩略图，但勘察确认它只接受
  网络 URL（给 MediaItem 抽帧），不能对已落盘文件用。改为类型图标，未硬凑。

## 结果

- `flutter analyze` 干净；`library_page_test.dart` 3 例（筛选、分组、空态）通过。
- 真机待验：打开/分享走的是既有 MediaExporter 路径，本页只是入口。
