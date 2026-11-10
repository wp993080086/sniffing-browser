import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/logging/app_log.dart';
import '../domain/transcode_job.dart';
import 'transcode_engine.dart';

/// 直接调用系统上的 ffmpeg 可执行文件。
///
/// 为什么桌面端走这条路而不是 `ffmpeg_kit_flutter`：桌面本来就能跑原生进程，
/// 引一个几十 MB 的预编译包反而更重，而且版本受制于包作者。用户机器上已有的
/// ffmpeg 或者随应用分发一个静态构建都更可控。
///
/// 移动端不能这么干（沙箱不允许执行任意二进制），那边仍然走 MethodChannel。
class SystemFfmpegEngine extends TranscodeEngine {
  SystemFfmpegEngine({this.ffmpegPath, this.ffprobePath});

  /// 显式指定路径，主要给测试用。为空时按 [locate] 的规则自动查找。
  final String? ffmpegPath;
  final String? ffprobePath;

  Process? _active;
  bool _cancelled = false;

  static String? _cachedFfmpeg;
  static String? _cachedFfprobe;

  /// 查找顺序：显式配置 → 应用同目录 → 用户级 devtools → 系统 PATH。
  ///
  /// 把「应用同目录」排在 PATH 前面，是为了让随应用分发的版本优先于
  /// 用户机器上某个版本不明的旧 ffmpeg。
  static Future<String?> locateFfmpeg() async {
    final String? cached = _cachedFfmpeg;
    if (cached != null) return cached;
    _cachedFfmpeg = await _locateBinary('ffmpeg');
    return _cachedFfmpeg;
  }

  static Future<String?> locateFfprobe() async {
    final String? cached = _cachedFfprobe;
    if (cached != null) return cached;
    _cachedFfprobe = await _locateBinary('ffprobe');
    return _cachedFfprobe;
  }

  static Future<String?> _locateBinary(String name) async {
    final String exe = Platform.isWindows ? '$name.exe' : name;

    // 1. 环境变量，方便调试时临时指向别的构建
    final String? override = Platform.environment['SNIFF_FFMPEG_DIR'];
    if (override != null && override.isNotEmpty) {
      final File candidate = File(p.join(override, exe));
      if (await candidate.exists()) return candidate.path;
    }

    // 2. 应用可执行文件同目录及其 bin/ 子目录
    final String exeDir = p.dirname(Platform.resolvedExecutable);
    for (final String relative in <String>[exe, p.join('ffmpeg', 'bin', exe), p.join('bin', exe)]) {
      final File candidate = File(p.join(exeDir, relative));
      if (await candidate.exists()) return candidate.path;
    }

    // 3. 用户级安装目录（本机开发时装在这里，不进系统 PATH）
    final String? home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      for (final String relative in <String>[
        p.join('.devtools', 'ffmpeg', 'bin', exe),
        p.join('.devtools', exe),
        p.join('.local', 'bin', exe),
      ]) {
        final File candidate = File(p.join(home, relative));
        if (await candidate.exists()) return candidate.path;
      }
    }

    // 4. 系统 PATH
    try {
      final ProcessResult result = Platform.isWindows
          ? await Process.run('where', <String>[exe])
          : await Process.run('which', <String>[exe]);
      if (result.exitCode == 0) {
        final String out = (result.stdout as String).trim();
        final String first = out.split(RegExp(r'\r?\n')).first.trim();
        if (first.isNotEmpty && await File(first).exists()) return first;
      }
    } catch (e) {
      logWarn('FFmpeg', 'PATH 查找失败: $e');
    }

    return null;
  }

  @override
  Future<bool> isAvailable() async {
    final String? ffmpeg = ffmpegPath ?? await locateFfmpeg();
    return ffmpeg != null && await File(ffmpeg).exists();
  }

  /// 探测媒体总时长，用于把 ffmpeg 输出的 `time=` 换算成百分比。
  /// 拿不到就返回 null，此时进度退化为「不确定」，UI 显示成无限循环。
  Future<Duration?> _probeDuration(String path) async {
    final String? probe = ffprobePath ?? await locateFfprobe();
    if (probe == null) return null;
    try {
      final ProcessResult result = await Process.run(probe, <String>[
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1',
        path,
      ]);
      if (result.exitCode != 0) return null;
      final double? seconds = double.tryParse((result.stdout as String).trim());
      if (seconds == null || seconds <= 0) return null;
      return Duration(milliseconds: (seconds * 1000).round());
    } catch (e) {
      logWarn('FFmpeg', 'ffprobe 失败: $e');
      return null;
    }
  }

  /// 音视频两路时长差太多时记一条警告。
  ///
  /// 不阻断合并 —— 差几秒的片子照样能看，用户要的是「有声音」而不是
  /// 「精确对齐」。但要留痕：合并后出现「结尾有声音没画面」时，
  /// 日志能直接指向原因，而不用去猜是不是合并本身坏了。
  Future<void> _warnIfDurationMismatch(String video, String audio) async {
    final Duration? v = await _probeDuration(video);
    final Duration? a = await _probeDuration(audio);
    if (v == null || a == null || v.inMilliseconds == 0) return;

    final int diffMs = (v.inMilliseconds - a.inMilliseconds).abs();
    final double ratio = diffMs / v.inMilliseconds;
    if (ratio <= 0.05) return;

    logWarn(
      'FFmpeg',
      '音视频时长相差 ${ratio * 100 ~/ 1}%（视频 ${v.inSeconds}s / 音频 ${a.inSeconds}s），'
      '合并后结尾可能有一段对不齐；音轨很可能是没下完整',
    );
  }

  @override
  Future<void> run({
    required String inputPath,
    required String outputPath,
    required TranscodeKind kind,
    required void Function(double progress) onProgress,
    required void Function() isCancelled,
    String? secondaryInputPath,
  }) async {
    final String? ffmpeg = ffmpegPath ?? await locateFfmpeg();
    if (ffmpeg == null) {
      throw UnsupportedError('没有找到 ffmpeg，请安装或设置 SNIFF_FFMPEG_DIR');
    }
    if (kind.needsSecondaryInput &&
        (secondaryInputPath == null || secondaryInputPath.isEmpty)) {
      throw ArgumentError('${kind.label}需要两路输入，第二路缺失');
    }

    _cancelled = false;
    final Duration? total = await _probeDuration(inputPath);

    if (kind == TranscodeKind.dashMerge && secondaryInputPath != null) {
      await _warnIfDurationMismatch(inputPath, secondaryInputPath);
    }

    try {
      await _execute(
        ffmpeg: ffmpeg,
        args: _argsFor(kind, inputPath, outputPath, secondaryInputPath),
        outputPath: outputPath,
        total: total,
        onProgress: onProgress,
      );
    } on _FfmpegFailure catch (e) {
      // 「要抽音轨但源里没有音轨」是最常见的一种失败，几乎都是纯视频轨
      // （B 站那种只有画面的 m4s）。ffmpeg 的原文是
      // `Stream map '0:a:0' matches no streams.`，对用户毫无意义，这里拦住。
      if (kind == TranscodeKind.audioToMp3 &&
          _looksLikeNoAudioStream('${e.message}\n${e.raw}')) {
        throw const TranscodeUnsupportedSource(
          '这个文件里没有音轨，无法提取 MP3（多半是纯视频轨或无声视频）',
        );
      }

      // TS 里的某些编码（老式 MPEG-2 音频、AC-3）装不进 MP4，`-c copy` 会失败。
      // 这时只重编音频、视频仍然直接复制，代价很小但能救回大部分片子。
      // （合并音视频不适用：它的音轨本来就是 AAC，失败是别的原因。）
      if (kind != TranscodeKind.tsToMp4) rethrow;
      logWarn('FFmpeg', '无损转封装失败，尝试只重编音频: ${e.message}');
      await _execute(
        ffmpeg: ffmpeg,
        args: <String>[
          '-y', '-hide_banner',
          '-i', inputPath,
          '-c:v', 'copy',
          '-c:a', 'aac', '-b:a', '192k',
          '-movflags', '+faststart',
          outputPath,
        ],
        outputPath: outputPath,
        total: total,
        onProgress: onProgress,
      );
    }

    // 有些站点的分片带少量损坏帧，ffmpeg 仍然产出了可播放文件，
    // 但退出码非 0。文件存在且有内容就认为成功，避免用户白等一场。
    final File out = File(outputPath);
    if (!await out.exists() || await out.length() == 0) {
      throw StateError('转换没有产出文件');
    }
  }

  List<String> _argsFor(
    TranscodeKind kind,
    String input,
    String output, [
    String? secondary,
  ]) {
    switch (kind) {
      case TranscodeKind.tsToMp4:
        return <String>[
          '-y', '-hide_banner',
          '-i', input,
          '-c', 'copy',
          '-movflags', '+faststart',
          output,
        ];
      case TranscodeKind.audioToMp3:
        return <String>[
          '-y', '-hide_banner',
          '-i', input,
          '-vn',
          // 显式取第一条音轨。源可能是视频容器（合并后的 mp4），多音轨时
          // 不指定会按 default 标记挑，结果不可预期。
          '-map', '0:a:0',
          // 不加 `-ac 2`：实测 5.1 源 ffmpeg 会自动降混到立体声，
          // 强行指定反而把单声道源也变成双声道、文件白白大一倍。
          '-c:a', 'libmp3lame',
          '-b:a', '192k',
          output,
        ];
      case TranscodeKind.dashMerge:
        return <String>[
          '-y', '-hide_banner',
          '-i', input,
          '-i', secondary ?? '',
          // 显式取「第一路的视频 + 第二路的音频」。不写 -map 时 ffmpeg 会
          // 每路各挑一条最优流，若视频轨里混进了空音轨就会选错。
          '-map', '0:v:0',
          '-map', '1:a:0',
          '-c', 'copy',
          // 刻意不加 -shortest：它按「最短的一路」截断，音轨下载不完整
          // （CDN 提前断开、文件非空但短）时会把视频砍掉一大截，
          // 比结尾多几秒声音严重得多。实测 4s 视频 + 2s 音频会被砍成 2s。
          '-movflags', '+faststart',
          output,
        ];
    }
  }

  Future<void> _execute({
    required String ffmpeg,
    required List<String> args,
    required String outputPath,
    required Duration? total,
    required void Function(double progress) onProgress,
  }) async {
    logInfo('FFmpeg', '执行: $ffmpeg ${args.join(' ')}');

    final Process process = await Process.start(ffmpeg, args);
    _active = process;

    final StringBuffer stderrTail = StringBuffer();
    final Completer<void> stderrDone = Completer<void>();

    process.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(
      (String chunk) {
        stderrTail.write(chunk);
        if (stderrTail.length > 8000) {
          final String s = stderrTail.toString();
          stderrTail
            ..clear()
            ..write(s.substring(s.length - 4000));
        }
        final Duration? current = _parseProgressTime(chunk);
        if (current != null && total != null && total.inMilliseconds > 0) {
          final double ratio = current.inMilliseconds / total.inMilliseconds;
          onProgress(ratio.clamp(0.0, 0.999));
        }
      },
      onDone: () {
        if (!stderrDone.isCompleted) stderrDone.complete();
      },
      onError: (Object _) {
        if (!stderrDone.isCompleted) stderrDone.complete();
      },
    );

    // stdout 不读会撑满管道导致 ffmpeg 阻塞，必须消费掉。
    process.stdout.drain<void>();

    final int code = await process.exitCode;
    await stderrDone.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () {},
    );
    _active = null;

    if (_cancelled) {
      await _deleteQuietly(outputPath);
      throw const TranscodeCancelled();
    }

    if (code != 0) {
      final String tail = stderrTail.toString();
      throw _FfmpegFailure(code, _extractError(tail), tail);
    }

    onProgress(1);
  }

  /// ffmpeg 的进度行形如 `frame= 100 ... time=00:01:23.45 bitrate=...`，
  /// 用 `\r` 原地刷新，所以一个 chunk 里可能有多行，取最后一个。
  static Duration? _parseProgressTime(String chunk) {
    Duration? latest;
    for (final RegExpMatch m in RegExp(r'time=(\d+):(\d+):(\d+\.?\d*)').allMatches(chunk)) {
      final int h = int.parse(m.group(1)!);
      final int min = int.parse(m.group(2)!);
      final double sec = double.parse(m.group(3)!);
      latest = Duration(
        hours: h,
        minutes: min,
        milliseconds: (sec * 1000).round(),
      );
    }
    return latest;
  }

  /// 从 stderr 里挑出对用户有意义的那一行，整段 stderr 太长不适合直接展示。
  static String _extractError(String stderr) {
    final List<String> lines = stderr
        .split(RegExp(r'[\r\n]+'))
        .map((String l) => l.trim())
        .where((String l) => l.isNotEmpty)
        .toList();
    for (final String line in lines.reversed) {
      final String lower = line.toLowerCase();
      if (lower.contains('error') ||
          lower.contains('invalid') ||
          lower.contains('unable') ||
          lower.contains('no such') ||
          lower.contains('could not')) {
        return line;
      }
    }
    return lines.isEmpty ? 'ffmpeg 执行失败' : lines.last;
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final File f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 删不掉也不影响主流程，下次转换会覆盖
    }
  }

  @override
  Future<void> cancel(String jobId) async {
    // 队列是串行的，同一时刻只有一个进程在跑，所以不需要按 jobId 精确匹配。
    _cancelled = true;
    final Process? process = _active;
    if (process != null) {
      logInfo('FFmpeg', '取消转换 $jobId');
      process.kill(ProcessSignal.sigkill);
    }
  }
}

class _FfmpegFailure implements Exception {
  _FfmpegFailure(this.exitCode, this.message, [this.raw = '']);

  final int exitCode;

  /// 从 stderr 里挑出的一行，用来展示。
  final String message;

  /// 完整 stderr。[message] 只保留一行，判断错误类型时不够用 ——
  /// 比如「没有音轨」的关键行本身不含 error 字样，会被 [_extractError] 跳过。
  final String raw;

  @override
  String toString() => message;
}

/// stderr 是否在说「源里没有音频流」。
bool _looksLikeNoAudioStream(String text) {
  final String lower = text.toLowerCase();
  return lower.contains('matches no streams') ||
      lower.contains('does not contain any stream') ||
      lower.contains('no audio stream') ||
      lower.contains('could not find codec parameters for stream 0 (audio');
}

/// 用户主动取消。和失败区分开，UI 上显示「已取消」而不是「失败」。
class TranscodeCancelled implements Exception {
  const TranscodeCancelled();
  @override
  String toString() => '已取消';
}
