import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/core/platform/storage_paths.dart';
import 'package:sniffing_browser/features/downloader/data/download_queue.dart';
import 'package:sniffing_browser/features/downloader/data/file_downloader.dart';
import 'package:sniffing_browser/features/downloader/domain/download_status.dart';
import 'package:sniffing_browser/features/downloader/domain/download_task.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_item.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_type.dart';

/// 每次 fetch 都拖一段时间，给测试留出「下载中」的窗口去点暂停。
class _SlowAdapter implements HttpClientAdapter {
  _SlowAdapter(this.bytes, this.delay);

  final List<int> bytes;
  final Duration delay;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    if (cancelFuture != null) {
      // 尊重取消：暂停时请求必须真的中断，否则任务会在暂停期间偷偷下完。
      await Future.any<Object?>(<Future<Object?>>[
        Future<void>.delayed(delay),
        cancelFuture.then<Object?>((_) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.cancel,
            error: 'pause',
          );
        }),
      ]);
    } else {
      await Future<void>.delayed(delay);
    }
    return ResponseBody.fromBytes(
      Uint8List.fromList(bytes),
      200,
      headers: <String, List<String>>{
        Headers.contentLengthHeader: <String>['${bytes.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory root;
  final List<int> payload = List<int>.generate(400, (int i) => i % 251);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('queue_pause');
    await StoragePaths.initWithRoot(root);
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  DownloadQueue buildQueue(_SlowAdapter adapter) => DownloadQueue(
    downloader: FileDownloader(
      dio: Dio(
        BaseOptions(
          validateStatus: (int? code) => code != null && code < 400,
          responseType: ResponseType.bytes,
        ),
      )..httpClientAdapter = adapter,
    ),
  );

  DownloadTask enqueueOne(DownloadQueue queue) => queue.enqueue(
    MediaItem(
      id: 'm1',
      url: 'https://example.com/v.mp4',
      type: MediaType.video,
      firstSeenAt: DateTime.now(),
      fileName: 'v.mp4',
    ),
  );

  test('暂停全部后任务落在 paused 而不是 canceled，进度不清零', () async {
    final _SlowAdapter adapter = _SlowAdapter(payload, const Duration(milliseconds: 600));
    final DownloadQueue queue = buildQueue(adapter);
    final DownloadTask task = enqueueOne(queue);

    while (task.status != DownloadStatus.running) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    queue.pauseAll();
    // 等 token 取消的 catch 走完
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(task.status, DownloadStatus.paused);
    expect(task.error, isNull);
    expect(queue.hasPaused, isTrue);
    queue.dispose();
  });

  test('暂停后继续，任务重新跑完且进度从断点恢复', () async {
    final _SlowAdapter adapter = _SlowAdapter(payload, const Duration(milliseconds: 1500));
    final DownloadQueue queue = buildQueue(adapter);
    final DownloadTask task = enqueueOne(queue);

    while (task.status != DownloadStatus.running) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    queue.pauseAll();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(task.status, DownloadStatus.paused);

    queue.resumeAll();
    final Stopwatch watch = Stopwatch()..start();
    while (task.status != DownloadStatus.completed &&
        watch.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(task.status, DownloadStatus.completed, reason: task.error ?? '');
    expect(await File(task.savedPath!).readAsBytes(), payload);
    queue.dispose();
  });

  test('取消全部会把暂停的任务也标成已取消', () async {
    final _SlowAdapter adapter = _SlowAdapter(payload, const Duration(milliseconds: 600));
    final DownloadQueue queue = buildQueue(adapter);
    final DownloadTask task = enqueueOne(queue);

    while (task.status != DownloadStatus.running) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    queue.pauseAll();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(task.status, DownloadStatus.paused);

    queue.cancelAll();
    expect(task.status, DownloadStatus.canceled);
    expect(queue.hasPaused, isFalse);
    queue.dispose();
  });
}
