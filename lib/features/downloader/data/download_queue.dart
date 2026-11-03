import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/constants/app_constants.dart';
import '../../../core/platform/media_exporter.dart';
import '../../../core/platform/storage_paths.dart';
import '../../../core/utils/hash_util.dart';
import '../../sniffer/domain/media_item.dart';
import '../../sniffer/domain/media_type.dart';
import '../domain/download_status.dart';
import '../domain/download_task.dart';
import 'file_downloader.dart';
import 'hls/hls_downloader.dart';

/// 下载队列。
///
/// 应用级单例：注册在 ProviderScope 顶层，不挂在页面上。
/// 否则用户切页 → 页面 dispose → 后台完成的回调拿不到队列，任务状态就丢了。
///
/// 注意通知粒度：
/// - `notifyListeners()` 只在**任务增删、状态迁移**时调用
/// - 字节进度走每个任务自己的 `ValueNotifier`，不触发队列重建
class DownloadQueue extends ChangeNotifier {
  DownloadQueue({FileDownloader? downloader, HlsDownloader? hlsDownloader})
      : _downloader = downloader ?? FileDownloader(),
        _hls = hlsDownloader ?? HlsDownloader();

  final FileDownloader _downloader;
  final HlsDownloader _hls;

  final List<DownloadTask> _tasks = <DownloadTask>[];
  final Map<String, CancelToken> _tokens = <String, CancelToken>{};

  int _runningCount = 0;
  bool _disposed = false;

  List<DownloadTask> get tasks => List<DownloadTask>.unmodifiable(_tasks);

  int get activeCount => _tasks
      .where((DownloadTask t) =>
          t.status == DownloadStatus.running || t.status == DownloadStatus.pending)
      .length;

  bool get hasRunning => _runningCount > 0;

  /// 入队。同一 mediaId 已在队列中则不重复添加，直接返回已有任务。
  DownloadTask enqueue(MediaItem item, {Map<String, String>? extraHeaders}) {
    final DownloadTask? existing = _findByMedia(item.id);
    if (existing != null &&
        existing.status != DownloadStatus.canceled &&
        existing.status != DownloadStatus.failed) {
      return existing;
    }

    final Map<String, String> headers =
        <String, String>{...item.requestHeaders, ...?extraHeaders};
    if (item.pageUrl != null && !headers.keys.any((String k) => k.toLowerCase() == 'referer')) {
      headers['Referer'] = item.pageUrl!;
    }

    final String fileName = item.fileName ??
        _fallbackFileName(item.url, item.type);

    final DownloadTask task = DownloadTask(
      id: HashUtil.md5Short('${item.id}_${DateTime.now().microsecondsSinceEpoch}'),
      mediaId: item.id,
      url: item.url,
      type: item.type,
      fileName: fileName,
      createdAt: DateTime.now(),
      pageUrl: item.pageUrl,
      headers: headers,
      isStream: item.type.isStream,
    );

    _tasks.insert(0, task);
    _safeNotify();
    _pump();
    return task;
  }

  /// 取消：运行中的真正中断请求，等待中的直接改状态。
  void cancel(String taskId) {
    final DownloadTask? task = _findById(taskId);
    if (task == null) return;

    if (task.status == DownloadStatus.running) {
      _tokens[taskId]?.cancel('user');
    } else if (task.status == DownloadStatus.pending) {
      task.setStatus(DownloadStatus.canceled);
      _safeNotify();
    }
  }

  /// 重试。HLS 断点续传靠未删的临时目录，这里不需要额外状态。
  void retry(String taskId) {
    final DownloadTask? task = _findById(taskId);
    if (task == null) return;
    if (!task.status.isFinished) return;

    task.error = null;
    task.receivedBytes = 0;
    task.segmentDone = 0;
    task.progress.value = 0;
    task.speed.value = 0;
    task.setStatus(DownloadStatus.pending);
    _safeNotify();
    _pump();
  }

  void remove(String taskId) {
    final DownloadTask? task = _findById(taskId);
    if (task == null) return;
    if (task.status == DownloadStatus.running) {
      _tokens[taskId]?.cancel('user');
    }
    _tasks.remove(task);
    task.dispose();
    _safeNotify();
  }

  void clearFinished() {
    final List<DownloadTask> finished = _tasks
        .where((DownloadTask t) => t.status.isFinished)
        .toList();
    for (final DownloadTask task in finished) {
      _tasks.remove(task);
      task.dispose();
    }
    _safeNotify();
  }

  /// 导出已完成的文件到相册 / 音乐目录 / 下载目录。
  Future<ExportResult> export(String taskId) async {
    final DownloadTask? task = _findById(taskId);
    if (task == null) {
      return const ExportResult(ExportStatus.failed, message: '任务不存在');
    }
    final String? path = task.savedPath;
    if (path == null) {
      return const ExportResult(ExportStatus.failed, message: '文件尚未下载完成');
    }

    final ExportResult result = await MediaExporter.export(
      filePath: path,
      type: task.type,
      displayName: task.fileName,
    );
    task.exportStatus = result.status;
    _safeNotify();
    return result;
  }

  void _pump() {
    if (_disposed) return;
    while (_runningCount < AppConstants.maxConcurrentDownloads) {
      final DownloadTask? next = _nextPending();
      if (next == null) break;
      unawaited(_start(next));
    }
  }

  DownloadTask? _nextPending() {
    for (int i = _tasks.length - 1; i >= 0; i--) {
      if (_tasks[i].status == DownloadStatus.pending) return _tasks[i];
    }
    return null;
  }

  Future<void> _start(DownloadTask task) async {
    _runningCount++;
    task.setStatus(DownloadStatus.running);
    _safeNotify();

    final CancelToken token = CancelToken();
    _tokens[task.id] = token;

    try {
      if (task.type == MediaType.hls) {
        await _runHls(task, token);
      } else if (task.type == MediaType.dash) {
        throw DownloadException('暂不支持 DASH 分片重组，可等待后续版本');
      } else {
        await _runFile(task, token);
      }
    } on DownloadException catch (e) {
      if (token.isCancelled) {
        task.setStatus(DownloadStatus.canceled);
      } else {
        task.fail(e.toString());
      }
    } on DioException catch (e) {
      task.fail(CancelToken.isCancel(e) ? '已取消' : (e.message ?? '网络错误'));
      if (CancelToken.isCancel(e)) task.setStatus(DownloadStatus.canceled);
    } catch (e) {
      if (token.isCancelled) {
        task.setStatus(DownloadStatus.canceled);
      } else {
        task.fail(e.toString());
      }
    } finally {
      _runningCount--;
      _tokens.remove(task.id);
      _safeNotify();
      _pump();
    }
  }

  Future<void> _runFile(DownloadTask task, CancelToken token) async {
    final File target = StoragePaths.uniqueFile(task.fileName);
    final Stopwatch stopwatch = Stopwatch()..start();
    int lastSampleMs = 0;
    int lastSampleBytes = 0;

    await _downloader.download(
      url: task.url,
      target: target,
      headers: task.headers,
      cancelToken: token,
      onProgress: (int received, int total) {
        task.updateBytes(received, total > 0 ? total : null);

        // 速度按 500ms 采样，直接用累计值算平均会让前半段数字虚高。
        final int elapsed = stopwatch.elapsedMilliseconds;
        if (elapsed - lastSampleMs >= 500) {
          final double seconds = (elapsed - lastSampleMs) / 1000;
          if (seconds > 0) {
            task.speed.value = (received - lastSampleBytes) / seconds;
          }
          lastSampleMs = elapsed;
          lastSampleBytes = received;
        }
      },
    );

    final String ext = p.extension(target.path);
    task.complete(
      target.path,
      containerExt: ext.isEmpty ? null : ext.substring(1),
    );
  }

  Future<void> _runHls(DownloadTask task, CancelToken token) async {
    final Directory workDir = StoragePaths.tempDirFor(task.id);
    // 输出必须放在 workDir 之外：HlsDownloader 成功后会删掉整个 workDir。
    final File rawOutput = File(p.join(StoragePaths.temp.path, '${task.id}.out'));

    final HlsDownloadResult result = await _hls.download(
      playlistUrl: task.url,
      workDir: workDir,
      output: rawOutput,
      headers: task.headers,
      userCancelToken: token,
      onProgress: (HlsProgress progress) {
        task.updateSegments(progress.done, progress.total);
      },
    );

    final String baseName = p.basenameWithoutExtension(task.fileName);
    final File target = StoragePaths.uniqueFile('$baseName.${result.container}');
    if (await target.exists()) {
      await target.delete();
    }
    await result.file.rename(target.path);

    task.needsRemux = result.needsRemux;
    task.complete(target.path, containerExt: result.container);
  }

  String _fallbackFileName(String url, MediaType type) {
    final Uri? uri = Uri.tryParse(url);
    final String guessed =
        (uri != null && uri.pathSegments.isNotEmpty) ? uri.pathSegments.last : '';
    if (guessed.isNotEmpty && guessed.length <= 80) {
      return Uri.decodeComponent(guessed);
    }
    return 'media_${DateTime.now().millisecondsSinceEpoch}.${type.defaultExtension}';
  }

  DownloadTask? _findById(String id) {
    for (final DownloadTask task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  DownloadTask? _findByMedia(String mediaId) {
    for (final DownloadTask task in _tasks) {
      if (task.mediaId == mediaId) return task;
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
    for (final CancelToken token in _tokens.values) {
      token.cancel('dispose');
    }
    _tokens.clear();
    for (final DownloadTask task in _tasks) {
      task.dispose();
    }
    _tasks.clear();
    super.dispose();
  }
}
