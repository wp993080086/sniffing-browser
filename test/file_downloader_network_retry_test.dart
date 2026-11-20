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

/// 一直 404，用来确认「站点拒绝」不会被标成 network。
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

FileDownloader _downloader(HttpClientAdapter adapter) {
  final Dio dio = Dio(
    BaseOptions(
      validateStatus: (int? code) => code != null && code < 400,
      responseType: ResponseType.bytes,
    ),
  );
  dio.httpClientAdapter = adapter;
  return FileDownloader(dio: dio);
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

  test('握手被打断后按 retries 自动重上一次，能自己接上', () async {
    final _HandshakeAdapter adapter = _HandshakeAdapter(full, failTimes: 1);

    await _downloader(adapter).download(
      url: 'https://s.surrit.com/v.mp4',
      target: File('${dir.path}/v.mp4'),
    );

    expect(adapter.calls, 2);
    expect(await File('${dir.path}/v.mp4').readAsBytes(), full);
  });

  test('握手失败报出「握手阶段被中断」，并标记为网络类', () async {
    final _HandshakeAdapter adapter = _HandshakeAdapter(full, failTimes: 99);

    await expectLater(
      _downloader(adapter).download(
        url: 'https://s.surrit.com/v.mp4',
        target: File('${dir.path}/v.mp4'),
        retries: 0,
      ),
      throwsA(
        isA<DownloadException>()
            .having(
              (DownloadException e) => e.message,
              'message',
              allOf(contains('握手'), contains('HandshakeException')),
            )
            // 队列靠这个标记决定「等网络」还是「直接失败」
            .having((DownloadException e) => e.network, 'network', isTrue),
      ),
    );
  });

  test('404 不会被标成网络类，仍是快速失败', () async {
    final _NotFoundAdapter adapter = _NotFoundAdapter();

    await expectLater(
      _downloader(adapter).download(
        url: 'https://s.surrit.com/v.mp4',
        target: File('${dir.path}/v.mp4'),
        retries: 2,
      ),
      throwsA(
        isA<DownloadException>()
            .having(
              (DownloadException e) => e.message,
              'message',
              contains('404'),
            )
            .having((DownloadException e) => e.network, 'network', isFalse),
      ),
    );
    expect(adapter.calls, 3);
  });
}
