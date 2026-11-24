> 记录路径：.agents/logs/changes/20261124/release-build.md

# 0.1.0 正式包构建

- 日期：2026-11-24
- 任务：把上一轮的日志功能与本次的顶栏 / 日志预览改动拆提交，并打 release 包。

## 提交

按功能拆成四个，每个单独可编译：

| 提交 | 内容 |
| --- | --- |
| `9d7be7f` feat(log) | 运行日志页、`exportBundle`、`LogExporter`、设置页入口、`AppConstants.version` |
| `ccbcb28` feat(log) | 导出后进应用内预览、导出记录页、`LogExporter.list/labelOf` |
| `8e6f531` refactor(header) | 去掉顶栏与设置页重复的诊断入口 |
| `b0de19c` docs | README / tech-design / rules 04、06 / 变更记录 |

`log_exporter.dart`、`diagnostics_page.dart` 和两个测试文件被两轮改动同时碰过，
按「备份最终版 → 还原成第一轮状态 → 提交 → 恢复最终版」拆开，不是用 `git add -p`。

## 构建

| 目标 | 命令 | 产物 | 耗时 |
| --- | --- | --- | --- |
| Android | `flutter build apk --release` | `build/app/outputs/flutter-apk/app-release.apk`（105.2 MB） | 136 s |
| Windows | `flutter build windows --release` | `build/windows/x64/runner/Release/`（99 MB，含内置 `ffmpeg.exe` 78 MB） | 72 s |

Windows 目录另打了 `build/sniffing-browser-0.1.0-windows-x64.zip`（40.8 MB）：
exe 单独拷走会缺 `data/` 与 dll，必须整目录一起分发。

**首次 Windows 构建失败**：`cpp_client_wrapper` 只剩 `include/`，`.cc` 全缺，
报 C1083。删掉 `windows/flutter/ephemeral/cpp_client_wrapper` 让 Flutter 重新生成即可，
与 11-23 那次是同一个问题，因此不新增处理逻辑。

## 已知事项

- APK 仍用 debug 签名（`android/app/build.gradle.kts` 模板默认）。能装能跑，
  但换正式 keystore 后已安装的版本不能直接覆盖升级，需先卸载。
- 未做真机验证：Android 的分享面板、Windows 的「用系统程序打开」各需点一次。
