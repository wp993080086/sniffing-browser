> 记录路径：.agents/logs/changes/20261111/mobile-unavailable-entries.md

# 移动端不可用入口收口 + 前置缺陷清理

- 日期：2026-11-11
- 任务：按「继续推进」落地此前已列明的范围：收掉移动端必然失败的菜单入口、补 release 网络权限、清过时注释、同步 8.0 文档。
- 内容：
  - `lib/features/downloader/presentation/download_tile.dart`：`_availableKinds()` 非桌面端直接返回空；`canExport` 增加 `PlatformInfo.isDesktop` 条件。共 +6/-2 行，纯 UI，不新增状态、不动原生。
  - `android/app/src/main/AndroidManifest.xml`：main 补 `INTERNET` 权限，debug / profile 原有声明保留。
  - `pubspec.yaml`：状态管理注释改为「应用级 ChangeNotifierProvider + 任务级 ValueNotifier」；文末 FFmpeg 段改为「桌面调系统 ffmpeg 进程 / 移动端 MethodChannel 占位」。
  - `lib/features/transcoder/data/transcode_engine.dart`：两处文档注释去掉三端 ffmpeg-kit 与「阶段 5 接入」假设。
  - `docs/tech-design.md`：8.0「本期不做」补资源缩略图并声明不做的能力不留入口；运行环境 INTERNET 条目改为已补；异常行为表改两行并补 DASH 合并失败 / 无缩略图两行；第 9 节风险表两行注明入口已隐藏。
- 结果：`dart analyze` 两个改动文件 No issues found；manifest XML 解析 OK；`flutter build apk --debug` EXIT=0（39s，产出 184MB apk）；`pubspec.lock` 无变化；文档围栏 56 个成对、章节 0~10 编号不变。
- 未做：`MainActivity.kt`、FFmpeg pub 包、预览图、cleartext 配置、`.gitignore`、测试。dart format 报的差异全是既有代码在 Dart 3.12 新风格下的表现，按「不优化周边格式」未格式化。
