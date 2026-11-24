> 记录路径：.agents/logs/plans/20261123/build-apk-and-windows-exe.md

# 打 APK 与 Windows exe

- 日期：2026-11-23
- 任务：基于当前最新代码（81cbcef）分别产出 Android APK 与 Windows 绿包 exe。
- 内容：
  - Android：按 `.agents/rules/05` 用 `flutter build apk --debug`，产物
    `build/app/outputs/flutter-apk/app-debug.apk`；32 位 ABI 由 Gradle 剔除。
  - Windows：`flutter build windows --release`，前置 `~/.devtools/nuget.exe` 到 PATH；
    内置 ffmpeg 已由前次准备脚本拷到 `windows/ffmpeg/bin/`，CMake 会随包安装
    `ffmpeg.exe` + GPLv3 许可证 + NOTICE。
  - 两个构建串行执行，避免 Flutter 构建缓存竞争；完成后核对产物时间、大小与
    bundle 内 ffmpeg/许可证是否齐全。
- 结果：两个构建均成功。
  - APK：`flutter build apk --debug` EXIT=0（111.8s），`app-debug.apk` 213MB，
    `unzip -l` 确认只含 arm64-v8a / x86_64 的 libffmpegkit so，32 位已剔除。
  - Windows：`flutter build windows --release` EXIT=0。首次因 ephemeral 的
    `cpp_client_wrapper` 只剩 include/、缺 .cc 源文件而失败（C1083），删掉残缺
    缓存目录后重建成功；bundle 根目录含 `sniffing_browser.exe`(82K)、
    `ffmpeg.exe`(78M)、`LICENSE.GPLv3.txt`、`THIRD_PARTY_NOTICES.txt`。
  详见 `.agents/logs/changes/20261123/build-apk-and-windows-exe.md`。
