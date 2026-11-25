import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/core/platform/storage_paths.dart';
import 'package:sniffingbrowser/features/transcoder/data/transcode_engine.dart';
import 'package:sniffingbrowser/features/transcoder/data/transcode_queue.dart';
import 'package:sniffingbrowser/features/transcoder/domain/transcode_job.dart';

class _FakeEngine extends TranscodeEngine {
  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> run({
    required String inputPath,
    required String outputPath,
    required TranscodeKind kind,
    required void Function(double progress) onProgress,
    required void Function() isCancelled,
    String? secondaryInputPath,
  }) async {
    await File(outputPath).writeAsBytes(<int>[1, 2, 3]);
    onProgress(1);
  }

  @override
  Future<void> cancel(String jobId) async {}
}

void main() {
  late Directory root;

  setUp(() async {
    root = Directory('${Directory.systemTemp.path}/sniffing-dedupe-test');
    if (await root.exists()) await root.delete(recursive: true);
    await StoragePaths.initWithRoot(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('同源同类型去重时，第二次入队的完成回调不会被吞掉', () async {
    final TranscodeQueue queue = TranscodeQueue(engine: _FakeEngine());
    final File source = File('${root.path}/clip.ts');
    await source.writeAsBytes(<int>[9]);

    int firstCalls = 0;
    int secondCalls = 0;
    final TranscodeJob first = queue.enqueue(
      sourcePath: source.path,
      kind: TranscodeKind.tsToMp4,
      onFinished: (TranscodeStatus _) => firstCalls++,
    );
    final TranscodeJob second = queue.enqueue(
      sourcePath: source.path,
      kind: TranscodeKind.tsToMp4,
      onFinished: (TranscodeStatus _) => secondCalls++,
    );

    expect(second, same(first));
    expect(first.finishedCallbacks, hasLength(2));

    // 等异步转码跑完再结束，否则 tearDown 删目录会撞上输出文件的写句柄。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(firstCalls, 1);
    expect(secondCalls, 1);
    queue.dispose();
  });
}
