import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/platform/storage_paths.dart';

/// 把导出的日志落成 txt。
///
/// 导出文件放在 `logs/` 里，和 `app.log` 同一个目录：用户问"文件在哪"时
/// 只需要说一个位置。只保留最近 [keepFiles] 份 —— 日志页每点一次导出就多
/// 一个文件，不设上限迟早会把用户空间吃掉。
class LogExporter {
  const LogExporter._();

  /// 保留的导出份数（不含 `app.log` 本体）。
  static const int keepFiles = 3;

  static const String _prefix = 'log-';

  static Directory get directory =>
      Directory(p.join(StoragePaths.root.path, 'logs'));

  /// 写出一份导出文件，返回文件句柄。
  ///
  /// [now] 只给测试用：名字里带秒级时间戳，测试要能固定住它。
  static Future<File> write(String content, {DateTime? now}) async {
    final Directory dir = directory;
    await dir.create(recursive: true);

    final File file = _uniqueFile(dir, now ?? DateTime.now());
    await file.writeAsString(content, flush: true);
    await prune();
    return file;
  }

  /// 删掉超出保留份数的旧导出。
  ///
  /// 失败不抛：删不掉旧文件不影响这次导出能不能看，最多多占点空间。
  static Future<void> prune() async {
    try {
      final List<File> files = await _exportFiles();
      if (files.length <= keepFiles) return;
      for (final File file in files.skip(keepFiles)) {
        try {
          await file.delete();
        } catch (_) {
          // 被占用就留着，下次再删。
        }
      }
    } catch (_) {
      // 目录不可读，忽略。
    }
  }

  /// 现有导出文件，按文件名倒序（新的在前）。
  ///
  /// 文件名里是 `yyyyMMdd-HHmmss`，字典序即时间序，不用读文件属性。
  static Future<List<File>> _exportFiles() async {
    final Directory dir = directory;
    if (!await dir.exists()) return <File>[];
    final List<File> files = await dir
        .list()
        .where((FileSystemEntity e) => e is File)
        .cast<File>()
        .where(
          (File f) =>
              p.basename(f.path).startsWith(_prefix) &&
              p.extension(f.path).toLowerCase() == '.txt',
        )
        .toList();
    files.sort((File a, File b) => b.path.compareTo(a.path));
    return files;
  }

  static File _uniqueFile(Directory dir, DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    final String date =
        '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    File candidate = File(p.join(dir.path, '$_prefix$date.txt'));
    int index = 1;
    // 同一秒连点两次导出不该覆盖前一份。
    while (candidate.existsSync()) {
      candidate = File(p.join(dir.path, '$_prefix$date-$index.txt'));
      index++;
    }
    return candidate;
  }
}
