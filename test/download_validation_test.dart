// 「服务器返回网页冒充媒体」这条链路的验证。
//
// 触发场景（真实站点 sagigames.cn）：
//   站点把 404 兜底成首页，请求 /_nuxt/videos/banner.xxx.mp4
//   拿到 200 + text/html 的整页 HTML（47200 字节），扩展名还是 .mp4，
//   存下来就是"此文件无法播放/已损坏"。
//
// 这里不联外网：本地 HttpServer 复刻同样的响应，验证三处防线。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/features/downloader/data/file_downloader.dart';
import 'package:sniffing_browser/features/downloader/data/hls/hls_downloader.dart';
import 'package:sniffing_browser/features/downloader/data/media_validator.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_classifier.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_type.dart';

const String _fakePage = '<!doctype html><html><head><title>首页</title></head>'
    '<body><div id="app"></div></body></html>';

/// 一个最小的合法 mp4 头：`ftyp` box + 一堆二进制。足够骗过文本判别。
Uint8List _fakeMp4() {
  return Uint8List.fromList(<int>[
    0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, // size + 'ftyp'
    0x6D, 0x70, 0x34, 0x32, 0x00, 0x00, 0x00, 0x00, // 'mp42'
    0x6D, 0x70, 0x34, 0x32, 0x69, 0x73, 0x6F, 0x6D,
    0x00, 0x00, 0x00, 0x08, 0x6D, 0x6F, 0x6F, 0x76, // 'moov'
    0xFF, 0xFE, 0x01, 0x02, 0x03, 0x04,
  ]);
}

void main() {
  group('MediaValidator', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sniff-validate');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('整页 HTML 冒充 mp4 → 拒绝，并说明是网页', () async {
      final File file = File('${tmp.path}/banner.mp4');
      await file.writeAsString(_fakePage);

      final String? problem =
          await MediaValidator.validate(file, type: MediaType.video);

      expect(problem, isNotNull);
      expect(problem, contains('网页'));
      expect(problem, contains('404'));
    });

    test('Content-Type 声明 text/html 时直接拒绝', () async {
      final File file = File('${tmp.path}/banner2.mp4');
      await file.writeAsBytes(_fakeMp4());

      final String? problem = await MediaValidator.validate(
        file,
        type: MediaType.video,
        contentType: 'text/html; charset=utf-8',
      );

      expect(problem, isNotNull);
      expect(problem, contains('text/html'));
    });

    test('0 字节文件被拒绝', () async {
      final File file = File('${tmp.path}/empty.mp3');
      await file.create();

      final String? problem =
          await MediaValidator.validate(file, type: MediaType.audio);

      expect(problem, isNotNull);
      expect(problem, contains('空'));
    });

    test('JSON 错误响应被拒绝', () async {
      final File file = File('${tmp.path}/x.mp4');
      await file.writeAsString('{"code":403,"msg":"referer blocked"}');

      final String? problem =
          await MediaValidator.validate(file, type: MediaType.video);

      expect(problem, isNotNull);
      expect(problem, contains('JSON'));
    });

    test('真正的二进制媒体通过', () async {
      final File mp4 = File('${tmp.path}/ok.mp4');
      await mp4.writeAsBytes(_fakeMp4());
      expect(await MediaValidator.validate(mp4, type: MediaType.video), isNull);

      // PNG: \x89PNG\r\n\x1a\n
      final File png = File('${tmp.path}/ok.png');
      await png.writeAsBytes(<int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      ]);
      expect(await MediaValidator.validate(png, type: MediaType.image), isNull);
    });
  });

  group('MediaClassifier 的 MIME 否决', () {
    test('扩展名是 mp4 但 MIME 是 text/html → 不算媒体', () {
      expect(
        MediaClassifier.classifyUrl(
          'https://sagigames.cn/_nuxt/videos/banner.bf78c42.mp4',
          mimeType: 'text/html',
        ),
        MediaType.other,
      );
    });

    test('MIME 正常时仍按扩展名判定', () {
      expect(
        MediaClassifier.classifyUrl(
          'https://a.com/banner.mp4',
          mimeType: 'video/mp4',
        ),
        MediaType.video,
      );
      expect(
        MediaClassifier.classifyUrl(
          'https://a.com/index.m3u8',
          mimeType: 'application/vnd.apple.mpegurl',
        ),
        MediaType.hls,
      );
    });

    test('DASH 的 application/dash+xml 不会被 xml 规则误杀', () {
      expect(
        MediaClassifier.classifyUrl(
          'https://a.com/manifest.mpd',
          mimeType: 'application/dash+xml',
        ),
        MediaType.dash,
      );
    });
  });

  group('下载链路端到端', () {
    late HttpServer server;
    late Directory tmp;

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        final HttpResponse res = request.response;
        final String path = request.uri.path;
        if (path.endsWith('/fake.mp4')) {
          // 复刻站点的 404 兜底：200 + 整页 HTML
          res.headers.contentType = ContentType.html;
          res.write(_fakePage);
        } else if (path.endsWith('/real.mp4')) {
          res.headers.contentType = ContentType('video', 'mp4');
          res.add(_fakeMp4());
        } else if (path.endsWith('/page.m3u8')) {
          res.headers.contentType = ContentType.html;
          res.write(_fakePage);
        } else {
          res.statusCode = HttpStatus.notFound;
        }
        await res.close();
      });
    });

    tearDownAll(() async {
      await server.close(force: true);
    });

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sniff-dl-validate');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('网页冒充 mp4：抛错、不留文件、不留 .part', () async {
      final File target = File('${tmp.path}/banner.mp4');
      final FileDownloader downloader = FileDownloader();

      await expectLater(
        downloader.download(
          url: 'http://127.0.0.1:${server.port}/fake.mp4',
          target: target,
          expectType: MediaType.video,
        ),
        throwsA(
          isA<DownloadException>().having(
            (DownloadException e) => e.message,
            'message',
            contains('网页'),
          ),
        ),
      );

      expect(await target.exists(), isFalse, reason: '坏文件不该落盘');
      expect(await File('${target.path}.part').exists(), isFalse,
          reason: '临时文件也要清掉');
    });

    test('真正的 mp4 正常保存', () async {
      final File target = File('${tmp.path}/real.mp4');
      final File result = await FileDownloader().download(
        url: 'http://127.0.0.1:${server.port}/real.mp4',
        target: target,
        expectType: MediaType.video,
      );

      expect(await result.exists(), isTrue);
      expect(await result.length(), _fakeMp4().length);
    });

    test('m3u8 地址返回 HTML 时报「不是 m3u8」，而不是「没有分片」', () async {
      final Directory workDir = Directory('${tmp.path}/work');
      final File output = File('${tmp.path}/out.ts');

      await expectLater(
        HlsDownloader().download(
          playlistUrl: 'http://127.0.0.1:${server.port}/page.m3u8',
          workDir: workDir,
          output: output,
        ),
        throwsA(
          isA<DownloadException>().having(
            (DownloadException e) => e.message,
            'message',
            contains('不是 m3u8'),
          ),
        ),
      );
    });
  });
}
