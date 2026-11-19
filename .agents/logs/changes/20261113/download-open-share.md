# 下载页补「打开 / 分享」

- 日期：2026-11-13
- 触发：A 组验收完成后推进「下载页打开 / 分享」（阶段 7 遗留项，产物已在盘上但页面无入口）
- 记录路径：`.agents/logs/changes/20261113/download-open-share.md`

## 改动

### Android 原生

1. `res/xml/file_paths.xml`（新增）：声明 `files-path` 与 `external-files-path`。
   下载产物落在 `files/SniffingBrowser` 与 `Android/data/<包名>/files/SniffingBrowser`
   两处，都要覆盖。
2. `AndroidManifest.xml`：加 `androidx.core.content.FileProvider`，authority 为
   `${applicationId}.fileprovider`，`grantUriPermissions=true`。
3. `MediaExporterHandler.kt`：
   - `openMedia` 改用 `toShareUri()`，绝对路径也能开（原来只有 `content://` 可用，
     传本地路径在 Android 7+ 会 `FileUriExposedException`）；
   - 新增 `shareMedia`：`ACTION_SEND` + `EXTRA_STREAM` + chooser，都带读授权；
   - 抽 `mimeOf()`（先问 ContentResolver 再按扩展名）、`launch()`（非 Activity
     Context 补 `NEW_TASK`）。

### Dart

4. `lib/core/platform/media_exporter.dart`：`openFile` 注释更正（本地路径也支持）；
   新增 `shareFile(path)`，桌面直接返回 false（没有系统级分享面板）。
5. `lib/features/downloader/presentation/download_tile.dart`：菜单加「打开」（全平台，
   条件是已完成且有 `savedPath`）与「分享」（仅 Android）；失败提示
   「没有找到能打开 / 分享这个文件的应用」。

## 取舍

- 不复用「导出的 URI」：`DownloadTask` 没有存 `mediaUri`，而 FileProvider 让本地路径
  就能交出去，省掉「必须先保存到相册」这一步，也避免为一个入口改数据结构。
- 桌面不做「在文件夹中显示」：`openFile` 已经能拉起默认程序，多一个入口收益不大。
- 分享不做「分享到指定应用」：系统 chooser 交给用户选，别自己猜。

## 测试

- 新增 `test/download_tile_test.dart`（2 条）：已完成有「打开」、未完成没有。
  未完成时进度条是不确定动画，`pumpAndSettle` 会超时，必须手动 `pump(400ms)`。
- 未加 `MediaExporter` 单测：`flutter_tester` 跑在 Windows 上，`PlatformInfo.isDesktop`
  恒为 true，走不到 Android 的 MethodChannel 分支，写了也只是自欺。
- 未加 Android 侧单测：项目没有 instrumented test 基建，靠编译 + 真机验证。

## 验证

- `flutter analyze`：No issues
- `flutter test`：**105 通过 / 8 个 e2e 跳过**
- `flutter build apk --debug`：EXIT=0（31.5s）
- merged manifest 确认：`androidx.core.content.FileProvider` 已合并，
  authority = `com.sniffing.sniffing_browser.fileprovider`

## 待真机

1. 下载一个 mp4 → 菜单「打开」，系统播放器能拉起；
2. 同一文件「分享」→ 面板出现，发给微信 / 相册能收到；
3. 未导出的文件（不点「保存到相册」）也能打开 —— 这条是本次改动的核心；
4. 音频 / 图片同样各试一次（mime 推断路径不同）。
