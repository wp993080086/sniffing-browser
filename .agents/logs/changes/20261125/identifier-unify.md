> 记录路径：.agents/logs/changes/20261125/identifier-unify.md

# 全仓标识符统一为 sniffingbrowser

- 日期：2026-11-25
- 任务：在 applicationId 改名之后，把仓库里剩下的 `sniffing_browser` 全部改掉，不留两套写法。

## 改动

| 类别 | 位置 | 改动 |
| --- | --- | --- |
| Dart 包名 | `pubspec.yaml` | `name: sniffing_browser` → `sniffingbrowser` |
| Dart import | `lib/` `test/` `tools/` 共 60+ 文件 | `package:sniffing_browser/...` → `package:sniffingbrowser/...` |
| MethodChannel | Dart 4 处 + Kotlin 4 处 | `sniffingbrowser/media_exporter`、`/transcoder`、`/thumbnailer`、`/download_service`，两端同时改 |
| 通知 action | `DownloadForegroundService.kt` | `sniffingbrowser.download.action`（取消下载的广播） |
| WakeLock tag | 同上 | `sniffingbrowser:download`（只影响 `dumpsys power` 里的标识） |
| Windows 工程 | `windows/CMakeLists.txt` | `project()` 与 `BINARY_NAME` → `sniffingbrowser`，产物变 `sniffingbrowser.exe` |
| Windows 版本信息 | `windows/runner/Runner.rc` | `InternalName`、`OriginalFilename` |
| IDE 配置 | `.idea/modules.xml`、两个 `.iml` | 文件改名并更新引用（未被 git 跟踪） |
| 文档 | README、tech-design、rules 01/03/04 | 通道名、包名、exe 名 |

## 为什么这次要动 Dart 包名

上一轮只改了 Android applicationId，理由是「包名和 pubspec name 无关」。这次统一的目标不是上架要求，
而是**一个词在仓库里只该有一种写法**：`sniffing_browser` 和 `sniffingbrowser` 并存时，搜代码、
看日志、对文档都得在脑子里做一次映射，改都改了不如一次改干净。

MethodChannel 必须两端同时改，漏一端就是运行时 `MissingPluginException`，所以 Dart 与 Kotlin 是
在同一次提交里改的，中间不留可提交状态。

## 验证

- `flutter pub get` → `.dart_tool/package_config.json` 中 `"name": "sniffingbrowser"`。
- `flutter analyze lib test tools` → No issues found。
- `flutter test -j 1` → **311 通过 / 9 跳过 / 0 失败**（与改名前一致）。
- `flutter build apk --release` → 105.2 MB；`aapt dump badging`：`package: name='com.wp.sniffingbrowser'`、
  `launchable-activity: com.wp.sniffingbrowser.MainActivity`。
- `flutter build windows --release` → `sniffingbrowser.exe`（分发 zip 40.8 MB）。

## 踩到的坑

`flutter clean` 之后重编 Windows 报 `NUGET-NOTFOUND`：清缓存同时删掉了
`build/windows/x64/packages` 里插件预下载的 NuGet 包（nlohmann.json / WIL / WebView2）。
rules/05 已写明构建前要把 `~/.devtools/nuget.exe` 前置到 PATH，这次就是漏了这一步。
另外先前的 `build/windows/x64/CMakeCache.txt` 里还留着旧 target 名，直接增量构建会报
`No target "sniffing_browser"`——改 Windows 工程名必须连构建目录一起清。

## 影响

- 产物名变化：`sniffing_browser.exe` → `sniffingbrowser.exe`，分发 zip 改为
  `sniffingbrowser-0.1.0-windows-x64.zip`。之前发出去的包需要重新给。
- 已装旧 APK 的设备仍需卸载重装（applicationId 与数据目录都变了）。
