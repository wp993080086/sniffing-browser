> 记录路径：.agents/logs/changes/20261123/bundle-windows-ffmpeg.md

# Windows 绿包内置 ffmpeg

- 日期：2026-11-23
- 任务：让 Windows 发布包自带 ffmpeg.exe，终端用户不必本机安装即可转码。
- 内容：
  - `windows/CMakeLists.txt`：两条 `install(FILES ... OPTIONAL)`，把
    `windows/ffmpeg/bin/ffmpeg.exe`、`LICENSE.GPLv3.txt`、`THIRD_PARTY_NOTICES.txt`
    拷到 exe 同目录。OPTIONAL 保证没内置时构建照常完成。Dart 侧零改动 ——
    `SystemFfmpegEngine._locateBinary` 本就先查 exe 同目录。
  - `tools/prepare_windows_ffmpeg.dart`：从 `SNIFF_FFMPEG_DIR` / `~/.devtools/ffmpeg/bin/` /
    PATH 找 exe，拷到 `windows/ffmpeg/bin/`。找不到就跳过、不阻断构建。顶部说明
    LGPL 替换方式。
  - `windows/ffmpeg/LICENSE.GPLv3.txt`：从 gnu.org 下载的 GPLv3 全文（35KB）。
  - `windows/ffmpeg/THIRD_PARTY_NOTICES.txt`：组件来源（gyan.dev essentials）、
    GPLv3 义务摘要、源码获取地址、LGPL 替换说明。
  - `.gitignore` 排除 `/windows/ffmpeg/bin/ffmpeg.exe`（78MB 不入库），许可证文本仍入库。
  - README「Windows 打绿包」段与 tech-design 5.7.2 同步说明。
  - 只内置 `ffmpeg.exe`：`ffprobe.exe` 仅用于进度百分比，缺了转码照常成功，省一半体积。
- 结果：
  - 脚本实跑：从 `~/.devtools/ffmpeg/bin/` 拷入 77.4MB，识别为 gyan.dev 6.0 essentials（GPLv3）。
  - `flutter build windows --release` 成功（459s 冷构建 + 14.7s 增量）；bundle 根目录
    确认同时存在 `ffmpeg.exe`(78M)、`LICENSE.GPLv3.txt`(35K)、`THIRD_PARTY_NOTICES.txt`(1.7K)，
    且无多余 `ffmpeg/bin/`。
  - 过程中发现并修复：第一版漏了 LICENSE 的 install 规则，NOTICE 引用的全文没进包 ——
    已补上并重新构建验证。
  - `flutter analyze` 无问题；转码相关测试 17 例全过。
  - 未提交（项目规范禁止主动 commit）。真人机器上运行绿包验证转码仍待做。
