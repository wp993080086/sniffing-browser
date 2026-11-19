import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/features/transcoder/data/transcode_engine.dart';
import 'package:sniffing_browser/features/transcoder/data/transcode_queue.dart';
import 'package:sniffing_browser/features/transcoder/data/transcode_store.dart';
import 'package:sniffing_browser/features/transcoder/domain/transcode_job.dart';

class _FakeEngine extends TranscodeEngine {
  int runs = 0;

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
    runs++;
    await File(outputPath).writeAsBytes(<int>[1]);
    onProgress(1);
  }

  @override
  Future<void> cancel(String jobId) async {}
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sniffing-store-test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  TranscodeStore store() => TranscodeStore(file: File('${dir.path}/jobs.json'));

  TranscodeJob job({
    String id = 'j1',
    TranscodeKind kind = TranscodeKind.audioToMp3,
    String output = '/tmp/out.mp3',
  }) {
    return TranscodeJob(
      id: id,
      sourcePath: '/tmp/src.mp4',
      outputPath: output,
      kind: kind,
      createdAt: DateTime(2026, 11, 12, 17, 30),
      displayName: 'src.mp4',
    );
  }

  group('TranscodeStore', () {
    test('保存后能原样读回（含状态与入库结论）', () async {
      final TranscodeStore target = store();
      final TranscodeJob done = job(id: 'a');
      done.setStatus(TranscodeStatus.completed);
      done.exportMessage = '已保存到「音乐/SniffingBrowser」';
      done.exported = true;
      done.mediaUri = 'content://media/external/audio/media/42';

      final TranscodeJob failed = job(id: 'b', kind: TranscodeKind.tsToMp4);
      failed.setStatus(TranscodeStatus.failed);
      failed.error = '输出文件为空';

      await target.save(<TranscodeJob>[done, failed]);
      final List<TranscodeJob> loaded = await store().load();

      expect(loaded, hasLength(2));
      expect(loaded[0].id, 'a');
      expect(loaded[0].status, TranscodeStatus.completed);
      expect(loaded[0].exported, isTrue);
      expect(loaded[0].exportMessage, '已保存到「音乐/SniffingBrowser」');
      // 「打开产物」用的是入库 URI，重启后必须还在，否则历史任务点了打不开
      expect(loaded[0].mediaUri, 'content://media/external/audio/media/42');
      expect(loaded[0].createdAt, DateTime(2026, 11, 12, 17, 30));
      expect(loaded[1].kind, TranscodeKind.tsToMp4);
      expect(loaded[1].error, '输出文件为空');
    });

    test('文件不存在时返回空列表', () async {
      expect(await store().load(), isEmpty);
    });

    test('内容损坏时不抛异常，按空列表处理', () async {
      final File file = File('${dir.path}/jobs.json');
      await file.writeAsString('{不是 json');
      expect(await store().load(), isEmpty);
    });

    test('单条记录缺字段只跳过它，其余保留', () async {
      final File file = File('${dir.path}/jobs.json');
      await file.writeAsString(
        jsonEncode(<String, Object?>{
          'version': 1,
          'jobs': <Object?>[
            <String, Object?>{'id': 'broken'},
            <String, Object?>{
              'id': 'ok',
              'sourcePath': '/tmp/s.mp4',
              'outputPath': '/tmp/o.mp3',
              'kind': 'audioToMp3',
              'createdAt': '2026-11-12T10:00:00.000',
              'status': 'completed',
            },
          ],
        }),
      );

      final List<TranscodeJob> loaded = await store().load();
      expect(loaded, hasLength(1));
      expect(loaded.single.id, 'ok');
      expect(loaded.single.status, TranscodeStatus.completed);
    });

    test('超过上限时只留最近的任务', () async {
      final List<TranscodeJob> many = <TranscodeJob>[
        for (int i = 0; i < TranscodeStore.maxJobs + 5; i++) job(id: 'j$i'),
      ];
      await store().save(many);
      expect(await store().load(), hasLength(TranscodeStore.maxJobs));
    });
  });

  group('重启恢复', () {
    test('running 标成中断，pending 继续跑', () async {
      final File file = File('${dir.path}/jobs.json');
      final File produced = File('${dir.path}/produced.mp3');
      await file.writeAsString(
        jsonEncode(<String, Object?>{
          'version': 1,
          'jobs': <Object?>[
            <String, Object?>{
              'id': 'interrupted',
              'sourcePath': '/tmp/a.mp4',
              'outputPath': '/tmp/a.mp3',
              'kind': 'audioToMp3',
              'createdAt': '2026-11-12T10:00:00.000',
              'status': 'running',
              'displayName': 'a.mp4',
            },
            <String, Object?>{
              'id': 'pending',
              'sourcePath': '/tmp/b.mp4',
              'outputPath': produced.path,
              'kind': 'audioToMp3',
              'createdAt': '2026-11-12T10:01:00.000',
              'status': 'pending',
              'displayName': 'b.mp4',
            },
          ],
        }),
      );

      final _FakeEngine engine = _FakeEngine();
      final TranscodeQueue queue = TranscodeQueue(
        engine: engine,
        autoExportToLibrary: false,
        store: store(),
      );
      addTearDown(queue.dispose);

      await queue.restore();

      expect(queue.jobs, hasLength(2));
      final TranscodeJob interrupted = queue.jobs.firstWhere(
        (TranscodeJob j) => j.id == 'interrupted',
      );
      expect(interrupted.status, TranscodeStatus.failed);
      expect(interrupted.error, contains('应用重启'));

      // pending 的那条会接着跑完
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!await produced.exists() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(engine.runs, 1);
      final TranscodeJob resumed = queue.jobs.firstWhere(
        (TranscodeJob j) => j.id == 'pending',
      );
      expect(resumed.status, TranscodeStatus.completed);
    });

    test('restore 只执行一次，重复调用不重复加载', () async {
      final TranscodeQueue queue = TranscodeQueue(
        engine: _FakeEngine(),
        autoExportToLibrary: false,
        store: store(),
      );
      addTearDown(queue.dispose);

      await queue.restore();
      await queue.restore();
      expect(queue.jobs, isEmpty);
    });

    test('移除与清空会同步到磁盘', () async {
      final TranscodeQueue queue = TranscodeQueue(
        engine: _FakeEngine(),
        autoExportToLibrary: false,
        store: store(),
      );
      addTearDown(queue.dispose);

      final File outA = File('${dir.path}/a.mp3');
      final TranscodeJob a = queue.enqueue(
        sourcePath: '/tmp/a.mp4',
        kind: TranscodeKind.audioToMp3,
        outputPath: outA.path,
      );
      final File outB = File('${dir.path}/b.mp3');
      queue.enqueue(
        sourcePath: '/tmp/b.mp4',
        kind: TranscodeKind.audioToMp3,
        outputPath: outB.path,
      );

      // 等两个任务都跑完，再移除其中一个
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
      while (queue.jobs.any((TranscodeJob j) => !j.status.isFinished) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      queue.remove(a.id);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final List<TranscodeJob> loaded = await store().load();
      expect(loaded.map((TranscodeJob j) => j.id), isNot(contains(a.id)));

      queue.clearFinished();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(await store().load(), isEmpty);
    });
  });
}
