> 记录路径：.agents/logs/changes/20261120/download-stream-break-resume.md

# 「未知错误」定位与下载内部重试（单文件 Range 续传）

- 日期：2026-11-20
- 任务：诊断下载途中报「未知错误 (https://surrit.com/…)/ 别的错误」的成因，并补内部重试
- 内容：
  - 定位链路（读 dio 5.11.1 源码确认，非猜测）：
    1. `receiveTimeout` 只包住「等响应头」（`io_adapter.dart` 对 `request.close()` 套 timeout），body 阶段无看门狗，卡住不会超时；
    2. body 中断抛原始 `SocketException`/`HttpException`，`DioForNative.download` 的 `onError` 用 `assureDioException` 包成 `type=unknown`、`message=null`、原因在 `error.error`；
    3. `_describeError` 旧写法 `error.message ?? '未知错误'` → 只剩四个字；
    4. 旧重试真实存在（`retries=2`），但 `deleteOnError:true` + 每次进 `_downloadOnce` 先删 `.part`，三次都从 0 开始，站点按连接时长/字节数掐断时三次断在同一处 → 「过一会儿报错、重试没用」。
  - 后台诱因：`AndroidManifest.xml` 原本无任何前台服务（只有 Activity + FileProvider），Android 10 / MIUI 会冻结后台进程并回收 socket，body 当场断；前台不动时 CDN 掐长连接、Wi-Fi↔蜂窝切换走同一条路径。用户确认要根治 → 见下方「前台服务」。
  - 改动：
    - `lib/features/downloader/data/file_downloader.dart`：`_downloadOnce` 改为保留 `.part` + `Range: bytes=<offset>-` + `FileAccessMode.append`，进度按 offset 补偿；`_resumedCorrectly` 只认 206 且 `Content-Range` 起点对得上（防 append 出「大小正常内容错位」的坏文件）；416 清掉 `.part` 重下；新增 `_partLength` / `_deleteQuietly`；`_describeError` 的 unknown 分支改走 `_describeUnknown`（带出底层异常原文，`Connection closed/reset`、`Broken pipe` 统一说成「连接被中途断开」）；`_backoff` 把 `unknown` 并入慢退避；`_logTimeout` 记录 unknown 的底层异常。
    - `lib/features/downloader/data/hls/hls_downloader.dart`：分片 `fetchBytes` 用 `AppConstants.segmentRetryCount`（该常量原先定义后从未被使用）；失败时记 `第 i/N 个分片失败` + 原因。
    - `test/file_downloader_resume_test.dart`：新增 4 例（断流后 Range 续传、服务端忽略 Range 不产出错位文件、错误文案含真实原因、失败保留 `.part` 且下次从断点续）。
    - `docs/tech-design.md`：新增 5.3.3（成因与改法）、5.3.4（前台服务），5.3/5.4 与 README 的「不支持单文件续传」同步更新。
  - 前台服务（用户选定方案）：
    - `android/.../DownloadForegroundService.kt`：只做 `startForeground`，下载仍在 Dart 侧；渠道 IMPORTANCE_LOW、不可划掉、点通知回应用、结束自动消失；`START_NOT_STICKY`（Dart 任务已没了，重启只会留空通知）；`onDestroy` 里 `stopForeground` 兼容 API < 24。
    - `android/.../DownloadServiceBridge.kt` + `MainActivity` 注册 `sniffing_browser/download_service`：`start` / `stop`；启动失败（Android 12+ 后台限制）回 `unavailable`，不阻断下载；Android 13+ 顺手要一次 `POST_NOTIFICATIONS`，被拒不报错。
    - `AndroidManifest.xml`：`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_DATA_SYNC`、`POST_NOTIFICATIONS` + `<service foregroundServiceType="dataSync" exported="false">`。
    - `lib/core/platform/download_foreground_service.dart`：Dart 侧薄封装，非 Android 直接返回；`_running` 去重，避免每轮调度重建通知。
    - `lib/features/downloader/data/download_queue.dart`：`_pump` 末尾 `_syncForegroundService()`（有任务 start / 跑完 stop），`dispose` 补一次 stop（`_disposed` 会拦住后续 `_pump`）。
- 结果：`flutter analyze` 全量无问题；`flutter test` 全量 184 通过（8 skip）；`flutter build apk --debug` 成功（49s），合并后清单已含 service 与三条权限。
- 待办：HLS 分片并发仍为 6（`AppConstants.maxConcurrentSegments`），若仍见 CDN 限流再下调到 3~4。

## 追加：底部提示不消失（同一日期，另一件事）

- 日期：2026-11-20
- 任务：修「打开新窗口的底部提示一直不消失」，并要求自动消失 + 更大的关闭图标
- 内容：
  - 根因：Flutter 3.44 里 `SnackBar.persist = persist ?? action != null`，**带 action 的 SnackBar 默认永不超时**（`scaffold.dart` 计时器到点先判 `persist` 再 hide）。隔离提示带「查看」按钮 → 一直挂着。与无障碍开关无关（那种情况是另一条历史遗留说明）。
  - 改动 `lib/features/browser/presentation/webview_host.dart`：显式 `persist: false` + `duration: 4s`；content 改成 `Row[Expanded(Text), IconButton]`，关闭键 28px 图标 / 40px 触控区，颜色 `onInverseSurface`（M3 SnackBar 深色底，默认 `onSurface` 会看不见）。
  - 改动 `lib/features/downloader/presentation/download_tile.dart`：「已加入转换队列」同样带 action，一并补 `persist: false` + 4s。
  - `docs/tech-design.md`：在页签隔离那节补这段成因与取舍。
- 结果：写了临时 widget 测试验证（1）新写法 4s 自动消失、关闭图标实测 28×28、无布局断言；（2）对照旧写法 30 秒后仍存在，确认 persist 默认值就是主因。验证后已删除临时测试。`flutter analyze` 无问题，`flutter test` 184 通过。

## 追加：打 release 包真机验证

- 日期：2026-11-20
- 任务：打可安装的 release APK，交给用户真机验证前台服务保活与断流续传
- 内容：
  - `flutter build apk --release` → 118.1MB，含 arm64+armv7+x86_64。
  - 发现 `android/app/build.gradle.kts` 的 `defaultConfig.ndk.abiFilters` **未生效**：`flutter build apk` 会把 `-Ptarget-platform` 透传并覆盖 ABI 选择，产物仍带 armeabi-v7a 目录。全 ABI 包里 armv7 只有 flutter 引擎、没有 ffmpeg 的 so（AAR 只发 arm64/x86_64），32 位设备会误装后在转码时崩溃。
  - 改用 `flutter build apk --release --target-platform android-arm64` → 84.6MB。产物仍残留 `armeabi-v7a/libdartjni.so`（插件 AAR 自带 jniLibs，81KB），但已无 flutter 引擎，32 位设备无法启动，不会再出现「能装但转码崩」。
  - 校验：`aapt dump badging` 得 `com.wp.sniffing_browser` / 0.1.0(1) / minSdk 24 / targetSdk 36 / 含 FOREGROUND_SERVICE；merged manifest 含 `DownloadForegroundService`、`foregroundServiceType="dataSync"`、`FOREGROUND_SERVICE_DATA_SYNC`、`POST_NOTIFICATIONS`。
- 结果：产物 `build/app/outputs/flutter-apk/sniffing-browser-0.1.0-arm64.apk`（debug 签名，可直接安装）。
- 待办：ABI 过滤要真正生效需在 gradle 里对 `packaging.jniLibs` / splits 处理，或统一用 `--target-platform` 构建；本轮未改动构建脚本。

## 追加：悬浮按钮玻璃透明度 + HLS 下载速度

- 日期：2026-11-20
- 任务：嗅探悬浮按钮底色太浅（要 70~80% 不透明度的毛玻璃）；下载项除进度外再显示速度，且不能影响下载
- 内容：
  - `lib/features/sniffer/presentation/sniff_fab.dart`：`_GlassSurface` 填充 `surface.withValues(alpha: 0.3)` → `0.75`，模糊半径 14 与描边不动。
  - `lib/features/downloader/data/hls/hls_downloader.dart`：`HlsProgress` 增加 `bytes`（本次实际落盘累计字节）；`_prepareSegment` 由 `Future<void>` 改 `Future<int>`，已存在的分片返回 0、新写的返回 `plain.length`；worker 累加后带进进度回调。
  - `lib/features/downloader/data/download_queue.dart`：`_runHls` 的 `onProgress` 里按 1 秒窗口对 `progress.bytes` 求差，`task.setSpeed` 推送（单文件原本已有 500ms 采样，未动）。
  - 速度纯本地采样，无额外请求，不改变下载流程。
  - `docs/tech-design.md`：毛玻璃段 0.3 → 0.75 并记录原因；5.6 补速度采样说明，同时订正该节遗留的「单文件不支持字节级续传」（5.3.3 早已改成 Range 续传）。
- 结果：`flutter analyze` 无问题；`flutter test` 全量 184 通过。另写临时用例（本地 HttpServer + 2 个 1000 字节分片）验证 `HlsProgress.bytes` 累加到 2000、单调不减、输出文件大小一致，通过后已删除；`dart run tools/verify_download.dart` 在当前机器上因 `dart run` 缺 `dart:ui` 无法启动（既有环境问题，与本次改动无关）。
- 待办：release APK 需重打。
