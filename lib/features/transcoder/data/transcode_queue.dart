import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

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
  TranscodeJob enqueue({
    required String sourcePath,
    required TranscodeKind kind,
    String? sourceTaskId,
    String? displayName,
  }) {
    for (final TranscodeJob job in _jobs) {
      if (job.sourcePath == sourcePath &&
          job.kind == kind &&
          !job.status.isFinished) {
        return job;
      }
    }

    final String baseName = p.basenameWithoutExtension(sourcePath);
    final File target = StoragePaths.uniqueFile('$baseName.${kind.extension}');

    final TranscodeJob job = TranscodeJob(
      id: HashUtil.md5Short('$sourcePath#${kind.name}#${DateTime.now().microsecondsSinceEpoch}'),
      sourcePath: sourcePath,
      outputPath: target.path,
      kind: kind,
      createdAt: DateTime.now(),
      sourceTaskId: sourceTaskId,
      displayName: displayName ?? p.basename(sourcePath),
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
      await _engine.run(
        inputPath: job.sourcePath,
        outputPath: job.outputPath,
        kind: job.kind,
        onProgress: (double value) {
          job.setProgress(value);
        },
        isCancelled: () => job.status == TranscodeStatus.canceled,
      );
      job.setProgress(1);
      // 取消和完成可能同时发生（kill 送达前进程已退出），以用户意图为准。
      if (job.status != TranscodeStatus.canceled) {
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
      _safeNotify();
      _pump();
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
