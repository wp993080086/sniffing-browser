import 'package:flutter/services.dart';

import '../../../core/logging/app_log.dart';
import '../domain/transcode_job.dart';

/// 源文件本身不满足转换前提，比如「要抽音轨，但文件里没有音轨」。
///
/// 单独一个类型是为了让 UI 能显示一句人话 —— ffmpeg 在这里的原话是
/// `Stream map '0:a:0' matches no streams.`，直接抛给用户没有任何意义。
class TranscodeUnsupportedSource implements Exception {
  const TranscodeUnsupportedSource(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 用户主动取消。和失败区分开，UI 上显示「已取消」而不是「失败」。
///
/// 放在引擎抽象层而不是桌面实现里：移动端走原生 session，同样需要表达取消，
/// 若留在 system_ffmpeg_engine.dart 会形成反向依赖。
class TranscodeCancelled implements Exception {
  const TranscodeCancelled();
  @override
  String toString() => '已取消';
}

/// 转换引擎抽象。
///
/// 为什么不在这一层直接依赖 ffmpeg 包：
/// 桌面端调本机 ffmpeg 进程，移动端走原生通道，两者无法共用一个 pub 依赖。
/// 由 TranscodeQueue 按平台选实现：桌面 SystemFfmpegEngine，其余 NativeTranscodeEngine。
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
        // 源可能是视频容器（合并后的 mp4、普通下载的 mp4）。
        // 显式取第一条音轨：多音轨的片子（双语版）不指定时 ffmpeg 会按
        // 默认标记挑，选中的不一定是用户以为的那条。
        return '-i "$inputPath" -vn -map 0:a:0 -c:a libmp3lame -b:a 192k '
            '"$outputPath"';
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

/// 走 Android 原生 FFmpegKit 的实现。
///
/// 契约要点：`startTranscode` 的回复由原生侧**挂起**到 FFmpeg session 结束才返回，
/// 所以这里的 await 天然等于「等这一路转码跑完」，队列不需要额外同步。
/// 进度则由原生通过同一个 channel 反向调用 `onProgress` 推过来。
class NativeTranscodeEngine extends TranscodeEngine {
  static const MethodChannel _channel = MethodChannel(
    'sniffing_browser/transcoder',
  );

  /// 当前正在跑的那一路的进度回调。队列严格串行，同一时刻只会有一个。
  static void Function(double)? _progressSink;
  static bool _handlerInstalled = false;

  bool? _available;

  static void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onProgress') {
        final Object? value = call.arguments;
        if (value is num) _progressSink?.call(value.toDouble());
        return null;
      }
      throw MissingPluginException('未知的原生回调：${call.method}');
    });
  }

  @override
  Future<bool> isAvailable() async {
    final bool? cached = _available;
    if (cached != null) return cached;
    try {
      final bool? result = await _channel.invokeMethod<bool>('isAvailable');
      // 只缓存成功结论：native 库偶发未就绪时返回 false，不该永远把入口判死。
      if (result == true) _available = true;
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
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

    _ensureHandler();
    _progressSink = onProgress;
    try {
      final Map<Object?, Object?>? reply = await _channel
          .invokeMethod<Map<Object?, Object?>>(
            'startTranscode',
            <String, Object?>{
              'input': inputPath,
              'secondaryInput': secondaryInputPath,
              'output': outputPath,
              'kind': kind.name,
            },
          );

      final String status = reply?['status'] as String? ?? 'failed';
      final String? message = reply?['message'] as String?;
      switch (status) {
        case 'done':
          // Android 在 `-c copy` 失败后会回退成「视频复制 + 音频重编」。
          // 结果一样可用，但不再是秒级无损转封装，记一笔方便排查慢任务。
          if (reply?['strategy'] == 'audioReencoded') {
            logInfo('FFmpeg', '无损转封装失败，已改为只重编音频完成转码');
          }
          onProgress(1);
          return;
        case 'canceled':
          throw const TranscodeCancelled();
        case 'unsupported':
          throw TranscodeUnsupportedSource(message ?? '这个文件里没有音轨，无法提取 MP3');
        default:
          throw StateError(message ?? '原生转换失败');
      }
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    } finally {
      _progressSink = null;
    }
  }

  @override
  Future<void> cancel(String jobId) async {
    if (!await isAvailable()) return;
    try {
      await _channel.invokeMethod<void>('cancelTranscode', <String, Object?>{
        'jobId': jobId,
      });
    } on MissingPluginException {
      // 原生侧已不在（比如引擎重建），忽略即可，会话自己会结束。
    } on PlatformException {
      // 同上。
    }
  }
}
