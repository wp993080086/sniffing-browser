> 记录路径：.agents/logs/changes/20261111/vscode-f5-launch.md

# 支持 VSCode / Cursor F5 调试

- 日期：2026-11-11
- 任务：让用户能在 IDE 里按 F5 启动 Android debug 会话做 A1~A6 验收
- 内容：
  - 新增 `.vscode/launch.json`：单个 `dart` launch 配置，`program` 指向 `lib/main.dart`、`flutterMode: debug`；不硬编码 `deviceId`，由状态栏选设备，同一配置也能跑 Windows
  - `docs/tech-design.md` 8.0 运行环境补一句：F5 等价于 `flutter run -d <选中设备>`，需确认状态栏选中的是 Android 而非 Windows
  - 前提核实：VSCode 与 Cursor 均装了 Dart / Flutter 扩展；`.gitignore` 的 `#.vscode/` 处于注释状态，配置会被 git 跟踪
- 结果：`python -m json.tool` 校验 JSON 通过；`git status` 新增 `?? .vscode/`；未改任何 Dart / 原生源码
