// DASH/MPD 点播下载的解析与落盘验证。
//
// 重点不是 RFC 全覆盖，而是三个最容易出错的地方：
// 1. BaseURL / SegmentTemplate 的继承与 `$Number$` 补齐；
// 2. SegmentTimeline 的 r 重复展开与 `$Time$`；
// 3. init + 分片拼出来的文件真的写到了目标路径，音轨单独成文件。
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/core/platform/storage_paths.dart';
import 'package:sniffing_browser/features/downloader/data/dash/dash_downloader.dart';
import 'package:sniffing_browser/features/downloader/data/dash/mpd_models.dart';
import 'package:sniffing_browser/features/downloader/data/dash/mpd_parser.dart';
import 'package:sniffing_browser/features/downloader/data/download_queue.dart';
import 'package:sniffing_browser/features/downloader/data/file_downloader.dart';
import 'package:sniffing_browser/features/downloader/domain/download_status.dart';
import 'package:sniffing_browser/features/downloader/domain/download_task.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_item.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_type.dart';
import 'package:sniffing_browser/features/transcoder/data/transcode_engine.dart';
import 'package:sniffing_browser/features/transcoder/data/transcode_queue.dart';
import 'package:sniffing_browser/features/transcoder/domain/transcode_job.dart';

const String _manifest = '''
<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static"
     mediaPresentationDuration="PT8S" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011">
  <BaseURL>https://cdn.example.com/v1/</BaseURL>
  <Period duration="PT8S">
    <AdaptationSet mimeType="video/mp4" contentType="video">
      <SegmentTemplate timescale="1" duration="4" startNumber="1"
        initialization="\$RepresentationID\$/init.mp4"
        media="\$RepresentationID\$/\$Number%03d\$.m4s" />
      <Representation id="720p" bandwidth="2000000" width="1280" height="720" />
      <Representation id="360p" bandwidth="500000" width="640" height="360" />
    </AdaptationSet>
    <AdaptationSet mimeType="audio/mp4" contentType="audio">
      <SegmentTemplate timescale="1" duration="4" startNumber="1"
        initialization="audio/init.mp4" media="audio/\$Number\$.m4s" />
      <Representation id="a1" bandwidth="128000" />
    </AdaptationSet>
  </Period>
</MPD>
''';

class _FakeDownloader extends FileDownloader {
  _FakeDownloader(this.texts, this.bytes);

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

class _RecordingEngine extends TranscodeEngine {
  final List<TranscodeKind> kinds = <TranscodeKind>[];

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> run({
    required String inputPath,
    required String outputPath,
    required TranscodeKind kind,
    required void Function(double progress) onProgress,
    required void Function() isCancelled,
    String? secondaryInputPath,
  }) async {
    kinds.add(kind);
    await File(outputPath).writeAsString('MERGED', flush: true);
    onProgress(1);
  }

  @override
  Future<void> cancel(String jobId) async {}
}

void main() {
  const String manifestUrl = 'https://cdn.example.com/m.mpd';
  final Uri base = Uri.parse(manifestUrl);
  final MpdParser parser = const MpdParser();

  group('MPD 解析', () {
    test('选最高码率视频 + 音轨，模板按 BaseURL 展开并补零', () {
      final MpdManifest manifest = parser.parse(_manifest, baseUri: base);
      expect(manifest.mediaPresentationDuration, const Duration(seconds: 8));

      final MpdSelectedTracks tracks = parser.selectTracks(manifest);
      expect(tracks.video, isNotNull);
      expect(tracks.video!.id, '720p');
      expect(tracks.audio, isNotNull);
      expect(tracks.audio!.id, 'a1');

      expect(tracks.video!.bandwidth, 2000000);
      expect(tracks.video!.label, contains('720p'));
      expect(tracks.audio!.codecs, isNull);
    });

    test(r'SegmentTimeline 的 r 重复展开成 $Time$ 地址', () {
      const String mpd = '''
      <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" mediaPresentationDuration="PT10S">
        <BaseURL>https://x.test/</BaseURL>
        <Period>
          <AdaptationSet mimeType="video/mp4">
            <SegmentTemplate timescale="1000" initialization="init.mp4"
              media="seg-\$Time\$.m4s">
              <SegmentTimeline>
                <S t="0" d="4000" r="1" />
                <S d="2000" />
              </SegmentTimeline>
            </SegmentTemplate>
            <Representation id="v" bandwidth="1000" />
          </AdaptationSet>
        </Period>
      </MPD>
      ''';
      final MpdSelectedTracks tracks =
          parser.selectTracks(parser.parse(mpd, baseUri: base));
      expect(tracks.video, isNotNull);
      expect(tracks.video!.segment.template!.timeline.length, 2);
      expect(tracks.video!.segment.template!.timeline.first.r, 1);
    });

    test('DRM 流直接拒绝，不拼出播放不了的坏文件', () {
      const String mpd = '''
      <MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
        <Period><AdaptationSet mimeType="video/mp4">
          <ContentProtection schemeIdUri="urn:uuid:edef8ba9" />
          <Representation id="v" bandwidth="1" />
        </AdaptationSet></Period>
      </MPD>
      ''';
      expect(
        () => parser.selectTracks(parser.parse(mpd, baseUri: base)),
        throwsA(
          isA<MpdParseException>().having(
            (MpdParseException e) => e.message,
            'message',
            contains('DRM'),
          ),
        ),
      );
    });

    test('ISO 时长与纯秒数都能解析', () {
      expect(
        MpdParser.parseDuration('PT1H2M3.5S'),
        const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 500),
      );
      expect(MpdParser.parseDuration('12.5'), const Duration(milliseconds: 12500));
      expect(MpdParser.parseDuration('nonsense'), isNull);
    });
  });

  group('DASH 下载落盘', () {
    late Directory root;

    setUp(() async {
      root = Directory(
        '${Directory.systemTemp.path}/sniffing-dash-${DateTime.now().microsecondsSinceEpoch}',
      );
      await StoragePaths.initWithRoot(root);
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('init + 音视频分片分别拼成两个文件', () async {
      final Map<String, String> texts = <String, String>{
        manifestUrl: _manifest,
      };
      final Map<String, List<int>> served = <String, List<int>>{};
      for (final String name in <String>[
        'https://cdn.example.com/v1/720p/init.mp4',
        'https://cdn.example.com/v1/720p/001.m4s',
        'https://cdn.example.com/v1/720p/002.m4s',
        'https://cdn.example.com/v1/audio/init.mp4',
        'https://cdn.example.com/v1/audio/1.m4s',
        'https://cdn.example.com/v1/audio/2.m4s',
      ]) {
        served[name] = utf8.encode('[$name]');
      }

      final DashDownloader downloader = DashDownloader(
        downloader: _FakeDownloader(texts, served),
        segmentConcurrency: () => 3,
      );
      final Directory workDir = StoragePaths.tempDirFor('dash-test-1');
      final File videoOut = File('${StoragePaths.temp.path}/dash-test-1.out');
      final File audioOut = File('${StoragePaths.temp.path}/dash-test-1.audio.out');

      final DashDownloadResult result = await downloader.download(
        manifestUrl: manifestUrl,
        workDir: workDir,
        output: videoOut,
        audioOutput: audioOut,
      );

      final String video = await videoOut.readAsString();
      final String audio = await audioOut.readAsString();
      expect(
        video,
        '[https://cdn.example.com/v1/720p/init.mp4]'
        '[https://cdn.example.com/v1/720p/001.m4s]'
        '[https://cdn.example.com/v1/720p/002.m4s]',
      );
      expect(
        audio,
        '[https://cdn.example.com/v1/audio/init.mp4]'
        '[https://cdn.example.com/v1/audio/1.m4s]'
        '[https://cdn.example.com/v1/audio/2.m4s]',
      );
      expect(result.container, 'mp4');
      expect(result.needsMerge, isTrue);
      expect(result.needsRemux, isFalse);
      expect(await workDir.exists(), isFalse);
    });

    test('队列入队 MPD 后完成下载并自动排期音视频合并', () async {
      final Map<String, List<int>> served = <String, List<int>>{};
      for (final String name in <String>[
        'https://cdn.example.com/v1/720p/init.mp4',
        'https://cdn.example.com/v1/720p/001.m4s',
        'https://cdn.example.com/v1/720p/002.m4s',
        'https://cdn.example.com/v1/audio/init.mp4',
        'https://cdn.example.com/v1/audio/1.m4s',
        'https://cdn.example.com/v1/audio/2.m4s',
      ]) {
        served[name] = utf8.encode('[$name]');
      }
      final _FakeDownloader fake = _FakeDownloader(
        <String, String>{manifestUrl: _manifest},
        served,
      );
      final _RecordingEngine engine = _RecordingEngine();
      final TranscodeQueue transcodeQueue = TranscodeQueue(
        engine: engine,
        autoExportToLibrary: false,
      );
      final DownloadQueue queue = DownloadQueue(
        downloader: fake,
        dashDownloader: DashDownloader(downloader: fake),
        transcoder: transcodeQueue,
      );

      final DownloadTask task = queue.enqueue(
        MediaItem(
          id: 'mpd-1',
          url: manifestUrl,
          type: MediaType.dash,
          firstSeenAt: DateTime.now(),
          fileName: 'manifest.mpd',
        ),
        pageTitle: '测试视频',
      );

      final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
      while (task.status != DownloadStatus.completed &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(task.status, DownloadStatus.completed);
      expect(task.fileName, 'manifest_测试视频.mpd');
      expect(File(task.savedPath!).existsSync(), isTrue);

      while (engine.kinds.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(engine.kinds, contains(TranscodeKind.dashMerge));
      queue.dispose();
      transcodeQueue.dispose();
    });

    test('SegmentBase 单文件封装给出明确的不支持原因', () async {
      const String mpd = '''
      <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" mediaPresentationDuration="PT8S">
        <Period><AdaptationSet mimeType="video/mp4">
          <SegmentBase indexRange="0-100"><Initialization range="0-50" /></SegmentBase>
          <Representation id="v" bandwidth="1" />
        </AdaptationSet></Period>
      </MPD>
      ''';
      final DashDownloader downloader = DashDownloader(
        downloader: _FakeDownloader(
          <String, String>{manifestUrl: mpd},
          <String, List<int>>{},
        ),
      );
      expect(
        () => downloader.download(
          manifestUrl: manifestUrl,
          workDir: StoragePaths.tempDirFor('dash-test-2'),
          output: File('${StoragePaths.temp.path}/dash-test-2.out'),
        ),
        throwsA(
          isA<UnsupportedError>().having(
            (UnsupportedError e) => e.toString(),
            'message',
            contains('SegmentBase'),
          ),
        ),
      );
    });
  });
}
