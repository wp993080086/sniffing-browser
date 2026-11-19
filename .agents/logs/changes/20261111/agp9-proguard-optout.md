> 记录路径：.agents/logs/changes/20261111/agp9-proguard-optout.md

# 修复 AGP 9 与 flutter_inappwebview_android 1.1.3 的构建冲突

- 日期：2026-11-11
- 任务：让 Android debug 构建通过，解除 F5 启动前的 Gradle 报错
- 内容：
  - `android/gradle.properties` 增加 `android.r8.proguardAndroidTxt.disallowed=false`，附中文注释说明原因与删除时机。该开关来自 AGP 9.0 官方 release notes：默认值由 false 改为 true，设回 false 即恢复接受 `getDefaultProguardFile('proguard-android.txt')`
  - 未改 `pubspec.yaml` / `pubspec.lock`、未改 pub cache、未改 Dart 或原生源码
  - 未处理的既有改动（均非本次产生）：`android/gradle/wrapper/gradle-wrapper.properties` 已被改成本地 `file:///C:/androidGradle/gradle-9.1.0-all.zip`；`android/build/reports/` 未被 .gitignore 忽略
- 结果：`flutter build apk --debug` 成功，耗时 2m38s，EXIT=0，产出 `build/app/outputs/flutter-apk/app-debug.apk`（147 MB）。完整日志在 `build/android-build.log`（已被忽略）。Windows 端走 CMake、不读 gradle.properties，无需重跑 W1
