> 记录路径：.agents/logs/reviews/20261112/transcode-library-export.md

# 复核：Android 转码产物入库

- 日期：2026-11-12
- 改动范围：4 个 Dart 源文件 + 1 个新测试文件 + 2 份文档；Kotlin 与 `pubspec` 未动。

## 检查项

| 项 | 结论 |
| --- | --- |
| 桌面链路是否受影响 | 否。`_autoExportToLibrary` 仅在 `AppPlatform.android` 为 true，Windows 上测试也验证了导出器不被调用 |
| DASH 合并是否被误改 | 否。`replaceSource` 分支先走 `_replaceSource()`，入库被跳过，覆盖语义与 5.8 一致 |
| 入库失败会不会把任务判失败 | 不会。异常与失败都在 `_exportToLibrary` 内部吞掉，只写 `exportMessage` |
| 是否有新的平台通道依赖 | 没有。复用 `sniffing_browser/media_exporter`，未改 Kotlin |
| 原有导出提示是否回退 | 是变好：`done` 不再把 `content://` URI 直接给用户看 |
| 测试稳定性 | 用 `onFinished` 的 Completer 等待终态；retry 复检用 5s 轮询，避免固定 sleep 造成的偶发失败 |
| 依赖锁 | `pubspec.lock` 未变 |
| 格式 | 新测试文件已 `dart format`；改动的三个源文件差异仍只落在既有行（Dart 3.12 格式器），按惯例不动周边代码 |

## 结论

通过。`flutter analyze` No issues、`flutter test` 67 通过 / 8 跳过、
`flutter build apk --debug` EXIT=0（37.8s）。

## 残留

- 入库是复制，Android 上一份产物占两份空间；后续若要省空间，可考虑入库成功后删私有副本，但要先确认没有重试/再次导出的需求。
- 已入库的 mp3 是直接 `insert` 进 MediaStore，部分 ROM 的音乐 App 第一次可能需要刷新媒体库才显示（文件本身在 `Music/SniffingBrowser` 里，文件管理器立即可见），等 B4 真机结果再决定要不要补一次 `MediaScanner`。
