// 转码链路的端到端验证：真的调用 ffmpeg 进程，产出真实文件。
//
// 默认跳过（要下载测试素材、要本机有 ffmpeg），需要时显式开启：
//   RUN_E2E=1 flutter test test/transcode_e2e_test.dart
//
// 为什么不用 mock：这条链路的全部风险都在「命令拼错、参数不兼容、
// 进度解析失败」这类只有真跑才会暴露的问题上，mock 掉就失去了意义。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/features/downloader/data/file_downloader.dart';
import 'package:sniffing_browser/features/transcoder/data/system_ffmpeg_engine.dart';
import 'package:sniffing_browser/features/transcoder/domain/transcode_job.dart';

const String _sampleTs =
    'https://test-streams.mux.dev/x36xhzz/url_2/url_526/193039199_mp4_h264_aac_ld_7.ts';

final bool _enabled = Platform.environment['RUN_E2E'] == '1';

void main() {
  group('FFmpeg 转码', () {
    late Directory work;
    late SystemFfmpegEngine engine;
    late File source;

    setUpAll(() async {
      work = Directory('${Directory.systemTemp.path}/sniffing-transcode');
      if (await work.exists()) await work.delete(recursive: true);
      await work.create(recursive: true);

      engine = SystemFfmpegEngine();
      source = File('${work.path}/sample.ts');
      if (!await source.exists()) {
        await FileDownloader().download(url: _sampleTs, target: source);
      }
    });

    test('能定位到 ffmpeg 可执行文件', () async {
      final String? ffmpeg = await SystemFfmpegEngine.locateFfmpeg();
      expect(ffmpeg, isNotNull, reason: '没找到 ffmpeg，转码无法工作');
      expect(await File(ffmpeg!).exists(), isTrue);

      final String? probe = await SystemFfmpegEngine.locateFfprobe();
      // ffprobe 只影响进度显示，缺失不算致命
      if (probe != null) {
        expect(await File(probe).exists(), isTrue);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('isAvailable 在桌面端为真', () async {
      expect(await engine.isAvailable(), isTrue);
    });

    test('TS 转 MP4：无损转封装，输出是合法 mp4', () async {
      final File output = File('${work.path}/out.mp4');
      if (await output.exists()) await output.delete();

      final List<double> progress = <double>[];
      await engine.run(
        inputPath: source.path,
        outputPath: output.path,
        kind: TranscodeKind.tsToMp4,
        onProgress: progress.add,
        isCancelled: () => false,
      );

      expect(await output.exists(), isTrue);
      expect(await output.length(), greaterThan(100 * 1024));

      // mp4 的前几个 box 里必须有 ftyp
      final List<int> head = await _readAt(output, 0, 32);
      expect(_hasAscii(head, 'ftyp'), isTrue, reason: '输出不是 mp4 容器');

      // 无损转封装不该改变时长，只换容器
      final Duration? srcDuration = await _duration(engine, source.path);
      final Duration? outDuration = await _duration(engine, output.path);
      if (srcDuration != null && outDuration != null) {
        final int diff = (srcDuration.inMilliseconds - outDuration.inMilliseconds).abs();
        expect(diff, lessThan(1500),
            reason: '时长差异 ${diff}ms，转封装不该改变时长');
      }

      expect(progress, isNotEmpty, reason: '没有收到进度回调');
      expect(progress.last, 1.0);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('音频转 MP3：输出是合法 mp3', () async {
      final File output = File('${work.path}/out.mp3');
      if (await output.exists()) await output.delete();

      await engine.run(
        inputPath: source.path,
        outputPath: output.path,
        kind: TranscodeKind.audioToMp3,
        onProgress: (double _) {},
        isCancelled: () => false,
      );

      expect(await output.exists(), isTrue);
      expect(await output.length(), greaterThan(20 * 1024));

      final List<int> head = await _readAt(output, 0, 3);
      // ID3 标签或帧同步字
      final bool isId3 = head.length >= 3 &&
          head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33;
      final bool isFrame = head.length >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0;
      expect(isId3 || isFrame, isTrue,
          reason: '输出不是 mp3，头字节 ${head.map((int b) => b.toRadixString(16)).join(' ')}');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('取消能中断进程并清掉半成品', () async {
      // 10 秒的 TS 转封装只要几十毫秒，根本来不及取消。
      // 现场生成一段 3 分钟音频，mp3 重编码要跑一两秒，才有取消的窗口。
      final File longSource = File('${work.path}/long.m4a');
      if (!await longSource.exists()) {
        final String? ffmpeg = await SystemFfmpegEngine.locateFfmpeg();
        expect(ffmpeg, isNotNull);
        final ProcessResult gen = await Process.run(ffmpeg!, <String>[
          '-y', '-hide_banner',
          '-f', 'lavfi', '-i', 'sine=frequency=440:duration=180',
          '-c:a', 'aac', '-b:a', '128k',
          longSource.path,
        ]);
        expect(gen.exitCode, 0, reason: '生成测试音频失败: ${gen.stderr}');
      }

      final File output = File('${work.path}/cancel.mp3');
      if (await output.exists()) await output.delete();

      final Future<void> running = engine.run(
        inputPath: longSource.path,
        outputPath: output.path,
        kind: TranscodeKind.audioToMp3,
        onProgress: (double _) {},
        isCancelled: () => false,
      );

      await Future<void>.delayed(const Duration(milliseconds: 250));
      await engine.cancel('test-job');

      await expectLater(running, throwsA(isA<TranscodeCancelled>()));
      expect(await output.exists(), isFalse, reason: '取消后应删除半成品');

      // 取消标记必须复位，否则下一次转换会立刻失败
      final File after = File('${work.path}/after-cancel.mp3');
      await engine.run(
        inputPath: source.path,
        outputPath: after.path,
        kind: TranscodeKind.audioToMp3,
        onProgress: (double _) {},
        isCancelled: () => false,
      );
      expect(await after.exists(), isTrue, reason: '取消后引擎应能继续工作');
    }, timeout: const Timeout(Duration(minutes: 3)));
  }, skip: _enabled ? false : '设置 RUN_E2E=1 才运行（需要网络和本机 ffmpeg）');
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

bool _hasAscii(List<int> bytes, String needle) {
  final List<int> target = needle.codeUnits;
  for (int i = 0; i + target.length <= bytes.length; i++) {
    bool match = true;
    for (int j = 0; j < target.length; j++) {
      if (bytes[i + j] != target[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

Future<Duration?> _duration(SystemFfmpegEngine engine, String path) async {
  final String? probe = await SystemFfmpegEngine.locateFfprobe();
  if (probe == null) return null;
  final ProcessResult result = await Process.run(probe, <String>[
    '-v', 'error',
    '-show_entries', 'format=duration',
    '-of', 'default=noprint_wrappers=1:nokey=1',
    path,
  ]);
  if (result.exitCode != 0) return null;
  final double? seconds = double.tryParse((result.stdout as String).trim());
  return seconds == null ? null : Duration(milliseconds: (seconds * 1000).round());
}
