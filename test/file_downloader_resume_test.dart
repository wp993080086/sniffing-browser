import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/features/downloader/data/file_downloader.dart';

/// 第一次请求模拟「响应体下到一半连接断开」，之后的请求正常工作。
/// [ignoreRange] 为真时后端不认 Range，一律回 200 全量。
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.full, {this.ignoreRange = false, this.breakFirst = true});

  final List<int> full;
  final bool ignoreRange;

  /// 第一次请求是否断在响应体中途。
  final bool breakFirst;

  int calls = 0;
  final List<String?> ranges = <String?>[];

  static Map<String, List<String>> _headers(int? length) {
    return <String, List<String>>{
      Headers.contentTypeHeader: <String>['video/mp4'],
      if (length != null) Headers.contentLengthHeader: <String>['$length'],
    };
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    final String? range = options.headers['Range']?.toString();
    ranges.add(range);

    if (breakFirst && calls == 1) {
      final StreamController<Uint8List> body = StreamController<Uint8List>();
      body.add(Uint8List.fromList(full.sublist(0, full.length ~/ 2)));
      // 真机上 dio 收到的就是这类底层异常：message 为空，原因落在 error 上
      body.addError(
        const SocketException('Connection closed while receiving data'),
      );
      unawaited(body.close());
      return ResponseBody(body.stream, 200, headers: _headers(full.length));
    }

    if (range == null || ignoreRange) {
      return ResponseBody.fromBytes(
        Uint8List.fromList(full),
        200,
        headers: _headers(full.length),
      );
    }

    final int offset = int.parse(
      range.replaceFirst('bytes=', '').replaceAll('-', ''),
    );
    return ResponseBody.fromBytes(
      Uint8List.fromList(full.sublist(offset)),
      206,
      headers: <String, List<String>>{
        Headers.contentLengthHeader: <String>['${full.length - offset}'],
        'content-range': <String>[
          'bytes $offset-${full.length - 1}/${full.length}',
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 每次都断在响应体中途，用来验证错误文案与残留文件。
class _AlwaysBreakAdapter implements HttpClientAdapter {
  _AlwaysBreakAdapter({this.prefix = const <int>[1, 2, 3]});

  /// 断流前写进去的字节，模拟「已经下了一半」。
  final List<int> prefix;

  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    final StreamController<Uint8List> body = StreamController<Uint8List>();
    body.add(Uint8List.fromList(prefix));
    body.addError(
      const SocketException('Connection closed while receiving data'),
    );
    unawaited(body.close());
    return ResponseBody(
      body.stream,
      200,
      headers: <String, List<String>>{
        Headers.contentLengthHeader: <String>['${prefix.length * 2}'],
      },
    );
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
    dir = await Directory.systemTemp.createTemp('dl_resume');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  final List<int> full = List<int>.generate(2000, (int i) => i % 251);

  test('中途断流后按 Range 续传，内容完整且只多一次请求', () async {
    final _ScriptedAdapter adapter = _ScriptedAdapter(full);
    final File target = File('${dir.path}/v.mp4');

    await _downloader(
      adapter,
    ).download(url: 'https://s.surrit.com/v.mp4', target: target);

    expect(adapter.calls, 2);
    // 第二次请求接着半截往下要，不是从头重来
    expect(adapter.ranges[1], 'bytes=${full.length ~/ 2}-');
    expect(await target.readAsBytes(), full);
    expect(await File('${target.path}.part').exists(), isFalse);
  });

  test('服务端忽略 Range 回全量时丢弃重下，不产出错位文件', () async {
    final _ScriptedAdapter adapter = _ScriptedAdapter(full, ignoreRange: true);
    final File target = File('${dir.path}/v.mp4');

    await _downloader(
      adapter,
    ).download(url: 'https://s.surrit.com/v.mp4', target: target);

    // 断流一次 → 带 Range 被回 200（已追加坏）→ 丢掉重新干净下一次
    expect(adapter.calls, 3);
    expect(await target.readAsBytes(), full);
  });

  test('一直断流时报出真实原因，不是干巴巴的「未知错误」', () async {
    final _AlwaysBreakAdapter adapter = _AlwaysBreakAdapter();

    await expectLater(
      _downloader(adapter).download(
        url: 'https://s.surrit.com/v.mp4',
        target: File('${dir.path}/v.mp4'),
        retries: 0,
      ),
      throwsA(
        isA<DownloadException>().having(
          (DownloadException e) => e.message,
          'message',
          allOf(contains('连接被中途断开'), contains('Connection closed')),
        ),
      ),
    );
    expect(adapter.calls, 1);
  });

  test('失败后保留 .part，下次下载从断点接着下', () async {
    const int kept = 500;
    final File target = File('${dir.path}/v.mp4');

    await expectLater(
      _downloader(_AlwaysBreakAdapter(prefix: full.sublist(0, kept))).download(
        url: 'https://s.surrit.com/v.mp4',
        target: target,
        retries: 0,
      ),
      throwsA(isA<DownloadException>()),
    );

    final File part = File('${target.path}.part');
    expect(await part.exists(), isTrue);
    expect(await part.length(), kept);

    // 相当于用户点「重试」：第一个请求就带 Range，直接补齐
    final _ScriptedAdapter resume = _ScriptedAdapter(full, breakFirst: false);
    await _downloader(resume).download(
      url: 'https://s.surrit.com/v.mp4',
      target: target,
    );

    expect(resume.ranges.first, 'bytes=$kept-');
    expect(resume.calls, 1);
    expect(await target.readAsBytes(), full);
  });
}
