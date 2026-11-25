> 记录路径：.agents/logs/changes/20261125/package-id-rename.md

# Android 包名去掉下划线

- 日期：2026-11-25
- 任务：`com.wp.sniffing_browser` → `com.wp.sniffingbrowser`（applicationId / namespace / Kotlin 包路径 / 文档）。

## 改动

| 文件 | 改动 |
| --- | --- |
| `android/app/build.gradle.kts` | `namespace` 与 `applicationId` 改为 `com.wp.sniffingbrowser` |
| `android/app/src/main/kotlin/com/wp/sniffing_browser/` → `.../sniffingbrowser/` | `git mv` 整个目录，保留文件历史；6 个 Kotlin 文件的 `package` 声明同步 |
| `README.md` | 日志路径示例里的 `/Android/data/com.wp.sniffingbrowser/` |
| `docs/tech-design.md` | 目录树与 `DownloadForegroundService.kt` 路径两处 |
| `.agents/rules/04-目录结构.md` | Kotlin 源码目录 |

**没改的**：
- Dart 侧 `package:sniffing_browser/...` 是 pubspec 的包名，与 Android applicationId 无关，改了会牵动全部 import；
- MethodChannel 名（`sniffing_browser/media_exporter` 等）是自定义标识，不是包名；
- `.agents/logs/` 与 `.workbuddy/memory` 里的历史记录保持原样，改了会让当时的记录失真。

## 验证

- `flutter build apk --debug` 通过（169.6 s）。
- merged manifest：`package="com.wp.sniffingbrowser"`，
  `android:authorities="com.wp.sniffingbrowser.fileprovider"`（`${applicationId}` 自动跟随）。
- `aapt dump badging`：`package: name='com.wp.sniffingbrowser'`、
  `launchable-activity: com.wp.sniffingbrowser.MainActivity`。
- `flutter analyze lib test` 零 issue。

## 影响

- 应用数据目录随之变化：`/sdcard/Android/data/com.wp.sniffingbrowser/`。
  装了旧包的设备需要卸载重装，旧下载产物不会自动迁移 —— 与 11-20 那次改包名同样是
  「旧数据可丢弃」的前提。
- 已发布的 release APK 需重新构建。
