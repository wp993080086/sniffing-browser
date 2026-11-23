> 记录路径：.agents/logs/changes/20261123/notification-progress-and-pause.md

# 通知栏实时进度 + 全局暂停/继续/取消

- 日期：2026-11-23
- 任务：把静态前台通知改成实时进度 + 速度，并加暂停/继续/取消操作。

## 内容

- `lib/core/platform/download_foreground_service.dart`：新增 `update(done,total,speed,count)`
  推进度，`setActionHandler` 接收原生反调（pauseAll/resumeAll/cancelAll）。
- `lib/features/downloader/data/download_queue.dart`：
  - 聚合进度 1 秒节流推送，走独立 MethodChannel，不触发 `notifyListeners()`；
  - 加 `pauseAll`/`resumeAll`/`cancelAll` + 单任务 `pause`/`resume`；
  - `_start` 的取消分流改用 `_settleCancel`，靠 `_pausedIds` + token 身份
    区分暂停/取消，并挡住「暂停后立刻继续」的旧 catch 竞态。
- `DownloadTile`：下载中显示「暂停」，暂停中显示「继续」。
- Kotlin：`DownloadForegroundService` 通知改 `setProgress` + 速度文案，
  注册广播接收通知按钮，经 `DownloadServiceBridge.invokeDart` 反调 Dart；
  Bridge 加 `update` 分支与静态 channel 绑定；MainActivity 传 channel 进去。

## 结果

- `flutter analyze` 干净；`:app:compileReleaseKotlin` 通过（用 Android Studio JBR / Java 17）。
- 新增 `download_queue_pause_test.dart` 3 例（暂停落 paused、恢复续传完成、取消全部含暂停项）；
  `download_tile_test.dart` 加 2 例菜单断言，全过。
- 待办：真机验证通知进度刷新与三个按钮（桌面无法测）。
