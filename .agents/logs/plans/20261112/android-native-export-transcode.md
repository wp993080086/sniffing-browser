> 记录路径：.agents/logs/plans/20261112/android-native-export-transcode.md

# Android 真机：补齐导出与转 MP3

- 日期：2026-11-12
- 触发：用户说明是在 **Android USB 真机**（非模拟器）上跑，要求把下载完成后缺失的「导出」「转 MP3」补上。
- 现状判定：`MainActivity.kt` 是空壳，两个 MethodChannel 只有 Dart 侧占位；上一轮为防误提示把移动端入口收起。属于原生能力缺失，不是 UI bug。
- 用户拍板（两问）：
  1. 功能范围 = **导出 + 转码都补**；
  2. 转码路线 = **引入 ffmpeg-kit**（接受 APK 增大、可能的构建冲突）。
- 技术方案（在动手前确定的取舍）：
  - 只在 Android 原生侧加 Maven AAR，**不引入 FFmpeg 的 Flutter pub 包**——保持 `pubspec.yaml` / `pubspec.lock` 不变，桌面系统 ffmpeg 链路与鸿蒙构建不受影响，复用项目已有的 `TranscodeEngine` 抽象。
  - 不用已退役的 `com.arthenica:ffmpeg-kit-*`（2025-04-01 从 Maven Central 移除），也不用 `ffmpeg_kit_flutter_new`（Full GPL）；选 `dev.ffmpegkit-maintained:ffmpeg-kit-full:8.1.9`（LGPL、同包名同 API、FFmpeg 8.1.2、含 libmp3lame、SDK 35 / 16KB 对齐）。
  - AAR 只发布 arm64-v8a / x86_64，必须用 `ndk.abiFilters` 同步限定，否则 32 位 ABI 的 APK 会缺 `libffmpegkit.so` 而崩。
- 通道契约：`startTranscode` 的 result 挂起到 FFmpegKit session 结束才回复，Dart 侧 await 天然等于等待完成；进度由原生反向 `onProgress` 推送；取消走 `cancelTranscode` → `FFmpegKit.cancel(sessionId)`。
- 范围边界：鸿蒙仍不接，入口保持隐藏；桌面代码除 `TranscodeCancelled` 上移外不动；不缩略图、不做 MPD 重组。
- 验收：构建 APK、核对 so 内 `libmp3lame` / mp4 muxer / mpegts demuxer；`flutter analyze`、`flutter test` 全量；新增协议单测覆盖 done/canceled/unsupported/failed/进度/取消/可用性。B1~B7 交用户在真机跑。
