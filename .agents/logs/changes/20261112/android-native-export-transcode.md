> 记录路径：.agents/logs/changes/20261112/android-native-export-transcode.md

# Android 原生导出 + FFmpegKit 转码

- 日期：2026-11-12
- 任务：在 Android USB 真机上补齐下载完成后的「保存到相册/音乐」与「转换」入口及原生实现。
- 新增文件：
  - `android/app/src/main/kotlin/.../MediaExporterHandler.kt`：`sniffing_browser/media_exporter`。API 29+ 用 MediaStore + `IS_PENDING`（无需权限），按 target 分派 Images / Video / Audio / Downloads；用 `MimeTypeMap` 纠正 Dart 侧非标准 mime；写失败删除 pending 条目；API ≤ 28 走公共目录 + `MediaScannerConnection`，权限缺失给中文提示。
  - `android/app/src/main/kotlin/.../TranscodeBridge.kt`：`sniffing_browser/transcoder`。`isAvailable` 真加载 native 库；`startTranscode` 后台线程按 kind 拼参数数组、`executeWithArgumentsAsync`，result 挂到 complete callback 才回复；`FFprobeKit` 取时长、`Statistics.getTime()` 换算进度，反向 `onProgress`；识别无音轨返回 `unsupported`；失败返回 ffmpeg 错误行；`cancelTranscode` 调 `FFmpegKit.cancel`。
  - `test/native_transcode_engine_test.dart`：8 个协议用例（参数、done、canceled、unsupported 中文、failed、不可用、isAvailable 不缓存失败、cancel、反向进度）。
- 修改文件：
  - `android/app/src/main/kotlin/.../MainActivity.kt`：注册两个 MethodChannel。
  - `android/app/build.gradle.kts`：加 `dev.ffmpegkit-maintained:ffmpeg-kit-full:8.1.9`；`ndk.abiFilters` 限定 arm64-v8a / x86_64。
  - `android/app/src/main/AndroidManifest.xml`：加 `WRITE_EXTERNAL_STORAGE`（`maxSdkVersion=28`），仅服务 legacy 导出路径。
  - `lib/features/transcoder/data/transcode_engine.dart`：`TranscodeCancelled` 上移到抽象层；重写 `NativeTranscodeEngine`（挂起 result、静态 handler 接 `onProgress`、状态映射成异常、只缓存 isAvailable 成功结论）。
  - `lib/features/transcoder/data/system_ffmpeg_engine.dart`：删除 `TranscodeCancelled` 定义，改 re-export 保持既有 import 路径兼容。
  - `lib/features/downloader/presentation/download_tile.dart`：菜单能力判断改为 `_mediaFeaturesReady`（桌面 + Android，鸿蒙仍隐藏）；`canExport` 补 `savedPath != null`；`_exportLabel()` 三分支文案；转换不可用提示区分平台。
  - `pubspec.yaml`：注释改为 Android 已接原生 AAR。
  - `README.md`：模块表、新增「Android 原生能力」章节、未实现清单。
  - `docs/tech-design.md`：0 章状态与范围变更、1 章能力边界、3.4 FFmpeg 方案与三端表、执行约束、5.5 实现状态、5.5.3 通道说明、新增 5.5.3a、7 章目录、8.0 本期口径 + B1~B7、异常行为表、阶段状态表、风险表。
  - `.agents/rules/01~06`：同步状态、优先级、依赖策略、目录、命令、原生通道编码约定。
- 结果：`flutter build apk --debug` EXIT=0（首次 7m40s 失败于 Kotlin 编译，修后 90s 通过）；APK 227MB（原 184MB），`lib/arm64-v8a` 与 `lib/x86_64` 下 FFmpeg so 齐备，`libavcodec.so` 内含 `libmp3lame`、`libavformat.so` 内含 mp4 muxer 与 mpegts demuxer；`flutter analyze` No issues；`flutter test` 60 通过 / 8 个 e2e 按预期跳过；`pubspec.lock` 未变。
- 首次构建错误与修复：`MethodCall` 需单独 import（不是 `MethodChannel.MethodCall`）；`buildResult` 改签名时遗留 `result.success(payload)` 一行。
- 边界：鸿蒙仍无原生实现；Android 未做 TS→MP4 的「只重编音频」失败回退；32 位真机装不上当前 APK；B1~B7 需用户真机执行。
