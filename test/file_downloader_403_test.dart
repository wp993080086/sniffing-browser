import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/core/platform/browser_headers.dart';
import 'package:sniffingbrowser/features/downloader/data/file_downloader.dart';

/// 模拟 Cloudflare 的 Browser Integrity Check：只要 UA 声称自己是浏览器
/// 就 403，中性 UA 放行。真机上就是这么分的。
class _UaGateAdapter implements HttpClientAdapter {
  final List<Map<String, String>> seen = <Map<String, String>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(Map<String, String>.from(options.headers));
    final String ua = options.headers['User-Agent']?.toString() ?? '';
    final bool blocked = ua.contains('Mozilla/');
    return ResponseBody.fromBytes(
      utf8.encode(blocked ? '<html>blocked</html>' : 'body'),
      blocked ? 403 : 200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/octet-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FixedAdapter implements HttpClientAdapter {
  _FixedAdapter(this.code);

  final int code;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromBytes(
      utf8.encode('body'),
      code,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/octet-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const String _browserUa =
    'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

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
    dir = await Directory.systemTemp.createTemp('dl403');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('浏览器 UA 被 403 后换成中性 UA 成功', () async {
    final _UaGateAdapter adapter = _UaGateAdapter();
    final File target = File('${dir.path}/a.m3u8');

    await _downloader(adapter).download(
      url: 'https://b.surrit.com/a.m3u8',
      target: target,
      headers: <String, String>{
        'Referer': 'https://missav.ws/x',
        'User-Agent': _browserUa,
      },
      retries: 0,
    );

    expect(await target.exists(), isTrue);
    expect(adapter.seen.length, greaterThanOrEqualTo(3));
    // 最后一次换成了中性 UA，并且不再冒充浏览器发客户端提示
    expect(adapter.seen.last['User-Agent'], kNeutralUserAgent);
    expect(
      adapter.seen.last.keys.any((String k) => k.startsWith('sec-ch-ua')),
      isFalse,
    );
    // Referer 每次都带着
    for (final Map<String, String> sent in adapter.seen) {
      expect(sent['Referer'], 'https://missav.ws/x');
    }
  });

  test('404 不换头重试，直接失败', () async {
    final _FixedAdapter adapter = _FixedAdapter(404);
    final File target = File('${dir.path}/a.mp4');

    await expectLater(
      _downloader(adapter).download(
        url: 'https://a.com/a.mp4',
        target: target,
        headers: <String, String>{'User-Agent': _browserUa},
        retries: 0,
      ),
      throwsA(
        isA<DownloadException>().having(
          (DownloadException e) => e.message,
          'message',
          contains('404'),
        ),
      ),
    );
    expect(adapter.calls, 1);
  });

  test('fetchBytes 同样走换头阶梯', () async {
    final _UaGateAdapter adapter = _UaGateAdapter();

    final List<int> bytes = await _downloader(adapter).fetchBytes(
      url: 'https://b.surrit.com/a.m3u8',
      headers: <String, String>{'User-Agent': _browserUa},
      retries: 0,
    );

    expect(bytes, isNotEmpty);
    expect(adapter.seen.last['User-Agent'], kNeutralUserAgent);
  });
}
