import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/logging/app_log.dart';
import '../../../core/platform/media_exporter.dart';
import '../../../core/platform/platform_info.dart';
import '../../../core/platform/storage_paths.dart';
import '../../../core/utils/hash_util.dart';
import '../../sniffer/domain/media_type.dart';
import '../domain/transcode_job.dart';
import 'system_ffmpeg_engine.dart';
import 'transcode_engine.dart';
import 'transcode_store.dart';

/// 把转换产物写进系统媒体库。默认走 [MediaExporter]，测试可替换。
typedef LibraryExporter = Future<ExportResult> Function({
  required String filePath,
  required MediaType type,
  required String displayName,
});

/// 转换队列。
///
/// 必须串行。并行跑多个 FFmpeg 不会更快 —— 它们抢同一批 CPU 核心，
/// 每个都会变慢，还可能触发移动端的内存压力限制，被系统直接杀掉。
class TranscodeQueue extends ChangeNotifier {
  TranscodeQueue({
    TranscodeEngine? engine,
    LibraryExporter? libraryExporter,
    bool? autoExportToLibrary,
    TranscodeStore? store,
  })  : _engine = engine ?? _defaultEngine(),
        _libraryExporter = libraryExporter ?? _defaultExporter,
        _store = store,
        // 桌面产物本来就落在用户下载目录，不需要再入库；
        // 移动端私有目录用户进不去，必须复制进媒体库才算「找到得到」。
        _autoExportToLibrary = autoExportToLibrary ??
            (PlatformInfo.current == AppPlatform.android);

  static Future<ExportResult> _defaultExporter({
    required String filePath,
    required MediaType type,
    required String displayName,
  }) {
    return MediaExporter.export(
      filePath: filePath,
      type: type,
      displayName: displayName,
    );
  }

  /// 桌面端可以直接跑系统 ffmpeg 进程，移动端沙箱不允许，只能走原生桥接。
  static TranscodeEngine _defaultEngine() {
    if (PlatformInfo.isDesktop) return SystemFfmpegEngine();
    return NativeTranscodeEngine();
  }

  final TranscodeEngine _engine;
  final LibraryExporter _libraryExporter;
  final bool _autoExportToLibrary;

  /// 任务记录的落盘。为 null 表示不持久化（测试用）。
  final TranscodeStore? _store;
  final List<TranscodeJob> _jobs = <TranscodeJob>[];

  bool _isRunning = false;
  bool _disposed = false;
  bool? _available;
  bool _restored = false;
  bool _persistScheduled = false;

  List<TranscodeJob> get jobs => List<TranscodeJob>.unmodifiable(_jobs);

  bool get isBusy => _isRunning;

  /// 还没结束的任务数，给入口角标用。
  int get activeCount =>
      _jobs.where((TranscodeJob job) => !job.status.isFinished).length;

  /// 从磁盘恢复上次的任务记录。
  ///
  /// 规则：
  /// - `running`：ffmpeg 进程随应用一起死了，标成「中断」并允许重试，
  ///   不能假装它还在跑（否则进度条会永远停在某个百分比）。
  /// - `pending`：重新排进队列，接着跑。
  /// - 其余：按原状态展示。产物多半还在，直接看历史。
  ///
  /// 进度不落盘，所以恢复出来的任务进度一律从 0 开始。
  Future<void> restore() async {
    final TranscodeStore? store = _store;
    if (store == null || _restored || _disposed) return;
    _restored = true;

    final List<TranscodeJob> jobs = await store.load();
    if (_disposed || jobs.isEmpty) return;

    for (final TranscodeJob job in jobs) {
      if (job.status == TranscodeStatus.running) {
        job.error = '应用重启，转换已中断，可重试';
        job.setStatus(TranscodeStatus.failed);
      }
      _jobs.add(job);
    }
    logInfo('Transcode', '已恢复 ${jobs.length} 条转换记录');
    _safeNotify();
    _pump();
    _schedulePersist();
  }

  /// 清掉所有已结束的记录。磁盘上跟着删，不然下次启动又全回来了。
  void clearFinished() {
    final List<TranscodeJob> finished = _jobs
        .where((TranscodeJob job) => job.status.isFinished)
        .toList();
    if (finished.isEmpty) return;
    for (final TranscodeJob job in finished) {
      _jobs.remove(job);
      job.dispose();
    }
    _safeNotify();
    _schedulePersist();
  }

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
    _schedulePersist();
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
      _schedulePersist();
      unawaited(_engine.cancel(jobId));
    } else if (job.status == TranscodeStatus.pending) {
      job.setStatus(TranscodeStatus.canceled);
      _safeNotify();
      _schedulePersist();
    }
  }

  void retry(String jobId) {
    final TranscodeJob? job = _find(jobId);
    if (job == null || !job.status.isFinished) return;
    job.error = null;
    job.exportMessage = null;
    job.exported = false;
    job.mediaUri = null;
    job.setProgress(0);
    job.setStatus(TranscodeStatus.pending);
    _safeNotify();
    _schedulePersist();
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
    _schedulePersist();
  }

  /// 攒一批写：入队 → 开始 → 结束往往是连着几次状态变更，
  /// 每次都落盘会反复打开同一个文件。
  void _schedulePersist() {
    if (_store == null || _persistScheduled || _disposed) return;
    _persistScheduled = true;
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      _persistScheduled = false;
      if (_disposed) return;
      unawaited(_store.save(_jobs));
    });
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
    // 把「正在跑」也落盘：万一应用被系统杀掉，下次启动才知道这条是中断，
    // 而不是把它当成还没开始的 pending 又自动重跑一遍。
    _schedulePersist();

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
        } else {
          await _exportToLibrary(job);
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
      _schedulePersist();
      _pump();
    }
  }

  /// 移动端把产物复制进系统媒体库。
  ///
  /// 移动端只能写应用私有目录（`Android/data/<包名>/files/SniffingBrowser`），
  /// 而 Android 11+ 的文件管理器进不去 `Android/data`，媒体库也不会扫描那里，
  /// 结果就是「转换完成」但用户在音乐 / 视频 App 里根本找不到文件。
  /// 所以转换成功后立刻入库一份，并把落点写进 [TranscodeJob.exportMessage]。
  ///
  /// 失败不能把任务判成失败 —— 产物本身是好的，只是没入库。
  Future<void> _exportToLibrary(TranscodeJob job) async {
    if (!_autoExportToLibrary) return;

    final MediaType type = job.kind == TranscodeKind.audioToMp3
        ? MediaType.audio
        : MediaType.video;
    try {
      final ExportResult result = await _libraryExporter(
        filePath: job.outputPath,
        type: type,
        displayName: p.basename(job.outputPath),
      );
      job.exported = result.isSuccess;
      job.mediaUri = result.isSuccess ? result.targetPath : null;
      job.exportMessage = result.isSuccess
          ? result.displayMessage
          : '转换完成，但没能存入系统媒体库（${result.displayMessage}）';
      if (result.isSuccess) {
        logInfo('Transcode', '产物已入库: ${job.exportMessage}');
      } else {
        logWarn('Transcode', '产物入库失败: ${result.displayMessage}');
      }
    } catch (e) {
      job.exported = false;
      job.exportMessage = '转换完成，但保存到媒体库失败: $e';
      logWarn('Transcode', '产物入库异常: $e');
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
