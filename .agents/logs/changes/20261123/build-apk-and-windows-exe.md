> 记录路径：.agents/logs/changes/20261123/build-apk-and-windows-exe.md

# 打 APK 与 Windows exe

- 日期：2026-11-23
- 任务：基于 81cbcef 最新代码产出 Android APK 与 Windows 绿包 exe。
- 内容：
  - Android：`flutter build apk --debug`，无代码改动。
  - Windows：`flutter build windows --release`，前置 `~/.devtools/nuget.exe` 到 PATH；
    CMake 安装规则把内置 ffmpeg 与许可证拷进 bundle。
- 结果：
  - APK：EXIT=0，111.8s，`build/app/outputs/flutter-apk/app-debug.apk` 213MB。
    `unzip -l` 确认 FFmpeg so 只有 arm64-v8a / x86_64，无 32 位目录。
  - Windows：首次构建 70.5s 后失败，报 `core_implementations.cc` 等 6 个
    `C1083: No such file or directory`。根因：`windows/flutter/ephemeral/cpp_client_wrapper/`
    只剩 `include/`、缺 SDK 拷贝的 .cc 源文件（残留的残缺缓存）。处理：删掉该目录
    让 Flutter tool 重新从 SDK 生成，重建 EXIT=0（增量 45.2s，整个过程 5m51s，
    含 C++ 全量重编）。
  - bundle 根目录 `build/windows/x64/runner/Release/` 校验齐全：
    `sniffing_browser.exe`(82K)、`ffmpeg.exe`(78M)、`LICENSE.GPLv3.txt`(35K)、
    `THIRD_PARTY_NOTICES.txt`(1.7K)，以及 data/ 与 Flutter/WebView2 DLL。
  - stderr 里有 `safe-delete-common.sh: fork: Resource temporarily unavailable`：
    来自沙箱删除钩子的 fork 警告，构建本身成功，产物已核对。
  - 真机 / 真机 Windows 绿包运行验证仍待用户侧执行。
