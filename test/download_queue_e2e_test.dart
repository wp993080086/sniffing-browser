// 下载队列的端到端验证：从 enqueue 到文件落盘，走完整状态机。
//
//   RUN_E2E=1 flutter test test/download_queue_e2e_test.dart
//
// 为什么单独测队列而不是只测下载器：用户点的是「下载」按钮，走的是队列。
// 队列里的状态迁移、临时目录清理、重名处理这些出错，下载器再对也没用。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/core/platform/storage_paths.dart';
import 'package:sniffing_browser/features/downloader/data/download_queue.dart';
import 'package:sniffing_browser/features/downloader/domain/download_status.dart';
import 'package:sniffing_browser/features/downloader/domain/download_task.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_item.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_type.dart';

const String _tsBase = 'https://test-streams.mux.dev/x36xhzz/url_2';
const List<String> _segments = <String>[
  '$_tsBase/url_526/193039199_mp4_h264_aac_ld_7.ts',
  '$_tsBase/url_527/193039199_mp4_h264_aac_ld_7.ts',
  '$_tsBase/url_528/193039199_mp4_h264_aac_ld_7.ts',
];

final bool _enabled = Platform.environment['RUN_E2E'] == '1';

void main() {
  group('下载队列', () {
    late HttpServer server;
    late Directory root;

    setUpAll(() async {
      root = Directory('${Directory.systemTemp.path}/sniffing-queue-e2e');
      if (await root.exists()) await root.delete(recursive: true);
      await StoragePaths.initWithRoot(root);

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        final HttpResponse res = request.response;
        if (request.uri.path.endsWith('.m3u8')) {
          final StringBuffer sb = StringBuffer()
            ..writeln('#EXTM3U')
            ..writeln('#EXT-X-VERSION:3')
            ..writeln('#EXT-X-TARGETDURATION:10')
            ..writeln('#EXT-X-PLAYLIST-TYPE:VOD');
          for (final String url in _segments) {
            sb
              ..writeln('#EXTINF:10.0,')
              ..writeln(url);
          }
          sb.writeln('#EXT-X-ENDLIST');
          res.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
          res.write(sb.toString());
        } else {
          res.statusCode = HttpStatus.notFound;
        }
        await res.close();
      });
    });

    tearDownAll(() async {
      await server.close(force: true);
    });

    test('HLS 任务从入队到完成，文件真正落盘', () async {
      final DownloadQueue queue = DownloadQueue();
      final String url = 'http://127.0.0.1:${server.port}/plain.m3u8';

      final MediaItem item = MediaItem(
        id: 'test-hls',
        url: url,
        type: MediaType.hls,
        firstSeenAt: DateTime.now(),
        fileName: 'test_stream.m3u8',
      );

      final DownloadTask task = queue.enqueue(item);
      // 队列空闲时 enqueue 会立刻开始跑，所以这里可能是 pending 也可能是 running
      expect(
        task.status == DownloadStatus.pending ||
            task.status == DownloadStatus.running,
        isTrue,
        reason: '入队后状态异常: ${task.status}',
      );

      await _waitFor(queue, task.id, const Duration(minutes: 3));

      expect(task.status, DownloadStatus.completed,
          reason: '任务未完成，error=${task.error}');
      expect(task.savedPath, isNotNull);

      final File output = File(task.savedPath!);
      expect(await output.exists(), isTrue, reason: '文件没有落盘');
      final int size = await output.length();
      expect(size, greaterThan(100 * 1024), reason: '文件太小: $size');
      expect(size % 188, 0, reason: 'TS 包没对齐，合并可能错位');

      expect(task.progress.value, 1.0);

      // 分片临时目录必须清理，否则每下完一个视频就留一堆垃圾
      final Directory tmp = StoragePaths.tempDirFor(task.id);
      final bool tmpExists = await tmp.exists();
      final bool tmpEmpty =
          !tmpExists || await tmp.list().isEmpty;
      expect(tmpEmpty, isTrue, reason: '临时目录没有清理');

      queue.dispose();
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('同一个媒体重复入队不会产生第二个任务', () async {
      final DownloadQueue queue = DownloadQueue();
      final MediaItem item = MediaItem(
        id: 'test-dedup',
        url: 'https://example.com/a.png',
        type: MediaType.image,
        firstSeenAt: DateTime.now(),
        fileName: 'a.png',
      );

      final DownloadTask first = queue.enqueue(item);
      final DownloadTask second = queue.enqueue(item);
      expect(identical(first, second), isTrue, reason: '重复入队应复用已有任务');
      expect(queue.tasks.length, 1);

      queue.cancel(first.id);
      // 取消是异步的，等任务真正停下再 dispose，否则销毁 notifier 后
      // 残留的请求回调会打到已销毁的对象上。
      await Future<void>.delayed(const Duration(milliseconds: 500));
      queue.dispose();
    });

    test('文件名重复时自动加序号，不覆盖已有文件', () async {
      final File existing = File('${StoragePaths.downloads.path}/dup.png');
      await existing.writeAsBytes(<int>[1, 2, 3]);

      final File next = StoragePaths.uniqueFile('dup.png');
      expect(next.path, isNot(existing.path));
      expect(next.path, contains('(1)'));

      await existing.delete();
    });
  }, skip: _enabled ? false : '设置 RUN_E2E=1 才运行（需要网络）');
}

/// 轮询到任务进入终态。队列是异步的，没有 Future 可以直接 await。
Future<void> _waitFor(
  DownloadQueue queue,
  String taskId,
  Duration limit,
) async {
  final DateTime deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    for (final DownloadTask task in queue.tasks) {
      if (task.id != taskId) continue;
      if (task.status == DownloadStatus.completed ||
          task.status == DownloadStatus.failed ||
          task.status == DownloadStatus.canceled) {
        return;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw StateError('等待任务完成超时');
}
