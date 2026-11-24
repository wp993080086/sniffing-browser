import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/core/platform/storage_paths.dart';
import 'package:sniffing_browser/features/downloader/data/download_queue.dart';
import 'package:sniffing_browser/features/downloader/data/download_store.dart';
import 'package:sniffing_browser/features/downloader/data/file_downloader.dart';
import 'package:sniffing_browser/features/downloader/domain/download_status.dart';
import 'package:sniffing_browser/features/downloader/domain/download_task.dart';
import 'package:sniffing_browser/features/settings/data/app_settings.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_item.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_type.dart';
import 'package:sniffing_browser/features/transcoder/data/transcode_engine.dart';
import 'package:sniffing_browser/features/transcoder/data/transcode_queue.dart';
import 'package:sniffing_browser/features/transcoder/domain/transcode_job.dart';

/// 本地落盘的假下载器：不联网，直接写出目标文件。
class _FakeDownloader extends FileDownloader {
  @override
  Future<File> download({
    required String url,
    required File target,
    Map<String, String> headers = const <String, String>{},
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
    int retries = 2,
    MediaType? expectType,
  }) async {
    await target.writeAsBytes(<int>[1, 2, 3, 4]);
    onProgress?.call(4, 4);
    return target;
  }
}

class _FakeEngine extends TranscodeEngine {
  final List<TranscodeKind> kinds = <TranscodeKind>[];

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> run({
    required String inputPath,
    required String outputPath,
    required TranscodeKind kind,
    required void Function(double) onProgress,
    required void Function() isCancelled,
    String? secondaryInputPath,
  }) async {
    kinds.add(kind);
    onProgress(1);
  }

  @override
  Future<void> cancel(String jobId) async {}
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sniffing-after-test');
    await StoragePaths.initWithRoot(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  MediaItem item(MediaType type, String name) => MediaItem(
    id: 'm-$name',
    url: 'https://example.com/$name',
    type: type,
    firstSeenAt: DateTime.now(),
    fileName: name,
  );

  Future<void> waitFinished(DownloadQueue queue) async {
    for (int i = 0; i < 200; i++) {
      final bool busy = queue.tasks.any(
        (DownloadTask t) =>
            t.status == DownloadStatus.pending ||
            t.status == DownloadStatus.running,
      );
      if (!busy && queue.tasks.isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  group('完成后动作', () {
    test('设为「转为 MP4」时，TS 文件下载完成后自动排一次转码', () async {
      final _FakeEngine engine = _FakeEngine();
      final TranscodeQueue transcoder = TranscodeQueue(engine: engine);
      addTearDown(transcoder.dispose);

      final DownloadQueue queue = DownloadQueue(
        downloader: _FakeDownloader(),
        transcoder: transcoder,
        afterDownload: () => AfterDownload.toMp4,
      );
      addTearDown(queue.dispose);

      final DownloadTask task = queue.enqueue(item(MediaType.video, 'a.ts'));
      await waitFinished(queue);

      expect(task.status, DownloadStatus.completed);
      expect(transcoder.jobs.length, 1);
      expect(transcoder.jobs.first.kind, TranscodeKind.tsToMp4);
      expect(transcoder.jobs.first.sourcePath, task.savedPath);
    });

    test('不适用就跳过，不报错也不排任务', () async {
      final _FakeEngine engine = _FakeEngine();
      final TranscodeQueue transcoder = TranscodeQueue(engine: engine);
      addTearDown(transcoder.dispose);

      final DownloadQueue queue = DownloadQueue(
        downloader: _FakeDownloader(),
        transcoder: transcoder,
        // 图片没有可做的转码，选了「转为 MP4」也只能略过。
        afterDownload: () => AfterDownload.toMp4,
      );
      addTearDown(queue.dispose);

      final DownloadTask task = queue.enqueue(item(MediaType.image, 'a.png'));
      await waitFinished(queue);

      expect(task.status, DownloadStatus.completed);
      expect(transcoder.jobs, isEmpty);
    });

    test('默认不做事', () async {
      final _FakeEngine engine = _FakeEngine();
      final TranscodeQueue transcoder = TranscodeQueue(engine: engine);
      addTearDown(transcoder.dispose);

      final DownloadQueue queue = DownloadQueue(
        downloader: _FakeDownloader(),
        transcoder: transcoder,
      );
      addTearDown(queue.dispose);

      queue.enqueue(item(MediaType.video, 'b.ts'));
      await waitFinished(queue);

      expect(transcoder.jobs, isEmpty);
    });
  });

  group('重启自动续传', () {
    test('开启后未完成任务重新排队并接着下', () async {
      final DownloadStore store = DownloadStore(
        file: File('${root.path}/download_tasks.json'),
      );
      final DownloadTask saved = DownloadTask(
        id: 'resume-1',
        mediaId: 'm1',
        url: 'https://example.com/x.mp4',
        type: MediaType.video,
        fileName: 'x.mp4',
        createdAt: DateTime(2026, 11, 24),
      );
      // 落盘时是「下载中」，重启后属于被中断。
      saved.setStatus(DownloadStatus.running);
      await store.save(<DownloadTask>[saved]);

      final DownloadQueue queue = DownloadQueue(
        downloader: _FakeDownloader(),
        store: store,
        autoResume: () => true,
      );
      addTearDown(queue.dispose);

      await queue.restore();
      await waitFinished(queue);

      expect(queue.tasks.length, 1);
      expect(queue.tasks.first.error, isNull);
      expect(queue.tasks.first.status, DownloadStatus.completed);
    });

    test('关闭后只标成「已中断，可重试」，不联网', () async {
      final DownloadStore store = DownloadStore(
        file: File('${root.path}/download_tasks.json'),
      );
      final DownloadTask saved = DownloadTask(
        id: 'resume-2',
        mediaId: 'm2',
        url: 'https://example.com/y.mp4',
        type: MediaType.video,
        fileName: 'y.mp4',
        createdAt: DateTime(2026, 11, 24),
      );
      saved.setStatus(DownloadStatus.running);
      await store.save(<DownloadTask>[saved]);

      final DownloadQueue queue = DownloadQueue(
        downloader: _FakeDownloader(),
        store: store,
        autoResume: () => false,
      );
      addTearDown(queue.dispose);

      await queue.restore();

      expect(queue.tasks.single.status, DownloadStatus.failed);
      expect(queue.tasks.single.error, contains('已中断'));
    });
  });

  group('删除文件', () {
    late DownloadQueue queue;
    late DownloadTask ready;

    setUp(() async {
      queue = DownloadQueue(downloader: _FakeDownloader());
      addTearDown(queue.dispose);
      ready = queue.enqueue(item(MediaType.image, 'del.png'));
      await waitFinished(queue);
      expect(ready.savedPath, isNotNull);
    });

    test('删记录同时删掉私有目录里的产物', () async {
      final File file = File(ready.savedPath!);
      expect(await file.exists(), isTrue);

      final int deleted = await queue.deleteFiles(<String>[ready.id]);

      expect(deleted, 1);
      expect(await file.exists(), isFalse);
      expect(queue.tasks, isEmpty);
    });

    test('路径在私有目录外时不删文件，只移除记录', () async {
      final File outside = File('${root.parent.path}/outside-${ready.id}.bin');
      await outside.writeAsBytes(<int>[9, 9, 9]);
      addTearDown(() async {
        if (await outside.exists()) await outside.delete();
      });
      ready.savedPath = outside.path;

      final int deleted = await queue.deleteFiles(<String>[ready.id]);

      expect(deleted, 0);
      expect(await outside.exists(), isTrue);
      expect(queue.tasks, isEmpty);
    });
  });
}
