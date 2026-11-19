> 记录路径：.agents/logs/changes/20261112/transcode-library-export.md

# Android 转码产物自动写入系统媒体库

- 日期：2026-11-12
- 触发：用户真机反馈「MP4 可以保存，但转 MP3 说是放到了什么界面，找不到了」。
- 根因：Android 侧 `StoragePaths` 把产物写在外部私有目录
  `Android/data/<包名>/files/SniffingBrowser/downloads/`。Android 11+ 的文件管理器
  不允许浏览 `Android/data`，系统媒体库也不扫描那里，所以产物在系统里**完全不可见**。
  此前 MP4 能看见，只是因为用户手动点了「保存到相册」走了 MediaStore；
  MP3 没有对应的手动入口，转完就留在私有目录，界面上只写「已转换为 MP3」。
- 修改文件：
  - `lib/features/transcoder/data/transcode_queue.dart`：新增 `LibraryExporter`
    注入点与 `_autoExportToLibrary`（默认 `PlatformInfo.current == AppPlatform.android`）。
    `_run()` 在任务成功后、`setStatus(completed)` 之前调 `_exportToLibrary()`；
    `replaceSource`（DASH 合并）跳过——成品覆盖回下载任务持有的路径，走下载项导出。
    入库失败/抛异常都只写 `exportMessage`，不把任务判成失败。
    `retry()` 清空上一轮的入库结论。
  - `lib/features/transcoder/domain/transcode_job.dart`：新增 `String? exportMessage`
    与 `bool exported`。
  - `lib/core/platform/media_exporter.dart`：成功的 `ExportResult` 带上人类可读落点
    （`已保存到「音乐/SniffingBrowser」` 等，由 `_libraryLabel()` 按 target + 扩展名映射），
    `displayMessage` 优先用它——之前直接拼 `content://` URI，用户看不懂。
  - `lib/features/downloader/presentation/download_tile.dart`：转换完成的状态行改为
    「已转为 MP3，已保存到「音乐/SniffingBrowser」」；入库失败显示失败原因。
  - `test/transcode_library_export_test.dart`：7 个用例（音频走 music、MP4 走 video、
    入库失败不改终态、入库抛异常被吞、桌面不入库、DASH 合并不入库、retry 清结论）。
  - `docs/tech-design.md`：5.7 新增「产物落点（移动端必须入库）」小节；B3 / B4
    通过条件补「落库目录可见」。
  - `README.md`：模块表状态 + 产物落点说明。
- 结果：`flutter analyze` No issues；`flutter test` **67 通过 / 8 个 e2e 跳过**；
  `flutter build apk --debug` EXIT=0（37.8s），APK 227MB。
- 边界：入库是复制不是移动，私有目录那份保留；Android 上同一份产物会占两份空间；
  鸿蒙仍无原生实现，`_autoExportToLibrary` 只在 Android 生效。
