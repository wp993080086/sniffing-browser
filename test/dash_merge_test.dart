// DASH 音视频自动配对 + 合并。
//
// 场景：B 站这类站点走 DASH，画面和声音是两条独立的 `.m4s` 请求：
//   42977332133-1-30016.m4s   视频轨
//   42977332133-1-30280.m4s   音频轨
// 只下视频轨得到的是哑的 mp4。这里验证「点一条视频轨 → 自动补音频 → 合并」。
//
// 不联外网：本地 HttpServer 提供两个分片，转码引擎用假的（真实 ffmpeg 的
// 合并命令在 tools/verify_dash_merge.dart 里用真文件验证）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/core/platform/storage_paths.dart';
import 'package:sniffing_browser/features/downloader/data/download_queue.dart';
import 'package:sniffing_browser/features/downloader/domain/dash_pair.dart';
import 'package:sniffing_browser/features/downloader/domain/download_status.dart';
import 'package:sniffing_browser/features/downloader/domain/download_task.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_item.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_type.dart';
import 'package:sniffing_browser/features/transcoder/data/transcode_engine.dart';
import 'package:sniffing_browser/features/transcoder/data/transcode_queue.dart';
import 'package:sniffing_browser/features/transcoder/domain/transcode_job.dart';

/// 一段带 `ftyp` 头的二进制，够骗过「纯文本」判别。
Uint8List _fakeFmp4() {
  return Uint8List.fromList(<int>[
    0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, // size + 'ftyp'
    0x69, 0x73, 0x6F, 0x35, 0x00, 0x00, 0x02, 0x00,
    0x69, 0x73, 0x6F, 0x35, 0x69, 0x73, 0x6F, 0x36,
    0x6D, 0x70, 0x34, 0x31, 0x64, 0x61, 0x73, 0x68, // 'mp41dash'
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x08, 0x6D, 0x6F, 0x6F, 0x76, // 'moov'
  ]);
}

MediaItem _item({
  required String id,
  required String url,
  required MediaType type,
  required String fileName,
}) {
  return MediaItem(
    id: id,
    url: url,
    type: type,
    firstSeenAt: DateTime.now(),
    pageUrl: 'https://www.bilibili.com/video/BV1DKn461EDF/',
    fileName: fileName,
  );
}

void main() {
  group('DashPairer 配对规则', () {
    MediaItem video(String name) => _item(
          id: name,
          url: 'https://cdn.example.com/upgcxcode/$name?sign=abc',
          type: MediaType.video,
          fileName: '$name.mp4',
        );

    MediaItem audio(String name) => _item(
          id: name,
          url: 'https://cdn.example.com/upgcxcode/$name?sign=xyz',
          type: MediaType.audio,
          fileName: '$name.m4a',
        );

    test('B 站命名：同前缀的音视频轨配到一起', () {
      final MediaItem v = video('42977332133-1-30016.m4s');
      final MediaItem a = audio('42977332133-1-30280.m4s');

      expect(DashPairer.findAudioFor(v, <MediaItem>[v, a])?.id, a.id);
    });

    test('不同视频（不同 aid 前缀）不会错配', () {
      final MediaItem v1 = video('42977332133-1-30016.m4s');
      final MediaItem v2 = video('55512345678-1-30080.m4s');
      final MediaItem a2 = audio('55512345678-1-30280.m4s');

      expect(DashPairer.findAudioFor(v1, <MediaItem>[v1, v2, a2]), isNull);
      expect(DashPairer.findAudioFor(v2, <MediaItem>[v1, v2, a2])?.id, a2.id);
    });

    test('同一 key 有多条音频时取数字段最大的（音质最好）', () {
      final MediaItem v = video('42977332133-1-30016.m4s');
      final MediaItem low = audio('42977332133-1-30216.m4s');
      final MediaItem high = audio('42977332133-1-30280.m4s');

      expect(
        DashPairer.findAudioFor(v, <MediaItem>[v, low, high])?.id,
        high.id,
      );
    });

    test('文件名毫无关系时，整页唯一才兜底配对', () {
      final MediaItem v = video('video.m4s');
      final MediaItem a = audio('audio.m4s');
      expect(DashPairer.findAudioFor(v, <MediaItem>[v, a])?.id, a.id);

      // 页面上有第二条视频轨就不敢乱配了 —— 配错比不配更糟
      final MediaItem v2 = video('trailer.m4s');
      expect(DashPairer.findAudioFor(v, <MediaItem>[v, v2, a]), isNull);
    });

    test('普通 mp4 不参与配对（它自带音轨）', () {
      final MediaItem plain = _item(
        id: 'plain',
        url: 'https://cdn.example.com/movie.mp4',
        type: MediaType.video,
        fileName: 'movie.mp4',
      );
      final MediaItem a = audio('42977332133-1-30280.m4s');
      expect(DashPairer.findAudioFor(plain, <MediaItem>[plain, a]), isNull);
    });

    test('音频轨自身不会被当成视频轨去配对', () {
      final MediaItem v = video('42977332133-1-30016.m4s');
      final MediaItem a = audio('42977332133-1-30280.m4s');
      expect(DashPairer.findAudioFor(a, <MediaItem>[v, a]), isNull);
    });

    test('pairKey 剥掉末尾的数字段', () {
      expect(
        DashPairer.pairKey('https://x.com/a/42977332133-1-30016.m4s?e=1'),
        '42977332133-1',
      );
      // 整个名字就是数字时没有分隔符可剥，保持原样 —— 这种 key 配不上任何
      // 视频轨，最终会走「整页唯一」的兜底逻辑。
      expect(DashPairer.pairKey('https://x.com/a/30280.m4s'), '30280');
      expect(DashPairer.pairKey('https://x.com/a/video.m4s'), 'video');
    });
  });

  group('下载队列自动配对与合并', () {
    late HttpServer server;
    late Directory root;
    late _FakeEngine engine;
    late TranscodeQueue transcoder;

    setUpAll(() async {
      root = Directory('${Directory.systemTemp.path}/sniffing-dash-merge');
      if (await root.exists()) await root.delete(recursive: true);
      await StoragePaths.initWithRoot(root);
    });

    setUp(() async {
      engine = _FakeEngine();
      transcoder = TranscodeQueue(engine: engine);

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        final HttpResponse res = request.response;
        if (request.uri.path.contains('broken')) {
          // 模拟音频轨下载失败
          res.statusCode = HttpStatus.internalServerError;
          await res.close();
          return;
        }
        res.headers.contentType = ContentType('video', 'mp4');
        res.add(_fakeFmp4());
        await res.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      transcoder.dispose();
    });

    List<MediaItem> pool(String host) {
      final MediaItem v = _item(
        id: 'v',
        url: '$host/42977332133-1-30016.m4s',
        type: MediaType.video,
        fileName: '42977332133-1-30016.mp4',
      );
      final MediaItem a = _item(
        id: 'a',
        url: '$host/42977332133-1-30280.m4s',
        type: MediaType.audio,
        fileName: '42977332133-1-30280.m4a',
      );
      return <MediaItem>[v, a];
    }

    test('点视频轨会自动补一条音频轨，列表里只显示视频那条', () async {
      final String host = 'http://127.0.0.1:${server.port}';
      final List<MediaItem> items = pool(host);
      final DownloadQueue queue = DownloadQueue(
        transcoder: transcoder,
        poolSupplier: () => items,
      );

      final DownloadTask video = queue.enqueue(items.first, pool: items);

      expect(video.pairedTaskId, isNotNull, reason: '没有配上音频轨');
      expect(queue.tasks.length, 2, reason: '音频轨应当作为伴随任务入队');
      expect(queue.visibleTasks.length, 1, reason: '伴随任务不该出现在列表里');
      expect(video.isCompanion, isFalse);

      await _waitFor(() => video.mergedAudio != null, const Duration(seconds: 20));

      expect(video.status, DownloadStatus.completed);
      expect(video.mergedAudio, isTrue, reason: '合并没有发生');
      expect(video.container, 'mp4');

      // 合并产物覆盖了视频轨原路径，音频任务从列表里消失
      expect(queue.visibleTasks.length, 1);
      expect(queue.tasks.length, 1, reason: '音频伴随任务应当被清掉');

      queue.dispose();
    });

    test('合并调用传了两路输入，且成品覆盖源文件、音频被删掉', () async {
      final String host = 'http://127.0.0.1:${server.port}';
      final List<MediaItem> items = pool(host);
      final DownloadQueue queue = DownloadQueue(
        transcoder: transcoder,
        poolSupplier: () => items,
      );

      final DownloadTask video = queue.enqueue(items.first, pool: items);
      await _waitFor(() => video.mergedAudio != null, const Duration(seconds: 20));

      expect(engine.calls, hasLength(1));
      final _FakeEngineCall call = engine.calls.single;
      expect(call.kind, TranscodeKind.dashMerge);
      expect(call.inputPath, video.savedPath);
      expect(call.secondaryInputPath, isNotNull);
      expect(call.secondaryInputPath, endsWith('.m4a'));

      // 覆盖回原路径：下载任务持有的路径不变，导出还能直接用
      final File merged = File(video.savedPath!);
      expect(await merged.exists(), isTrue);
      expect(call.secondaryInputPath, isNot(merged.path));

      queue.dispose();
    });

    test('页面上只有视频轨时，标记为无音轨（不该给 MP3 入口）', () async {
      final String host = 'http://127.0.0.1:${server.port}';
      final MediaItem v = _item(
        id: 'solo',
        url: '$host/42977332133-3-30016.m4s',
        type: MediaType.video,
        fileName: '42977332133-3-30016.mp4',
      );
      final List<MediaItem> items = <MediaItem>[v];

      final DownloadQueue queue = DownloadQueue(
        transcoder: transcoder,
        poolSupplier: () => items,
      );

      final DownloadTask video = queue.enqueue(v, pool: items);
      expect(video.pairedTaskId, isNull, reason: '没有音频轨可配');

      await _waitFor(
          () => video.status.isFinished, const Duration(seconds: 20));

      expect(video.status, DownloadStatus.completed);
      expect(video.mergedAudio, isFalse,
          reason: '明确没有音轨，UI 才能把「转为 MP3」挡掉');
      expect(engine.calls, isEmpty, reason: '没有音频轨时不该触发合并');

      queue.dispose();
    });

    test('音频轨下不下来时，视频照常完成并标记无音轨', () async {
      final String host = 'http://127.0.0.1:${server.port}';
      final MediaItem v = _item(
        id: 'v2',
        url: '$host/42977332133-2-30016.m4s',
        type: MediaType.video,
        fileName: '42977332133-2-30016.mp4',
      );
      final MediaItem a = _item(
        id: 'a2',
        url: '$host/broken-42977332133-2-30280.m4s',
        type: MediaType.audio,
        fileName: '42977332133-2-30280.m4a',
      );
      final List<MediaItem> items = <MediaItem>[v, a];

      final DownloadQueue queue = DownloadQueue(
        transcoder: transcoder,
        poolSupplier: () => items,
      );

      final DownloadTask video = queue.enqueue(v, pool: items);
      await _waitFor(() => video.mergedAudio != null, const Duration(seconds: 30));

      expect(video.status, DownloadStatus.completed,
          reason: '音轨失败不该拖累视频: ${video.error}');
      expect(video.mergedAudio, isFalse);
      expect(engine.calls, isEmpty, reason: '没有音轨时不该尝试合并');

      queue.dispose();
    });

    test('用户自己单独下过音频轨时不抢过来合并', () async {
      final String host = 'http://127.0.0.1:${server.port}';
      final List<MediaItem> items = pool(host);
      final DownloadQueue queue = DownloadQueue(
        transcoder: transcoder,
        poolSupplier: () => items,
      );

      // 先手动下音频轨（用户想抽 MP3）
      final DownloadTask audioTask = queue.enqueue(items[1], pool: items);
      expect(audioTask.isCompanion, isFalse);

      // 再点视频轨：不应该把已有音频任务变成伴随任务
      final DownloadTask video = queue.enqueue(items.first, pool: items);
      expect(video.pairedTaskId, isNull);
      expect(audioTask.isCompanion, isFalse);

      queue.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
  });
}

class _FakeEngineCall {
  _FakeEngineCall(this.inputPath, this.secondaryInputPath, this.kind);
  final String inputPath;
  final String? secondaryInputPath;
  final TranscodeKind kind;
}

/// 假引擎：只记录调用并产出一个非空文件，不真的跑 ffmpeg。
class _FakeEngine extends TranscodeEngine {
  final List<_FakeEngineCall> calls = <_FakeEngineCall>[];

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
    calls.add(_FakeEngineCall(inputPath, secondaryInputPath, kind));
    onProgress(0.5);
    // 内容写成标识串，方便断言"覆盖回去的确实是合并产物"
    await File(outputPath).writeAsString('MERGED', flush: true);
    onProgress(1);
  }

  @override
  Future<void> cancel(String jobId) async {}
}

/// 轮询到条件成立。
Future<void> _waitFor(bool Function() predicate, Duration limit) async {
  final DateTime deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('等待超时');
}
