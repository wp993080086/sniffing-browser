> 记录路径：.agents/logs/reviews/20261113/transcode-open-artifact.md

# review：「打开产物」改动范围

- 日期：2026-11-13
- 任务：复核本轮改动的边界与副作用。
- 内容：
  - 改动文件：`transcode_job.dart`、`transcode_queue.dart`、`transcode_store.dart`、
    `transcode_page.dart`、`media_exporter.dart`、`MediaExporterHandler.kt`、
    两个测试文件。未动下载队列、嗅探、浏览器侧，Windows 链路零影响。
  - `mediaUri` 的生命周期核对：入库成功才写；入库失败/异常与 `retry()` 清空；
    恢复任务时从 JSON 读回。不存在「打开一个已被覆盖的文件」的路径。
  - 原生侧异常面：`ActivityNotFoundException` 与老系统的 `FileUriExposedException`
    都落到 `catch (Exception)` → 返回 false，不让异常穿透 MethodChannel。
  - 未新增依赖、未改 `pubspec.lock`、未改 minSdk / targetSdk / manifest。
  - 格式：`dart format` 对四个修改文件的差异全部落在既有行（Dart 3.12 新格式器），
    按项目惯例不动周边代码；新增行本身符合格式。
- 结果：analyze 无问题、测试 85 通过、APK 构建通过。B12 需真机确认。
