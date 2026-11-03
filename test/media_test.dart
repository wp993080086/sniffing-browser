import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/features/downloader/data/hls/m3u8_models.dart';
import 'package:sniffing_browser/features/downloader/data/hls/m3u8_parser.dart';
import 'package:sniffing_browser/features/sniffer/data/sniffer_service.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_classifier.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_type.dart';

void main() {
  group('MediaClassifier', () {
    test('按扩展名识别类型', () {
      expect(MediaClassifier.classifyUrl('https://a.com/x.jpg'), MediaType.image);
      expect(MediaClassifier.classifyUrl('https://a.com/x.mp3'), MediaType.audio);
      expect(MediaClassifier.classifyUrl('https://a.com/x.m3u8'), MediaType.hls);
      expect(MediaClassifier.classifyUrl('https://a.com/x.mpd'), MediaType.dash);
      expect(MediaClassifier.classifyUrl('https://a.com/x.mp4'), MediaType.video);
    });

    test('query 参数不干扰扩展名判断', () {
      expect(
        MediaClassifier.classifyUrl('https://a.com/x.m3u8?token=abc&t=1'),
        MediaType.hls,
      );
    });

    test('blob 与统计域名被忽略', () {
      expect(MediaClassifier.isIgnorable('blob:https://a.com/123'), isTrue);
      expect(
        MediaClassifier.isIgnorable('https://www.google-analytics.com/collect'),
        isTrue,
      );
    });

    test('无扩展名且无 MIME 时归为 other', () {
      expect(
        MediaClassifier.classifyUrl('https://a.com/api/list'),
        MediaType.other,
      );
    });
  });

  group('SnifferService', () {
    test('新捕获的排在首位，重复 URL 不重复入列', () {
      final SnifferService sniffer = SnifferService();
      sniffer.capture(url: 'https://a.com/1.jpg');
      sniffer.capture(url: 'https://a.com/2.png');
      // 同一个地址再报一次（CDP 会为重定向、缓存命中重复推送）
      sniffer.capture(url: 'https://a.com/1.jpg');

      expect(sniffer.count, 2);
      expect(sniffer.items.first.url, 'https://a.com/2.png');
      expect(sniffer.items.last.url, 'https://a.com/1.jpg');

      sniffer.dispose();
    });

    test('非媒体地址不进入列表', () {
      final SnifferService sniffer = SnifferService();
      expect(sniffer.capture(url: 'https://a.com/app.js'), isNull);
      expect(sniffer.capture(url: 'https://a.com/style.css'), isNull);
      expect(
        sniffer.capture(url: 'https://www.google-analytics.com/collect'),
        isNull,
      );
      expect(sniffer.count, 0);

      sniffer.dispose();
    });

    test('清空后列表长度为 0', () {
      final SnifferService sniffer = SnifferService();
      sniffer.capture(url: 'https://a.com/1.jpg');
      expect(sniffer.count, 1);
      sniffer.clear();
      expect(sniffer.count, 0);

      sniffer.dispose();
    });
  });

  group('M3u8Parser', () {
    const M3u8Parser parser = M3u8Parser();

    test('相对路径基于 playlist 地址解析', () {
      final M3u8Playlist playlist = parser.parse(
        '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nseg1.ts\n'
        '#EXTINF:10,\nseg2.ts\n#EXT-X-ENDLIST',
        Uri.parse('https://cdn.a.com/hls/720p/index.m3u8'),
      );

      expect(playlist.segments.length, 2);
      expect(
        playlist.segments.first.uri.toString(),
        'https://cdn.a.com/hls/720p/seg1.ts',
      );
      expect(playlist.isFmp4, isFalse);
      expect(playlist.containerExtension, 'ts');
    });

    test('master playlist 选出最高分辨率', () {
      final M3u8Playlist master = parser.parse(
        '#EXTM3U\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\nlow/index.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080\nhigh/index.m3u8\n',
        Uri.parse('https://cdn.a.com/master.m3u8'),
      );

      expect(master.isMaster, isTrue);
      final M3u8Variant best = parser.pickBestVariant(master);
      expect(best.resolution, '1920x1080');
      expect(best.uri.toString(), 'https://cdn.a.com/high/index.m3u8');
    });

    test('EXT-X-MAP 被识别为 fMP4 初始化段', () {
      final M3u8Playlist playlist = parser.parse(
        '#EXTM3U\n'
        '#EXT-X-MAP:URI="init.mp4"\n'
        '#EXTINF:4,\nseg1.m4s\n'
        '#EXT-X-ENDLIST',
        Uri.parse('https://cdn.a.com/v/index.m3u8'),
      );

      expect(playlist.isFmp4, isTrue);
      expect(playlist.initSegmentUrl, 'https://cdn.a.com/v/init.mp4');
      expect(playlist.containerExtension, 'mp4');
    });

    test('AES-128 的 KEY 作用于其后所有分片', () {
      final M3u8Playlist playlist = parser.parse(
        '#EXTM3U\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x0123456789ABCDEF0123456789ABCDEF\n'
        '#EXTINF:4,\nseg1.ts\n'
        '#EXTINF:4,\nseg2.ts\n'
        '#EXT-X-ENDLIST',
        Uri.parse('https://cdn.a.com/v/index.m3u8'),
      );

      expect(playlist.segments.length, 2);
      for (final M3u8Segment segment in playlist.segments) {
        expect(segment.key, isNotNull);
        expect(segment.key!.isAes128, isTrue);
        expect(segment.key!.iv!.length, 16);
        expect(segment.key!.uri.toString(), 'https://cdn.a.com/v/key.bin');
      }
    });

    test('媒体序列号从 EXT-X-MEDIA-SEQUENCE 起算', () {
      final M3u8Playlist playlist = parser.parse(
        '#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:100\n#EXTINF:4,\nseg1.ts\n#EXT-X-ENDLIST',
        Uri.parse('https://cdn.a.com/v/index.m3u8'),
      );
      expect(playlist.segments.first.sequence, 100);
    });
  });
}
