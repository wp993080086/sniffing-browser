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

/// 第一次握手就断（熄屏断网的样子），之后正常返回。
class _FlakyAdapter implements HttpClientAdapter {
  _FlakyAdapter(this.bytes, {this.failTimes = 1, this.alwaysFail = false});

  final List<int> bytes;

  /// 前几次握手失败。下载器内部会重试 `retries` 次，要越过它才会落到队列。
  final int failTimes;

  /// 一直握手失败，模拟长时间断网。
  final bool alwaysFail;

  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    if (alwaysFail || calls <= failTimes) {
      throw const HandshakeException('Connection terminated during handshake');
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

/// 一直返回 403，模拟链接签名过期 / 被 WAF 拒绝。
class _ForbiddenAdapter implements HttpClientAdapter {
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromBytes(
      Uint8List.fromList(<int>[102, 111, 114, 98, 105, 100, 100, 101, 110]),
      403,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/plain'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('queue_net');
    await StoragePaths.initWithRoot(root);
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  final List<int> payload = List<int>.generate(400, (int i) => i % 251);

  test('断网时进入「等待网络」，网络回来后自动续传完成', () async {
    // 越过下载器内部那 3 次（attempt 0/1/2），让失败真正落到队列
    final _FlakyAdapter adapter = _FlakyAdapter(payload, failTimes: 3);
    final Dio dio = Dio(
      BaseOptions(
        validateStatus: (int? code) => code != null && code < 400,
        responseType: ResponseType.bytes,
      ),
    );
    dio.httpClientAdapter = adapter;

    final DownloadQueue queue = DownloadQueue(
      downloader: FileDownloader(dio: dio),
      // 用例里不等真实秒数，节奏本身由 defaultNetworkWaits 决定
      networkWaits: const <Duration>[Duration.zero],
    );

    final DownloadTask task = queue.enqueue(
      MediaItem(
        id: 'm1',
        url: 'https://example.com/v.mp4',
        type: MediaType.video,
        firstSeenAt: DateTime.now(),
        fileName: 'v.mp4',
      ),
    );

    final List<DownloadStatus> seen = <DownloadStatus>[];
    task.statusNotifier.addListener(() => seen.add(task.status));

    final Stopwatch watch = Stopwatch()..start();
    while (!task.status.isFinished &&
        watch.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(task.status, DownloadStatus.completed, reason: task.error ?? '');
    // 中间必须经过「等待网络」：这是界面上看得见的那一步
    expect(seen, contains(DownloadStatus.waitingNetwork));
    expect(adapter.calls, 4);
    expect(await File(task.savedPath!).readAsBytes(), payload);
  });

  test('等待网络期间取消，任务是已取消而不是失败', () async {
    final Dio dio = Dio(
      BaseOptions(
        validateStatus: (int? code) => code != null && code < 400,
        responseType: ResponseType.bytes,
      ),
    );
    // 永远握手失败：模拟长时间断网
    dio.httpClientAdapter = _FlakyAdapter(payload, alwaysFail: true);

    final DownloadQueue queue = DownloadQueue(
      downloader: FileDownloader(dio: dio),
      // 一分钟一档，确保取消发生在等待里
      networkWaits: const <Duration>[Duration(minutes: 1)],
    );

    final DownloadTask task = queue.enqueue(
      MediaItem(
        id: 'm2',
        url: 'https://example.com/v2.mp4',
        type: MediaType.video,
        firstSeenAt: DateTime.now(),
        fileName: 'v2.mp4',
      ),
    );

    // 等它进入等待网络
    final Stopwatch watch = Stopwatch()..start();
    while (task.status != DownloadStatus.waitingNetwork &&
        watch.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(task.status, DownloadStatus.waitingNetwork);

    queue.cancel(task.id);

    final Stopwatch after = Stopwatch()..start();
    while (!task.status.isFinished &&
        after.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(task.status, DownloadStatus.canceled);
  });

  test('403 自动重试有限轮次，之后仍失败', () async {
    final Dio dio = Dio(
      BaseOptions(
        validateStatus: (int? code) => code != null && code < 400,
        responseType: ResponseType.bytes,
      ),
    );
    final _ForbiddenAdapter adapter = _ForbiddenAdapter();
    dio.httpClientAdapter = adapter;

    final DownloadQueue queue = DownloadQueue(
      downloader: FileDownloader(dio: dio),
      // 用例里不等真实秒数，轮次与上限逻辑不变
      networkWaits: const <Duration>[Duration.zero],
    );

    final DownloadTask task = queue.enqueue(
      MediaItem(
        id: 'm3',
        url: 'https://example.com/v3.mp4',
        type: MediaType.video,
        firstSeenAt: DateTime.now(),
        fileName: 'v3.mp4',
      ),
    );

    final List<String?> reasons = <String?>[];
    task.statusNotifier.addListener(() {
      if (task.status == DownloadStatus.waitingNetwork) {
        reasons.add(task.retryReason);
      }
    });

    final Stopwatch watch = Stopwatch()..start();
    while (!task.status.isFinished &&
        watch.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(task.status, DownloadStatus.failed);
    expect(adapter.calls, greaterThan(1));
    // 3 轮 403 等待，文案是「站点拒绝访问」，不是「等待网络」
    expect(reasons, <String?>['站点拒绝访问', '站点拒绝访问', '站点拒绝访问']);
  });
}
