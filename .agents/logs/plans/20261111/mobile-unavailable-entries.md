> 记录路径：.agents/logs/plans/20261111/mobile-unavailable-entries.md

# 移动端不可用入口收口 + 前置缺陷清理

- 日期：2026-11-11
- 任务：用户在 Android 模拟器连续撞到「没有预览图 / 保存提示未实现 / 转 MP3 提示没有 ffmpeg」，收敛为同一根因（入口可见性未按能力过滤）；按已确认范围推进，不启动移动端原生能力。
- 内容：
  1. `download_tile.dart`：非桌面端隐藏「保存到相册/音乐」与全部手动转码入口，纯 UI，不新增状态、不动原生。
  2. `android/app/src/main/AndroidManifest.xml`：补 `INTERNET` 权限，消除 release 包无网络的确定性缺陷。
  3. 清过时注释：`pubspec.yaml`（AsyncValue / 阶段 5 引 ffmpeg-kit）、`transcode_engine.dart`（三端 ffmpeg-kit 假设 / 阶段 5 占位）。
  4. `docs/tech-design.md` 8.0：同步异常行为表与运行环境说明。
  5. 验证：`flutter analyze`、manifest XML 合法性、debug 构建、改动范围核对。
  6. 按规范写 changes / reviews 日志与工作区记忆。
- 边界：不改 `MainActivity.kt`、不引入 FFmpeg pub 包、不做预览图、不动 cleartext 配置、不动 `.gitignore`、不改测试与 `pubspec.lock`。
- 结果：已完成。`dart analyze` 无问题、manifest XML 合法、`flutter build apk --debug` EXIT=0（39s）、`pubspec.lock` 未变化；A1~A6 仍需用户设备执行，A2 计数器待回收。
