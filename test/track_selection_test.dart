import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/features/downloader/data/dash/mpd_models.dart';
import 'package:sniffingbrowser/features/downloader/data/dash/mpd_parser.dart';
import 'package:sniffingbrowser/features/downloader/data/file_downloader.dart';
import 'package:sniffingbrowser/features/downloader/data/hls/hls_downloader.dart';
import 'package:sniffingbrowser/features/downloader/data/hls/m3u8_models.dart';

/// 下载前选轨：把「能列出什么」和「选了是不是真的按它下」钉住。
const String _mpd = '''
<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static"
     mediaPresentationDuration="PT8S">
  <BaseURL>https://cdn.example.com/</BaseURL>
  <Period duration="PT8S">
    <AdaptationSet mimeType="video/mp4" contentType="video">
      <SegmentTemplate timescale="1" duration="4" startNumber="1"
        initialization="v/init.mp4" media="v/\$Number\$.m4s" />
      <Representation id="720p" bandwidth="2000000" width="1280" height="720" />
      <Representation id="360p" bandwidth="500000" width="640" height="360" />
    </AdaptationSet>
    <AdaptationSet mimeType="audio/mp4" contentType="audio" lang="en">
      <SegmentTemplate timescale="1" duration="4" startNumber="1"
        initialization="a/init.mp4" media="a/\$Number\$.m4s" />
      <Representation id="en" bandwidth="128000" />
    </AdaptationSet>
    <AdaptationSet mimeType="audio/mp4" contentType="audio" lang="zh">
      <SegmentTemplate timescale="1" duration="4" startNumber="1"
        initialization="z/init.mp4" media="z/\$Number\$.m4s" />
      <Representation id="zh" bandwidth="96000" />
    </AdaptationSet>
  </Period>
</MPD>
''';

class _FakeDownloader extends FileDownloader {
  _FakeDownloader({
    this.texts = const <String, String>{},
    this.bytes = const <String, List<int>>{},
  });

  final Map<String, String> texts;
  final Map<String, List<int>> bytes;

  @override
  Future<String> fetchString({
    required String url,
    Map<String, String> headers = const <String, String>{},
    CancelToken? cancelToken,
  }) async {
    final String? value = texts[url];
    if (value == null) throw StateError('没有这个清单: $url');
    return value;
  }

  @override
  Future<List<int>> fetchBytes({
    required String url,
    Map<String, String> headers = const <String, String>{},
    CancelToken? cancelToken,
    int retries = 2,
  }) async {
    final List<int>? value = bytes[url];
    if (value == null) throw StateError('没有这个分片: $url');
    return value;
  }
}

void main() {
  group('DASH 轨道枚举与选择', () {
    const MpdParser parser = MpdParser();
    final MpdManifest manifest = parser.parse(
      _mpd,
      baseUri: Uri.parse('https://cdn.example.com/manifest.mpd'),
    );

    test('列全所有音视频轨，带语言标记', () {
      final List<MpdSelectedTrack> tracks = parser.listTracks(manifest);

      expect(tracks.length, 4);
      final List<MpdSelectedTrack> audio = tracks
          .where((MpdSelectedTrack t) => t.kind == DashTrackKind.audio)
          .toList();
      expect(
        audio.map((MpdSelectedTrack t) => t.lang),
        containsAll(<String?>['en', 'zh']),
      );
      // 展示名要能让用户区分两条外语/中文音轨，只有码率不够。
      expect(
        audio.map((MpdSelectedTrack t) => t.label).join('|'),
        contains('zh'),
      );
    });

    test('不指定就挑码率最高的', () {
      final MpdSelectedTracks selected = parser.selectTracks(manifest);
      expect(selected.video?.id, '720p');
      expect(selected.audio?.id, 'en');
    });

    test('指定视频轨与音轨后按指定来', () {
      final MpdSelectedTracks selected = parser.selectTracks(
        manifest,
        videoId: '360p',
        audioId: 'zh',
      );
      expect(selected.video?.id, '360p');
      expect(selected.audio?.id, 'zh');
    });

    test('指定的 id 不存在时退回自动挑选，不让整单失败', () {
      final MpdSelectedTracks selected = parser.selectTracks(
        manifest,
        videoId: '不存在的轨',
      );
      expect(selected.video?.id, '720p');
    });
  });

  group('HLS 清晰度', () {
    const String master = '''#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=640x360
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
high/index.m3u8
''';
    const String child = '''#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4.0,
seg0.ts
#EXT-X-ENDLIST
''';

    _FakeDownloader fake() => _FakeDownloader(
      texts: <String, String>{
        'https://cdn.example.com/master.m3u8': master,
        'https://cdn.example.com/low/index.m3u8': child,
        'https://cdn.example.com/high/index.m3u8': child,
      },
      bytes: <String, List<int>>{
        'https://cdn.example.com/low/seg0.ts': <int>[1, 2, 3],
        'https://cdn.example.com/high/seg0.ts': <int>[4, 5, 6],
      },
    );

    test('能列出 master 里的全部清晰度', () async {
      final HlsDownloader downloader = HlsDownloader(downloader: fake());
      final ({List<M3u8Variant> variants, List<M3u8Media> subtitles}) probe =
          await downloader.probe(
            playlistUrl: 'https://cdn.example.com/master.m3u8',
          );

      final List<M3u8Variant> variants = probe.variants;
      expect(variants.length, 2);
      expect(
        variants.map((M3u8Variant v) => v.resolution),
        containsAll(<String>['640x360', '1280x720']),
      );
    });

    test('不是 master playlist 时没有可选清晰度', () async {
      final HlsDownloader downloader = HlsDownloader(
        downloader: _FakeDownloader(
          texts: <String, String>{'https://cdn.example.com/plain.m3u8': child},
        ),
      );
      final ({List<M3u8Variant> variants, List<M3u8Media> subtitles}) probe =
          await downloader.probe(
            playlistUrl: 'https://cdn.example.com/plain.m3u8',
          );
      expect(probe.variants, isEmpty);
      expect(probe.subtitles, isEmpty);
    });

    test('按指定的变体下载，不是自动挑最高码率', () async {
      final Directory root = await Directory.systemTemp.createTemp('track-hls');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });

      final HlsDownloader downloader = HlsDownloader(downloader: fake());
      final HlsDownloadResult result = await downloader.download(
        playlistUrl: 'https://cdn.example.com/master.m3u8',
        workDir: Directory('${root.path}/work'),
        output: File('${root.path}/out.ts'),
        preferredVariantUri: 'https://cdn.example.com/low/index.m3u8',
      );

      expect(result.variantLabel, contains('360'));
      // 走低码率那条，分片就只应该是 low 目录里的。
      final List<int> written = await result.file.readAsBytes();
      expect(written, <int>[1, 2, 3]);
    });
  });

  group('HLS 字幕', () {
    const String master = '''#EXTM3U
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="中文",LANGUAGE="zh",URI="subs/zh.m3u8",DEFAULT=YES
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",URI="subs/en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,SUBTITLES="subs"
high/index.m3u8
''';
    const String subPlaylist = '''#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
0.vtt
#EXT-X-ENDLIST
''';

    test('字幕轨带语言标记，能当文件后缀', () async {
      final HlsDownloader downloader = HlsDownloader(
        downloader: _FakeDownloader(
          texts: <String, String>{'https://cdn.example.com/m.m3u8': master},
        ),
      );
      final ({List<M3u8Variant> variants, List<M3u8Media> subtitles}) probe =
          await downloader.probe(playlistUrl: 'https://cdn.example.com/m.m3u8');

      expect(probe.subtitles.length, 2);
      expect(probe.subtitles.first.label, contains('中文'));
      expect(probe.subtitles.first.fileTag, 'zh');
      expect(probe.subtitles.last.fileTag, 'en');
    });

    test('下载字幕拼成 vtt 文本', () async {
      final Directory root = await Directory.systemTemp.createTemp('track-sub');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });

      final HlsDownloader downloader = HlsDownloader(
        downloader: _FakeDownloader(
          texts: <String, String>{
            'https://cdn.example.com/subs/zh.m3u8': subPlaylist,
          },
          bytes: <String, List<int>>{
            'https://cdn.example.com/subs/0.vtt': utf8.encode(
              'WEBVTT\n\n00:00.000 --> 00:02.000\n你好\n',
            ),
          },
        ),
      );

      final File file = await downloader.downloadSubtitle(
        playlistUrl: 'https://cdn.example.com/subs/zh.m3u8',
        workDir: Directory('${root.path}/work'),
        output: File('${root.path}/zh.vtt'),
      );

      final String text = await file.readAsString();
      expect(text, contains('WEBVTT'));
      expect(text, contains('你好'));
    });
  });
}
