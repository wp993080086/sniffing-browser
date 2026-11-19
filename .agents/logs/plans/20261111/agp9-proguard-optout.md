> 记录路径：.agents/logs/plans/20261111/agp9-proguard-optout.md

# 修复 AGP 9 与 flutter_inappwebview_android 1.1.3 的构建冲突

- 日期：2026-11-11
- 任务：用户在 Android 模拟器按 F5 启动时报 `getDefaultProguardFile('proguard-android.txt') is no longer supported`，需要让 Android debug 构建通过
- 内容：
  1. 核对根因：Flutter 3.44.9 模板给的是 AGP 9.0.1 + Gradle 9.1.0；插件 `flutter_inappwebview_android 1.1.3` 的 `android/build.gradle` 第 43/46 行仍用旧 proguard 文件名，AGP 9 在 evaluation 阶段直接抛错
  2. 方案取舍：改 pub cache（会被 `pub cache repair` 还原，不可持续）／升级插件（上游 issue #2765 已修但最新稳定版仍是 1.1.3，只有 beta）／降 AGP（需连带降 Gradle wrapper 与 Kotlin，改动面大）→ 选 `android/gradle.properties` 加 AGP 9 官方 opt-out
  3. 只改一行配置 + 注释，不动依赖版本、不动 pub cache、不动 Dart / 原生源码
  4. 回归确认：跑 `flutter build apk --debug`，通过后再跑一次 Windows 回归确认没影响其它端
- 结果：已完成。`android/gradle.properties` 加官方 opt-out 后 `flutter build apk --debug` 成功（EXIT=0，2m38s，产出 app-debug.apk）；详见 changes / reviews 同名记录。Windows 端不受影响，未重跑 W1
