import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/features/downloader/data/file_downloader.dart';

/// 前 [failTimes] 次在 TLS 握手阶段断开，之后正常返回全量。
///
/// 真机熄屏时系统回收 socket，dio 收到就是这个形状：type = unknown，
/// message 为空，原因在 error.error 上。
class _HandshakeAdapter implements HttpClientAdapter {
  _HandshakeAdapter(this.full, {this.failTimes = 1});

  final List<int> full;
  final int failTimes;

  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    if (calls <= failTimes) {
      throw const HandshakeException('Connection terminated during handshake');
    }
    return ResponseBody.fromBytes(
      Uint8List.fromList(full),
      200,
      headers: <String, List<String>>{
        Headers.contentLengthHeader: <String>['${full.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 一直 404，用来确认「站点拒绝」不会占用网络重试预算。
class _NotFoundAdapter implements HttpClientAdapter {
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromBytes(<int>[], 404);
  }

  @override
  void close({bool force = false}) {}
}

FileDownloader _downloader(
  HttpClientAdapter adapter, {
  List<Duration> networkWaits = const <Duration>[],
}) {
  final Dio dio = Dio(
    BaseOptions(
      validateStatus: (int? code) => code != null && code < 400,
      responseType: ResponseType.bytes,
    ),
  );
  dio.httpClientAdapter = adapter;
  return FileDownloader(dio: dio, networkWaits: networkWaits);
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dl_net');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  final List<int> full = List<int>.generate(300, (int i) => i % 251);

  test('握手被打断后自动重试接上，不需要用户点重试', () async {
    final _HandshakeAdapter adapter = _HandshakeAdapter(full, failTimes: 2);

    await _downloader(
      adapter,
      networkWaits: const <Duration>[Duration.zero, Duration.zero],
    ).download(url: 'https://s.surrit.com/v.mp4', target: File('${dir.path}/v.mp4'));

    expect(adapter.calls, 3);
    expect(await File('${dir.path}/v.mp4').readAsBytes(), full);
  });

  test('握手失败报出「握手阶段被中断」，不再是干巴巴的未知错误', () async {
    final _HandshakeAdapter adapter = _HandshakeAdapter(full, failTimes: 99);

    await expectLater(
      _downloader(adapter).download(
        url: 'https://s.surrit.com/v.mp4',
        target: File('${dir.path}/v.mp4'),
      ),
      throwsA(
        isA<DownloadException>().having(
          (DownloadException e) => e.message,
          'message',
          allOf(contains('握手'), contains('HandshakeException')),
        ),
      ),
    );
    expect(adapter.calls, 1);
  });

  test('网络重试预算用尽才放弃，不会无限重试', () async {
    final _HandshakeAdapter adapter = _HandshakeAdapter(full, failTimes: 99);
    const List<Duration> waits = <Duration>[Duration.zero, Duration.zero];

    await expectLater(
      _downloader(adapter, networkWaits: waits).download(
        url: 'https://s.surrit.com/v.mp4',
        target: File('${dir.path}/v.mp4'),
      ),
      throwsA(isA<DownloadException>()),
    );
    // 首轮 + 两次等待重试
    expect(adapter.calls, 3);
  });

  test('404 不走网络预算，仍按 retries 快速失败', () async {
    final _NotFoundAdapter adapter = _NotFoundAdapter();

    await expectLater(
      _downloader(
        adapter,
        // 给足网络预算：如果 404 被误判成网络错误，请求次数会变成 6 次
        networkWaits: const <Duration>[
          Duration.zero,
          Duration.zero,
          Duration.zero,
          Duration.zero,
          Duration.zero,
        ],
      ).download(
        url: 'https://s.surrit.com/v.mp4',
        target: File('${dir.path}/v.mp4'),
        retries: 2,
      ),
      throwsA(
        isA<DownloadException>().having(
          (DownloadException e) => e.message,
          'message',
          contains('404'),
        ),
      ),
    );
    expect(adapter.calls, 3);
  });
}
