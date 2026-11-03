import 'package:flutter/services.dart';

import '../domain/transcode_job.dart';

/// 转换引擎抽象。
///
/// 为什么不在这一层直接依赖 ffmpeg 包：
/// FFmpeg 在三个平台是三个不同的东西
/// （Android `ffmpeg_kit_flutter_new` / 鸿蒙 `@ohos/ffmpeg-kit` / Windows 同 Android），
/// 而 Dart 没有按平台条件依赖的语法。先留接口，阶段 5 按实测结果接实现。
abstract class TranscodeEngine {
  /// 引擎是否可用。UI 用它决定要不要显示转换入口。
  Future<bool> isAvailable();

  /// 执行转换。进度 0~1。
  ///
  /// [secondaryInputPath] 只有 [TranscodeKind.dashMerge] 需要（音频轨），
  /// 其余类型传 null。
  Future<void> run({
    required String inputPath,
    required String outputPath,
    required TranscodeKind kind,
    required void Function(double progress) onProgress,
    required void Function() isCancelled,
    String? secondaryInputPath,
  });

  Future<void> cancel(String jobId);

  /// 给日志和排查用的命令行（不实际执行）。
  String buildCommand({
    required String inputPath,
    required String outputPath,
    required TranscodeKind kind,
    String? secondaryInputPath,
  }) {
    switch (kind) {
      case TranscodeKind.tsToMp4:
        // 无损转封装。若源流编码 MP4 不支持，需要回退到只重编音频。
        return '-i "$inputPath" -c copy -movflags +faststart "$outputPath"';
      case TranscodeKind.audioToMp3:
        return '-i "$inputPath" -vn -c:a libmp3lame -b:a 192k "$outputPath"';
      case TranscodeKind.dashMerge:
        // `-map` 显式指定「第一路的视频 + 第二路的音频」。
        // 不写的话 ffmpeg 默认每路各取一条最优流，遇到两路都只有视频（或录制
        // 出来的分片带空音轨）时会选出重复的流。
        // 不加 `-shortest`：它按最短的一路截断，音轨残缺时会把视频砍掉。
        return '-i "$inputPath" -i "${secondaryInputPath ?? ''}" '
            '-map 0:v:0 -map 1:a:0 -c copy -movflags +faststart "$outputPath"';
    }
  }
}

/// 走原生桥接的实现。
///
/// 原生侧接好之后（Android 用 FFmpegKit，鸿蒙用 ohos_ffmpeg_kit），
/// 只需要实现这个 channel，Dart 侧一行不用改。
class NativeTranscodeEngine extends TranscodeEngine {
  static const MethodChannel _channel =
      MethodChannel('sniffing_browser/transcoder');

  bool? _available;

  @override
  Future<bool> isAvailable() async {
    final bool? cached = _available;
    if (cached != null) return cached;
    try {
      final bool? result = await _channel.invokeMethod<bool>('isAvailable');
      _available = result ?? false;
    } on MissingPluginException {
      _available = false;
    } on PlatformException {
      _available = false;
    }
    return _available!;
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
    if (!await isAvailable()) {
      throw UnsupportedError('当前平台尚未接入 FFmpeg，转换功能不可用');
    }
    await _channel.invokeMethod<void>('startTranscode', <String, Object?>{
      'input': inputPath,
      'secondaryInput': secondaryInputPath,
      'output': outputPath,
      'kind': kind.name,
      'command': buildCommand(
        inputPath: inputPath,
        outputPath: outputPath,
        kind: kind,
        secondaryInputPath: secondaryInputPath,
      ),
    });
  }

  @override
  Future<void> cancel(String jobId) async {
    if (!await isAvailable()) return;
    await _channel.invokeMethod<void>('cancelTranscode', <String, Object?>{
      'jobId': jobId,
    });
  }
}
