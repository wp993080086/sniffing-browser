import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/features/downloader/data/segment_writer.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('seg-writer-test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('写入后目标一次性拿到完整内容，临时文件不残留', () async {
    final File target = File('${dir.path}/seg_0.part');
    await writeSegmentAtomically(target, <int>[1, 2, 3, 4]);

    expect(await target.readAsBytes(), <int>[1, 2, 3, 4]);
    expect(File('${target.path}.writing').existsSync(), isFalse);
  });

  test('上次的 .writing 残留会被覆盖，不污染新分片', () async {
    final File target = File('${dir.path}/seg_1.part');
    await File('${target.path}.writing').writeAsBytes(<int>[9, 9, 9, 9, 9]);

    await writeSegmentAtomically(target, <int>[1, 2]);

    expect(await target.readAsBytes(), <int>[1, 2]);
  });

  test('目标已存在（空残留）时也能替换', () async {
    final File target = File('${dir.path}/seg_2.part');
    await target.writeAsBytes(<int>[]);

    await writeSegmentAtomically(target, <int>[7, 8]);

    expect(await target.readAsBytes(), <int>[7, 8]);
  });
}
