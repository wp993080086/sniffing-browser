> 记录路径：.agents/logs/changes/20261113/transcode-open-artifact.md

# 转换页「打开产物」

- 日期：2026-11-13
- 任务：转换页已完成的任务可以直接用系统程序打开产物（上一步明确留到「下一步」的那件事）。
- 内容：
  - `TranscodeJob` 新增 `mediaUri`（媒体库 URI，随任务落盘）与 `artifactPath` getter
    （`replaceSource` 的合并任务产物其实在 `sourcePath`）。
  - `TranscodeQueue._exportToLibrary` 入库成功时把 `ExportResult.targetPath` 记进
    `mediaUri`；失败与 `retry()` 都清空它，避免拿旧 URI 打开已被覆盖的产物。
  - `TranscodeStore` 编解码 `mediaUri`，否则重启后历史任务点了打不开。
  - `MediaExporter.openFile(target)`：桌面 `cmd /c start` / `open` / `xdg-open`
    拉起默认程序；Android 走 `openMedia` 通道，返回 false 表示没有处理程序。
  - `MediaExporterHandler.kt` 新增 `openMedia`：`Intent.ACTION_VIEW` +
    `FLAG_GRANT_READ_URI_PERMISSION`，content:// 用 `ContentResolver.getType`
    取真实 mime；绝对路径（API<=28 导出）退化成 file Uri。
  - `transcode_page.dart` 菜单新增「打开」（仅 `completed`），失败弹
    「没有找到能打开这个文件的应用」。
- 关键取舍：
  - 打开必须用入库 URI 而不是 `outputPath`：私有目录那份文件外部应用无权读取，
    只有 `content://` + 读授权才交得出去。桌面没有入库这一步，退回 `artifactPath`。
  - 不做「下载页也能打开」：下载项已有「另存到下载目录 / 保存到相册」，产物本就
    在下载目录，再给一个打开入口属于重复路径。
- 结果：`flutter analyze` No issues；`flutter test` 85 通过 / 8 跳过（新增断言：
  入库写 `mediaUri`、入库失败留空、store 往返保留 URI）；
  `flutter build apk --debug` EXIT=0（90.9s，227MB）。真机待验 B12。
- 附带发现：全量跑时 `dash_merge_ffmpeg_test.dart` 的「走队列时成品覆盖视频轨原路径」
  失败过一次，单独跑与随后两次全量均通过，判定为并发跑真实 ffmpeg 的偶发失败，
  与本次改动无关；若再复现再收紧该用例的临时目录隔离。
