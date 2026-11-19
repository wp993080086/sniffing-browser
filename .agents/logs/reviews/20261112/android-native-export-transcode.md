> 记录路径：.agents/logs/reviews/20261112/android-native-export-transcode.md

# 复核：Android 原生导出 + FFmpegKit 转码

- 日期：2026-11-12
- 任务：审查本轮改动是否最小、是否回退已验收链路、依赖选型是否可靠

## 依赖核对（动手前先查证，未凭记忆写坐标）

- 官方 `com.arthenica:ffmpeg-kit-*` 2025-01 退役、2025-04-01 从 Maven Central 移除，直接加依赖会解析失败；`ffmpeg_kit_flutter_new` 主包是 **Full GPL**（含 x264/x265），且 4.6.6 才修 AGP 9 的 KGP 冲突。
- 选定 `dev.ffmpegkit-maintained:ffmpeg-kit-full:8.1.9`：Maven Central 可解析（HTTP 200 / 31MB AAR），POM 为 LGPL-3.0，包名与 API 仍是 `com.arthenica.ffmpegkit`，FFmpeg 8.1.2，SDK 35 / 16KB 对齐。
- 用 `unzip + javap` 实际核对过 `FFmpegKit.executeWithArgumentsAsync`、`FFprobeKit.getMediaInformation`、`Statistics.getTime`、`ReturnCode.isCancel/isSuccess`、`Session.getAllLogsAsString` 的签名，Kotlin 调用未凭猜测写。
- 传递依赖 `com.arthenica:smart-exception-java:0.2.1` 可解析（HTTP 200）。
- AAR 的 `AndroidManifest.xml` 声明 `minSdkVersion 24`，与 `flutter.minSdkVersion = 24` 一致，无 manifest 冲突。

## 架构与范围

- **没有引入 FFmpeg 的 Flutter pub 包**：`pubspec.yaml` 只改注释，`pubspec.lock` 未变（已用 `git diff --quiet` 确认）。桌面系统 ffmpeg 链路、鸿蒙构建、20 项 W1 回归均不受影响。
- `TranscodeQueue` / `TranscodeJob` / 桌面引擎的队列逻辑一行未动；`TranscodeCancelled` 上移到抽象层，桌面文件 re-export 保持既有 import 路径，测试无需改动。
- 桌面唯一行为变化：`download_tile` 的能力判断从「非桌面隐藏」改为「桌面 + Android 可用」，鸿蒙仍隐藏；导出文案三分支修正了原本 `ExportTarget.file` 会误显示「保存到音乐目录」的死代码分支。
- 导出走 MediaStore `IS_PENDING`，API 29+ 不申请权限；`WRITE_EXTERNAL_STORAGE` 用 `maxSdkVersion=28` 限定，只服务 legacy 兜底，不扩大运行时权限面。
- `ndk.abiFilters` 与 AAR 的 ABI 集合一致，避免打出「能装但缺 so」的 APK；`checkAvailable()` 真加载 native 库，加载失败返回 false 而不是崩。

## 验证结果

- `flutter build apk --debug` EXIT=0。首次失败于 Kotlin 编译（`MethodCall` 需单独 import、`buildResult` 改签名遗留一行 `result.success`），已修；修后 90s 通过。
- APK 227MB（原 184MB）。`lib/arm64-v8a` 与 `lib/x86_64` 下 `libavcodec/avformat/avutil/ffmpegkit/swresample` 齐备；`grep -a` 确认 `libmp3lame`、`mov,mp4,m4a,3gp...`、`mpegts` 都在，三类转换的编解码能力成立。
- `flutter analyze` No issues found；`flutter test` 60 通过 / 8 个 e2e 按预期跳过；新增 `native_transcode_engine_test.dart` 8/8。
- 格式核对：把修改文件复制到临时目录跑 `dart format` 后 diff，差异全部是 Dart 3.12 新格式器对**既有行**的改动（`system_ffmpeg_engine` 的 `for` 列表、`download_tile` 的 `any(...)`、`transcode_engine` 的 `_channel` 声明），本轮新增行无格式问题；故未格式化周边代码，避免无关 diff。新增测试文件已 `dart format`。

## 残余风险与待办

- **静态验证不等于运行时验证**：B1~B7 必须在 USB 真机跑过才能判定功能可用。重点看 B1（相册可见）、B4（libmp3lame 实际产出 mp3）、B5（取消语义）、B6（无音轨中文提示）。
- `startTranscode` 的 result 挂起时长等于转码时长；若原生侧异常未回调，队列会一直显示「转换中」。目前 `cancelTranscode` 是唯一外部中断手段，未加超时，属已知边界。
- Android 未实现 TS→MP4 的「只重编音频」失败回退（桌面有），AC-3 / MPEG-2 音频源会直接失败并显示 ffmpeg 错误行。已在文档中登记为已知差异。
- 32 位真机装不上当前 APK；若用户的 USB 真机是 32 位，需自行编译 AAR 或改用系统 API 方案。
- 鸿蒙侧仍无原生实现，菜单入口保持隐藏。
- 结果：**通过**，可交用户真机验证。
