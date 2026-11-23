import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/features/downloader/data/download_queue.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_type.dart';

void main() {
  group('HLS 文件名带来源页标题', () {
    test('HLS 拼上标题，扩展名仍在最后', () {
      expect(
        DownloadQueue.fileNameWithPageTitle(
          'playlist.m3u8',
          MediaType.hls,
          '某某视频 - 某某网',
        ),
        'playlist_某某视频 - 某某网.m3u8',
      );
    });

    test('标题为空或全空白时不改动', () {
      expect(
        DownloadQueue.fileNameWithPageTitle('playlist.m3u8', MediaType.hls, ''),
        'playlist.m3u8',
      );
      expect(
        DownloadQueue.fileNameWithPageTitle(
          'playlist.m3u8',
          MediaType.hls,
          '   ',
        ),
        'playlist.m3u8',
      );
      expect(
        DownloadQueue.fileNameWithPageTitle(
          'playlist.m3u8',
          MediaType.hls,
          null,
        ),
        'playlist.m3u8',
      );
    });

    test('标题里的非法字符被清洗，不会产出坏路径', () {
      expect(
        DownloadQueue.fileNameWithPageTitle(
          'index.m3u8',
          MediaType.hls,
          'a/b:c*d?e"f',
        ),
        'index_a_b_c_d_e_f.m3u8',
      );
    });

    test('超长标题截断，但保留 m3u8 扩展名', () {
      final String result = DownloadQueue.fileNameWithPageTitle(
        'playlist.m3u8',
        MediaType.hls,
        '标' * 200,
      );
      expect(result.endsWith('.m3u8'), isTrue);
      expect(result.length, 120);
    });

    test('普通媒体类型不加标题', () {
      for (final MediaType type in <MediaType>[
        MediaType.video,
        MediaType.audio,
        MediaType.image,
        MediaType.other,
      ]) {
        expect(
          DownloadQueue.fileNameWithPageTitle('clip.mp4', type, '某某视频'),
          'clip.mp4',
        );
      }
    });

    test('DASH 清单同样带来源页标题', () {
      expect(
        DownloadQueue.fileNameWithPageTitle(
          'manifest.mpd',
          MediaType.dash,
          '某某视频',
        ),
        'manifest_某某视频.mpd',
      );
    });
  });
}
