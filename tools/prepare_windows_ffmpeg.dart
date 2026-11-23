// 把本机已有的 ffmpeg.exe 拷到 windows/ffmpeg/bin/，供 CMake install 打进
// Windows 绿包。二进制刻意不入库：78MB 会永久撑大仓库，且许可与版本由
// 构建机自行决定 —— 脚本只负责搬运，不对下载来源做任何假设。
//
// 用法（项目根目录）：
//   dart run tools/prepare_windows_ffmpeg.dart
//
// 查找顺序：SNIFF_FFMPEG_DIR 环境变量 → ~/.devtools/ffmpeg/bin/ →
// ~/.devtools/ → ~/.local/bin/ → 系统 PATH（where ffmpeg）。
// 找不到就直接退出，不报错 —— 没有 ffmpeg 的包照样能构建，只是转码不可用。
//
// LGPL 替换：若不想承担 GPL 义务，从 https://www.gyan.dev/ffmpeg/builds/
// 下载 lgpl 版的 ffmpeg.exe，放到 windows/ffmpeg/bin/ffmpeg.exe 覆盖即可，
// 再更新 windows/ffmpeg/THIRD_PARTY_NOTICES.txt 里的许可证说明。
// 注意 LGPL 构建不含 x264/x265，但本项目的 TS→MP4（-c copy）与 MP3
// 转码（libmp3lame）都能正常工作。

import 'dart:io';

import 'package:path/path.dart' as p;

Future<void> main() async {
  final Directory projectRoot = Directory.current;
  final String cmakeFile = p.join(projectRoot.path, 'windows', 'CMakeLists.txt');
  if (!File(cmakeFile).existsSync()) {
    stderr.writeln('请在项目根目录运行此脚本（找不到 windows/CMakeLists.txt）。');
    exitCode = 2;
    return;
  }

  final File? source = await _findFfmpeg();
  if (source == null) {
    stdout.writeln('未找到 ffmpeg.exe，跳过。');
    stdout.writeln('Windows 包仍可构建，但转码会提示「请安装 ffmpeg」。');
    stdout.writeln('如需内置，请先安装 ffmpeg 或设置 SNIFF_FFMPEG_DIR 后重试。');
    return;
  }

  final Directory targetDir = Directory(
    p.join(projectRoot.path, 'windows', 'ffmpeg', 'bin'),
  );
  await targetDir.create(recursive: true);
  final File target = File(p.join(targetDir.path, 'ffmpeg.exe'));
  await source.copy(target.path);

  stdout.writeln('已拷贝：${source.path}');
  stdout.writeln('    到：${target.path}');
  stdout.writeln('大小：${_sizeLabel(await target.length())}');

  // 顺带取版本首行，让人一眼看出内置的是 GPL 还是 LGPL 构建。
  try {
    final ProcessResult result = await Process.run(target.path, <String>['-version']);
    final String firstLine = (result.stdout as String).split('\n').first.trim();
    stdout.writeln('版本：$firstLine');
  } catch (_) {
    // 版本探测失败不影响拷贝结果。
  }

  stdout.writeln('');
  stdout.writeln('注意：若这是 GPL 构建，请保留 windows/ffmpeg/ 下的');
  stdout.writeln('LICENSE.GPLv3.txt 与 THIRD_PARTY_NOTICES.txt —— CMake 会随包拷入。');
  stdout.writeln('下一步：flutter build windows --release');
}

Future<File?> _findFfmpeg() async {
  const String name = 'ffmpeg.exe';
  final List<String> candidates = <String>[];

  final String? override = Platform.environment['SNIFF_FFMPEG_DIR'];
  if (override != null && override.isNotEmpty) {
    candidates.add(p.join(override, name));
  }

  final String? home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'];
  if (home != null) {
    candidates.addAll(<String>[
      p.join(home, '.devtools', 'ffmpeg', 'bin', name),
      p.join(home, '.devtools', name),
      p.join(home, '.local', 'bin', name),
    ]);
  }

  for (final String candidate in candidates) {
    final File file = File(candidate);
    if (await file.exists()) return file;
  }

  try {
    final ProcessResult result =
        await Process.run('where', <String>[name], runInShell: true);
    if (result.exitCode == 0) {
      final List<String> found = (result.stdout as String)
          .split(RegExp(r'\r?\n'))
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .toList();
      if (found.isNotEmpty && await File(found.first).exists()) {
        return File(found.first);
      }
    }
  } catch (_) {
    // where 不可用就跳过 PATH 查找。
  }

  return null;
}

String _sizeLabel(int bytes) {
  if (bytes < 1024 * 1024) return '$bytes B';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
