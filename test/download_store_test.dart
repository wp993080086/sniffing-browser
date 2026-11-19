import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/core/platform/media_exporter.dart';
import 'package:sniffing_browser/features/downloader/data/download_queue.dart';
import 'package:sniffing_browser/features/downloader/data/download_store.dart';
import 'package:sniffing_browser/features/downloader/domain/download_status.dart';
import 'package:sniffing_browser/features/downloader/domain/download_task.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_type.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sniffing-download-store-test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  DownloadStore store() =>
      DownloadStore(file: File('${dir.path}/download_tasks.json'));

  File recordFile() => File('${dir.path}/download_tasks.json');

  DownloadTask task({
    String id = 't1',
    MediaType type = MediaType.video,
    DownloadStatus status = DownloadStatus.completed,
    String? savedPath,
  }) {
    final DownloadTask t = DownloadTask(
      id: id,
      mediaId: 'm-$id',
      url: 'https://example.com/$id.mp4',
      type: type,
      fileName: '$id.mp4',
      createdAt: DateTime(2026, 11, 12, 18, 0),
      pageUrl: 'https://example.com/page',
      headers: <String, String>{'Referer': 'https://example.com/page'},
      isStream: type.isStream,
    );
    t.savedPath = savedPath;
    t.setStatus(status);
    return t;
  }

  group('DownloadStore', () {
    test('保存后能原样读回（含配对、合并、导出结论）', () async {
      final DownloadTask video = task(id: 'v', savedPath: '/tmp/v.mp4')
        ..pairedTaskId = 'a'
        ..mergedAudio = true
        ..container = 'mp4'
        ..receivedBytes = 1024
        ..totalBytes = 2048
        ..exportStatus = ExportStatus.done;

      final DownloadTask audio = task(id: 'a', type: MediaType.audio)
        ..isCompanion = true
        ..pairedTaskId = 'v';

      await store().save(<DownloadTask>[video, audio]);
      final List<DownloadTask> loaded = await store().load();

      expect(loaded, hasLength(2));
      expect(loaded[0].id, 'v');
      expect(loaded[0].status, DownloadStatus.completed);
      expect(loaded[0].savedPath, '/tmp/v.mp4');
      expect(loaded[0].pairedTaskId, 'a');
      expect(loaded[0].mergedAudio, isTrue);
      expect(loaded[0].container, 'mp4');
      expect(loaded[0].receivedBytes, 1024);
      expect(loaded[0].exportStatus, ExportStatus.done);
      expect(loaded[0].createdAt, DateTime(2026, 11, 12, 18, 0));
      expect(loaded[0].headers['Referer'], 'https://example.com/page');
      // 界面读的是 statusNotifier 与 progress，不是裸字段
      expect(loaded[0].statusNotifier.value, DownloadStatus.completed);
      expect(loaded[0].progress.value, 1);

      expect(loaded[1].isCompanion, isTrue);
      expect(loaded[1].type, MediaType.audio);
    });

    test('文件不存在时返回空列表', () async {
      expect(await store().load(), isEmpty);
    });

    test('内容损坏时不抛异常，按空列表处理', () async {
      await recordFile().writeAsString('{不是 json');
      expect(await store().load(), isEmpty);
    });

    test('单条记录缺字段只跳过它，其余保留', () async {
      await recordFile().writeAsString(
        jsonEncode(<String, Object?>{
          'version': 1,
          'tasks': <Object?>[
            <String, Object?>{'id': 'broken'},
            <String, Object?>{
              'id': 'ok',
              'mediaId': 'm-ok',
              'url': 'https://example.com/ok.mp4',
              'type': 'video',
              'fileName': 'ok.mp4',
              'createdAt': '2026-11-12T10:00:00.000',
              'status': 'completed',
              'savedPath': '/tmp/ok.mp4',
            },
          ],
        }),
      );

      final List<DownloadTask> loaded = await store().load();
      expect(loaded, hasLength(1));
      expect(loaded.single.id, 'ok');
      expect(loaded.single.status, DownloadStatus.completed);
    });

    test('超过上限时只留最近的任务', () async {
      final List<DownloadTask> many = <DownloadTask>[
        for (int i = 0; i < DownloadStore.maxTasks + 5; i++) task(id: 't$i'),
      ];
      await store().save(many);
      expect(await store().load(), hasLength(DownloadStore.maxTasks));
    });
  });

  group('重启恢复', () {
    test('产物还在就保持完成，文件没了标成失败', () async {
      final File alive = File('${dir.path}/alive.mp4');
      await alive.writeAsBytes(<int>[1, 2, 3]);

      await store().save(<DownloadTask>[
        task(id: 'alive', savedPath: alive.path),
        task(id: 'gone', savedPath: '${dir.path}/gone.mp4'),
      ]);

      final DownloadQueue queue = DownloadQueue(store: store());
      addTearDown(queue.dispose);
      await queue.restore();

      expect(queue.tasks, hasLength(2));
      final DownloadTask kept = queue.tasks.firstWhere(
        (DownloadTask t) => t.id == 'alive',
      );
      expect(kept.status, DownloadStatus.completed);
      expect(kept.savedPath, alive.path);

      final DownloadTask lost = queue.tasks.firstWhere(
        (DownloadTask t) => t.id == 'gone',
      );
      expect(lost.status, DownloadStatus.failed);
      expect(lost.error, contains('文件已被删除'));
      expect(lost.savedPath, isNull);
    });

    test('没下完的一律标成可重试，不自动重跑', () async {
      await store().save(<DownloadTask>[
        task(id: 'running', status: DownloadStatus.running),
        task(id: 'pending', status: DownloadStatus.pending),
        task(id: 'paused', status: DownloadStatus.paused),
      ]);

      final DownloadQueue queue = DownloadQueue(store: store());
      addTearDown(queue.dispose);
      await queue.restore();

      for (final DownloadTask t in queue.tasks) {
        expect(t.status, DownloadStatus.failed, reason: t.id);
        expect(t.error, contains('应用重启'), reason: t.id);
        expect(t.status.canRetry, isTrue, reason: t.id);
      }
      // 恢复不应该偷偷占用下载槽位（地址多半已过期，移动网络下更是白耗流量）
      expect(queue.hasRunning, isFalse);
      expect(queue.activeCount, 0);
    });

    test('已取消与已失败的记录保持原状', () async {
      await store().save(<DownloadTask>[
        task(id: 'canceled', status: DownloadStatus.canceled),
        task(id: 'failed', status: DownloadStatus.failed)..error = '404',
      ]);

      final DownloadQueue queue = DownloadQueue(store: store());
      addTearDown(queue.dispose);
      await queue.restore();

      expect(
        queue.tasks.firstWhere((DownloadTask t) => t.id == 'canceled').status,
        DownloadStatus.canceled,
      );
      expect(
        queue.tasks.firstWhere((DownloadTask t) => t.id == 'failed').error,
        '404',
      );
    });

    test('restore 只执行一次，重复调用不重复加载', () async {
      await store().save(<DownloadTask>[task(id: 't1')]);

      final DownloadQueue queue = DownloadQueue(store: store());
      addTearDown(queue.dispose);

      await queue.restore();
      await queue.restore();
      expect(queue.tasks, hasLength(1));
    });

    test('恢复后的状态会写回磁盘，不会每次启动又变回「下载中」', () async {
      await store().save(<DownloadTask>[
        task(id: 'running', status: DownloadStatus.running),
      ]);

      final DownloadQueue queue = DownloadQueue(store: store());
      addTearDown(queue.dispose);
      await queue.restore();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final List<DownloadTask> reloaded = await store().load();
      expect(reloaded.single.status, DownloadStatus.failed);
      expect(reloaded.single.error, contains('应用重启'));
    });
  });
}
