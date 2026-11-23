> 记录路径：.agents/logs/plans/20261123/bundle-windows-ffmpeg.md

# Windows 包内置 ffmpeg

- 日期：2026-11-23
- 任务：让 Windows 绿包自带 ffmpeg.exe，终端用户不必本机安装。
- 内容：
  - 用户两项决定：只内置 `ffmpeg.exe`（本机 gyan.dev GPLv3 构建，78MB），不内置 `ffprobe.exe`（缺了只影响进度条百分比，转码照常）；二进制不入库，用脚本从开发机拷贝。
  - Dart 侧不改：`system_ffmpeg_engine.dart` 的 `_locateBinary` 已查找 exe 同目录、`ffmpeg/bin/`、`bin/`，把二进制放进 bundle 即可命中。
  - `windows/CMakeLists.txt` 加 `install(FILES ... OPTIONAL)`：有就拷进 exe 同目录，没有就静默跳过（构建不失败，转码提示不可用）。
  - 新增准备脚本（Dart，避免 bat 中文编码问题）：从本机 `~/.devtools/ffmpeg/bin/`、`SNIFF_FFMPEG_DIR`、PATH 找 ffmpeg.exe，拷到 `windows/ffmpeg/bin/`。
  - `windows/ffmpeg/bin/` 加入 .gitignore；随包附带 GPLv3 许可说明与源码获取地址。
  - 更新 README / tech-design，写计划与变更记录；跑一次 `flutter build windows --release` 验证 bundle 内容。
- 结果：已落地。`flutter build windows --release` 成功，bundle 根目录确认有
  `ffmpeg.exe` + `LICENSE.GPLv3.txt` + `THIRD_PARTY_NOTICES.txt`；脚本实跑拷贝成功；
  analyze 干净、转码测试 17 例全过。过程中修复了漏拷许可证全文的问题。
  详见 `.agents/logs/changes/20261123/bundle-windows-ffmpeg.md`。未提交。
