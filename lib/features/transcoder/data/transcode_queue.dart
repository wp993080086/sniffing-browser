import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/logging/app_log.dart';
import '../../../core/platform/platform_info.dart';
import '../../../core/platform/storage_paths.dart';
import '../../../core/utils/hash_util.dart';
import '../domain/transcode_job.dart';
import 'system_ffmpeg_engine.dart';
import 'transcode_engine.dart';

/// 转换队列。
///
/// 必须串行。并行跑多个 FFmpeg 不会更快 —— 它们抢同一批 CPU 核心，
/// 每个都会变慢，还可能触发移动端的内存压力限制，被系统直接杀掉。
class TranscodeQueue extends ChangeNotifier {
  TranscodeQueue({TranscodeEngine? engine})
      : _engine = engine ?? _defaultEngine();

  /// 桌面端可以直接跑系统 ffmpeg 进程，移动端沙箱不允许，只能走原生桥接。
  static TranscodeEngine _defaultEngine() {
    if (PlatformInfo.isDesktop) return SystemFfmpegEngine();
    return NativeTranscodeEngine();
  }

  final TranscodeEngine _engine;
  final List<TranscodeJob> _jobs = <TranscodeJob>[];

  bool _isRunning = false;
  bool _disposed = false;
  bool? _available;

  List<TranscodeJob> get jobs => List<TranscodeJob>.unmodifiable(_jobs);

  bool get isBusy => _isRunning;

  Future<bool> availability() async {
    final bool? cached = _available;
    if (cached != null) return cached;
    final bool result = await _engine.isAvailable();
    _available = result;
    return result;
  }

  /// 入队。同一个源文件 + 同一种转换不重复添加。
  ///
  /// 常规手动转换只用 [sourcePath] / [kind]；DASH 合并额外给
  /// [secondarySourcePath]（音频轨），并用 [replaceSource] 把成品覆盖回源路径。
  TranscodeJob enqueue({
    required String sourcePath,
    required TranscodeKind kind,
    String? secondarySourcePath,
    String? sourceTaskId,
    String? displayName,
    String? outputPath,
    bool replaceSource = false,
    void Function(TranscodeStatus status)? onFinished,
  }) {
    for (final TranscodeJob job in _jobs) {
      if (job.sourcePath == sourcePath &&
          job.kind == kind &&
          !job.status.isFinished) {
        return job;
      }
    }

    final String baseName = p.basenameWithoutExtension(sourcePath);
    // 合并任务的输出由下载队列指定（临时目录），其余按源文件名落到下载目录。
    final File target = outputPath != null
        ? File(outputPath)
        : StoragePaths.uniqueFile('$baseName.${kind.extension}');

    final TranscodeJob job = TranscodeJob(
      id: HashUtil.md5Short(
          '$sourcePath#${kind.name}#${DateTime.now().microsecondsSinceEpoch}'),
      sourcePath: sourcePath,
      outputPath: target.path,
      kind: kind,
      createdAt: DateTime.now(),
      secondarySourcePath: secondarySourcePath,
      sourceTaskId: sourceTaskId,
      displayName: displayName ?? p.basename(sourcePath),
      replaceSource: replaceSource,
      onFinished: onFinished,
    );

    _jobs.insert(0, job);
    _safeNotify();
    _pump();
    return job;
  }

  void cancel(String jobId) {
    final TranscodeJob? job = _find(jobId);
    if (job == null) return;
    if (job.status == TranscodeStatus.running) {
      // 立刻反映到 UI：用户点了取消，状态就该变，不该等进程真正退出。
      // 如果进程已经跑完（kill 落空的竞态），_run 里会看到状态是 canceled 并保持它。
      job.setStatus(TranscodeStatus.canceled);
      _safeNotify();
      unawaited(_engine.cancel(jobId));
    } else if (job.status == TranscodeStatus.pending) {
      job.setStatus(TranscodeStatus.canceled);
      _safeNotify();
    }
  }

  void retry(String jobId) {
    final TranscodeJob? job = _find(jobId);
    if (job == null || !job.status.isFinished) return;
    job.error = null;
    job.setProgress(0);
    job.setStatus(TranscodeStatus.pending);
    _safeNotify();
    _pump();
  }

  void remove(String jobId) {
    final TranscodeJob? job = _find(jobId);
    if (job == null) return;
    if (job.status == TranscodeStatus.running) {
      unawaited(_engine.cancel(jobId));
    }
    _jobs.remove(job);
    job.dispose();
    _safeNotify();
  }

  void _pump() {
    if (_disposed || _isRunning) return;
    final TranscodeJob? next = _nextPending();
    if (next == null) return;
    unawaited(_run(next));
  }

  TranscodeJob? _nextPending() {
    for (int i = _jobs.length - 1; i >= 0; i--) {
      if (_jobs[i].status == TranscodeStatus.pending) return _jobs[i];
    }
    return null;
  }

  Future<void> _run(TranscodeJob job) async {
    _isRunning = true;
    job.setStatus(TranscodeStatus.running);
    _safeNotify();

    try {
      if (!await availability()) {
        throw UnsupportedError(
          PlatformInfo.isDesktop
              ? '没有找到 ffmpeg，请安装后重试'
              : '当前平台尚未接入 FFmpeg',
        );
      }
      final Directory outDir = Directory(p.dirname(job.outputPath));
      if (!await outDir.exists()) {
        await outDir.create(recursive: true);
      }

      await _engine.run(
        inputPath: job.sourcePath,
        outputPath: job.outputPath,
        kind: job.kind,
        secondaryInputPath: job.secondarySourcePath,
        onProgress: (double value) {
          job.setProgress(value);
        },
        isCancelled: () => job.status == TranscodeStatus.canceled,
      );
      job.setProgress(1);
      // 取消和完成可能同时发生（kill 送达前进程已退出），以用户意图为准。
      if (job.status != TranscodeStatus.canceled) {
        if (job.replaceSource) {
          await _replaceSource(job);
        }
        job.setStatus(TranscodeStatus.completed);
      }
    } on TranscodeCancelled {
      job.setProgress(0);
      job.setStatus(TranscodeStatus.canceled);
    } catch (e) {
      // 转换途中被取消时，引擎抛的可能是进程被杀导致的通用错误，
      // 这里再判一次状态，避免把用户主动取消显示成失败。
      if (job.status == TranscodeStatus.canceled) {
        job.setProgress(0);
      } else {
        job.error = e.toString();
        job.setStatus(TranscodeStatus.failed);
      }
    } finally {
      _isRunning = false;
      // 先把终态抛给上层（下载队列要靠它决定是否删掉伴随任务），
      // 再通知 UI、再排下一个。
      final void Function(TranscodeStatus)? callback = job.onFinished;
      if (callback != null) {
        try {
          callback(job.status);
        } catch (e) {
          logWarn('Transcode', '完成回调异常: $e');
        }
      }
      _safeNotify();
      _pump();
    }
  }

  /// 合并成功后把成品挪回源路径，并删掉中间的音频轨。
  ///
  /// 顺序必须是「先落地成品，再删中间文件」：反过来的话，一旦 mv 失败
  /// 用户就既没有带声音的 mp4，也没了原始分片。
  Future<void> _replaceSource(TranscodeJob job) async {
    final File produced = File(job.outputPath);
    if (!await produced.exists()) {
      throw StateError('合并完成但没有产出文件');
    }

    final File target = File(job.sourcePath);
    await _moveFile(produced, target);

    final String? secondary = job.secondarySourcePath;
    if (secondary != null) {
      await _deleteQuietly(secondary);
    }
    // 临时目录里的成品已经挪走；如果 _moveFile 走了复制分支，这里清掉原件。
    await _deleteQuietly(job.outputPath);

    logInfo('Transcode', '音视频已合并: ${p.basename(job.sourcePath)}');
  }

  /// 同盘 rename 是瞬时的；跨盘（临时目录和下载目录可能不在一个卷）
  /// 会抛 FileSystemException，退回复制。
  static Future<void> _moveFile(File from, File to) async {
    final File target = File(to.path);
    if (await target.exists()) {
      await target.delete();
    }
    try {
      await from.rename(to.path);
    } on FileSystemException {
      await from.copy(to.path);
    }
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final File file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      logWarn('Transcode', '清理中间文件失败: $path ($e)');
    }
  }

  TranscodeJob? _find(String id) {
    for (final TranscodeJob job in _jobs) {
      if (job.id == id) return job;
    }
    return null;
  }

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final TranscodeJob job in _jobs) {
      job.dispose();
    }
    _jobs.clear();
    super.dispose();
  }
}
