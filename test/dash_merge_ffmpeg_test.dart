// 真实 ffmpeg 的合并验证。
//
// 前面的 dash_merge_test.dart 用假引擎验证调度，这里验证**命令行本身**：
// 两路 fMP4 分片流拷贝出来的 mp4 是不是真的有画面 + 有声音、时长对不对。
//
// 素材用 lavfi 现场生成，形状和 B 站一致：视频轨只有视频流，音频轨只有音频流。
// 本机没有 ffmpeg 时自动跳过（和 SystemFfmpegEngine 的查找顺序一致）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/core/platform/storage_paths.dart';
import 'package:sniffing_browser/features/transcoder/data/system_ffmpeg_engine.dart';
import 'package:sniffing_browser/features/transcoder/data/transcode_engine.dart';
import 'package:sniffing_browser/features/transcoder/data/transcode_queue.dart';
import 'package:sniffing_browser/features/transcoder/domain/transcode_job.dart';

void main() {
  late String? ffmpeg;
  late String? ffprobe;
  late Directory work;

  setUpAll(() async {
    ffmpeg = await SystemFfmpegEngine.locateFfmpeg();
    ffprobe = await SystemFfmpegEngine.locateFfprobe();
  });

  setUp(() async {
    work = await Directory.systemTemp.createTemp('sniff-dash-ffmpeg');
  });

  tearDown(() async {
    if (await work.exists()) await work.delete(recursive: true);
  });

  /// 生成一段只有视频流的 fMP4，模拟 B 站的视频轨。
  Future<File> makeVideoTrack(int seconds) async {
    final File out = File('${work.path}/video.m4s');
    final ProcessResult r = await Process.run(ffmpeg!, <String>[
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=15:duration=$seconds',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-an',
      '-f', 'mp4', '-movflags', 'frag_keyframe+empty_moov',
      out.path,
    ]);
    expect(r.exitCode, 0, reason: '生成视频轨失败: ${r.stderr}');
    return out;
  }

  /// 生成一段只有音频流的 fMP4，模拟 B 站的音频轨。
  Future<File> makeAudioTrack(int seconds) async {
    final File out = File('${work.path}/audio.m4s');
    final ProcessResult r = await Process.run(ffmpeg!, <String>[
      '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=$seconds',
      '-c:a', 'aac', '-b:a', '128k', '-vn',
      '-f', 'mp4', '-movflags', 'frag_keyframe+empty_moov',
      out.path,
    ]);
    expect(r.exitCode, 0, reason: '生成音频轨失败: ${r.stderr}');
    return out;
  }

  /// 读出容器里的流类型与各自时长。
  Future<List<({String type, double seconds})>> probeStreams(String path) async {
    final ProcessResult r = await Process.run(ffprobe!, <String>[
      '-v', 'error',
      '-show_entries', 'stream=codec_type,duration',
      '-of', 'csv=p=0',
      path,
    ]);
    expect(r.exitCode, 0, reason: 'ffprobe 失败: ${r.stderr}');
    return (r.stdout as String)
        .trim()
        .split(RegExp(r'\r?\n'))
        .where((String line) => line.contains(','))
        .map((String line) {
      final List<String> parts = line.split(',');
      return (
        type: parts[0],
        seconds: double.tryParse(parts[1]) ?? 0,
      );
    }).toList();
  }

  test('两路分片合并后既有画面又有声音', () async {
    if (ffmpeg == null) {
      markTestSkipped('本机没有 ffmpeg');
      return;
    }

    final File video = await makeVideoTrack(4);
    final File audio = await makeAudioTrack(4);
    final File output = File('${work.path}/merged.mp4');

    final SystemFfmpegEngine engine = SystemFfmpegEngine();
    await engine.run(
      inputPath: video.path,
      outputPath: output.path,
      kind: TranscodeKind.dashMerge,
      secondaryInputPath: audio.path,
      onProgress: (double _) {},
      isCancelled: () => false,
    );

    expect(await output.exists(), isTrue);

    final List<({String type, double seconds})> streams =
        await probeStreams(output.path);
    expect(streams.map((({String type, double seconds}) s) => s.type),
        containsAll(<String>['video', 'audio']),
        reason: '合并产物缺少轨道: $streams');

    final double vSeconds = streams
        .firstWhere((({String type, double seconds}) s) => s.type == 'video')
        .seconds;
    expect(vSeconds, closeTo(4, 0.2), reason: '视频时长被改动过: $vSeconds');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('音轨比视频长时，不截断视频（这是去掉 -shortest 的原因）', () async {
    if (ffmpeg == null) {
      markTestSkipped('本机没有 ffmpeg');
      return;
    }

    final File video = await makeVideoTrack(4);
    // 音轨长 2 秒：如果加了 `-shortest`，视频会被砍成 2 秒。
    final File audio = await makeAudioTrack(6);
    final File output = File('${work.path}/merged-long.mp4');

    final SystemFfmpegEngine engine = SystemFfmpegEngine();
    await engine.run(
      inputPath: video.path,
      outputPath: output.path,
      kind: TranscodeKind.dashMerge,
      secondaryInputPath: audio.path,
      onProgress: (double _) {},
      isCancelled: () => false,
    );

    final List<({String type, double seconds})> streams =
        await probeStreams(output.path);
    final double vSeconds = streams
        .firstWhere((({String type, double seconds}) s) => s.type == 'video')
        .seconds;
    expect(vSeconds, closeTo(4, 0.2),
        reason: '视频被音频长度带跑了: $vSeconds');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('走队列时成品覆盖视频轨原路径，中间音频被清掉', () async {    if (ffmpeg == null) {
      markTestSkipped('本机没有 ffmpeg');
      return;
    }

    final Directory root = Directory('${work.path}/home');
    await StoragePaths.initWithRoot(root);

    final File video = await makeVideoTrack(3);
    final File audio = await makeAudioTrack(3);
    // 挪到下载目录，模拟视频轨已经下载完成
    final File downloaded = File('${StoragePaths.downloads.path}/track.mp4');
    await video.copy(downloaded.path);
    final File audioDownloaded = File('${StoragePaths.downloads.path}/track.m4a');
    await audio.copy(audioDownloaded.path);

    final TranscodeQueue queue =
        TranscodeQueue(engine: SystemFfmpegEngine());
    final File output = File('${StoragePaths.temp.path}/merge-out.mp4');

    final TranscodeJob job = queue.enqueue(
      sourcePath: downloaded.path,
      secondarySourcePath: audioDownloaded.path,
      kind: TranscodeKind.dashMerge,
      outputPath: output.path,
      replaceSource: true,
    );

    await _waitDone(job, const Duration(seconds: 60));
    expect(job.status, TranscodeStatus.completed, reason: '失败: ${job.error}');

    final List<({String type, double seconds})> streams =
        await probeStreams(downloaded.path);
    expect(streams.map((({String type, double seconds}) s) => s.type),
        containsAll(<String>['video', 'audio']),
        reason: '原路径上的文件没有被替换成合并产物');

    expect(await audioDownloaded.exists(), isFalse, reason: '中间音频没被清理');
    expect(await output.exists(), isFalse, reason: '临时成品没被清理');

    queue.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('合并后的 mp4 能抽出 MP3（这个文件确实带音轨）', () async {
    if (ffmpeg == null) {
      markTestSkipped('本机没有 ffmpeg');
      return;
    }

    final File video = await makeVideoTrack(4);
    final File audio = await makeAudioTrack(4);
    final File merged = File('${work.path}/merged.mp4');
    final SystemFfmpegEngine engine = SystemFfmpegEngine();

    await engine.run(
      inputPath: video.path,
      outputPath: merged.path,
      kind: TranscodeKind.dashMerge,
      secondaryInputPath: audio.path,
      onProgress: (double _) {},
      isCancelled: () => false,
    );

    final File mp3 = File('${work.path}/merged.mp3');
    await engine.run(
      inputPath: merged.path,
      outputPath: mp3.path,
      kind: TranscodeKind.audioToMp3,
      onProgress: (double _) {},
      isCancelled: () => false,
    );

    expect(await mp3.exists(), isTrue);
    expect(await mp3.length(), greaterThan(10 * 1024),
        reason: '抽出来的 mp3 太小，可能只有容器头');

    final List<int> head = await _readAt(mp3, 0, 3);
    final bool isMp3 = (head.length >= 3 &&
            head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) ||
        (head.length >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0);
    expect(isMp3, isTrue, reason: '输出不是 mp3 容器');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('纯视频 mp4 抽 MP3 会给出中文结论，而不是 ffmpeg 原文', () async {
    if (ffmpeg == null) {
      markTestSkipped('本机没有 ffmpeg');
      return;
    }

    final File video = await makeVideoTrack(2);
    final SystemFfmpegEngine engine = SystemFfmpegEngine();

    await expectLater(
      engine.run(
        inputPath: video.path,
        outputPath: '${work.path}/silent.mp3',
        kind: TranscodeKind.audioToMp3,
        onProgress: (double _) {},
        isCancelled: () => false,
      ),
      throwsA(
        isA<TranscodeUnsupportedSource>().having(
          (TranscodeUnsupportedSource e) => e.toString(),
          'message',
          contains('没有音轨'),
        ),
      ),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}

Future<List<int>> _readAt(File file, int offset, int length) async {
  final RandomAccessFile raf = await file.open();
  try {
    await raf.setPosition(offset);
    return await raf.read(length);
  } finally {
    await raf.close();
  }
}

Future<void> _waitDone(TranscodeJob job, Duration limit) async {
  final DateTime deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    if (job.status.isFinished) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('等待转换完成超时');
}
