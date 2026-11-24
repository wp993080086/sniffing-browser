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
}
