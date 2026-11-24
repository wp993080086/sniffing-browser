import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sniffing_browser/core/platform/storage_paths.dart';
import 'package:sniffing_browser/features/diagnostics/data/log_exporter.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sniff_export_');
    await StoragePaths.initWithRoot(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('导出文件落在 logs 目录，名字带时间戳', () async {
    final File file = await LogExporter.write(
      'hello',
      now: DateTime(2026, 11, 24, 16, 30, 5),
    );

    expect(p.dirname(file.path), LogExporter.directory.path);
    expect(p.basename(file.path), 'log-20261124-163005.txt');
    expect(await file.readAsString(), 'hello');
  });

  test('同一秒内连续导出不会覆盖前一份', () async {
    final DateTime now = DateTime(2026, 11, 24, 16, 30, 5);
    final File first = await LogExporter.write('一', now: now);
    final File second = await LogExporter.write('二', now: now);

    expect(first.path, isNot(second.path));
    expect(await first.readAsString(), '一');
    expect(await second.readAsString(), '二');
  });

  test('只保留最近 3 份导出', () async {
    for (int i = 0; i < 5; i++) {
      await LogExporter.write('第 $i 份', now: DateTime(2026, 11, 24, 16, 30, i));
    }

    final List<String> names =
        Directory(LogExporter.directory.path)
            .listSync()
            .whereType<File>()
            .map((File f) => p.basename(f.path))
            .toList()
          ..sort();

    expect(names.length, LogExporter.keepFiles);
    // 留下来的是最后三次，最早的两次被删掉。
    expect(names, <String>[
      'log-20261124-163002.txt',
      'log-20261124-163003.txt',
      'log-20261124-163004.txt',
    ]);
  });

  test('list 按时间倒序返回现存的导出', () async {
    for (int i = 0; i < 2; i++) {
      await LogExporter.write('第 $i 份', now: DateTime(2026, 11, 24, 16, 30, i));
    }

    final List<File> files = await LogExporter.list();

    expect(files.map((File f) => p.basename(f.path)).toList(), <String>[
      'log-20261124-163001.txt',
      'log-20261124-163000.txt',
    ]);
  });

  test('目录还不存在时 list 返回空而不是抛异常', () async {
    expect(await LogExporter.list(), isEmpty);
  });

  test('labelOf 把文件名里的时间戳转成可读标签', () {
    final File file = File(
      p.join(LogExporter.directory.path, 'log-20261124-163005.txt'),
    );
    expect(LogExporter.labelOf(file), '2026-11-24 16:30:05');

    // 同一秒的第二份带 `-1` 后缀，时间部分仍然认得出来。
    final File duplicated = File(
      p.join(LogExporter.directory.path, 'log-20261124-163005-1.txt'),
    );
    expect(LogExporter.labelOf(duplicated), '2026-11-24 16:30:05');
  });

  test('名字被改过时 labelOf 回退到文件名', () {
    final File file = File(p.join(LogExporter.directory.path, '随手改的.txt'));
    expect(LogExporter.labelOf(file), '随手改的');
  });
}
