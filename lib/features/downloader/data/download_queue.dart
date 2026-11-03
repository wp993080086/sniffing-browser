import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/constants/app_constants.dart';
import '../../../core/logging/app_log.dart';
import '../../../core/platform/media_exporter.dart';
import '../../../core/platform/storage_paths.dart';
import '../../../core/utils/hash_util.dart';
import '../../sniffer/domain/media_item.dart';
import '../../sniffer/domain/media_type.dart';
import '../../transcoder/data/transcode_queue.dart';
import '../../transcoder/domain/transcode_job.dart';
import '../domain/dash_pair.dart';
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
  DownloadQueue({
    FileDownloader? downloader,
    HlsDownloader? hlsDownloader,
    TranscodeQueue? transcoder,
    List<MediaItem> Function()? poolSupplier,
  })  : _downloader = downloader ?? FileDownloader(),
        _hls = hlsDownloader ?? HlsDownloader(),
        _transcoder = transcoder,
        _poolSupplier = poolSupplier;

  final FileDownloader _downloader;
  final HlsDownloader _hls;

  /// 合并音视频用。缺省时退化为「只下载不合并」，不影响单轨下载。
  final TranscodeQueue? _transcoder;

  /// 拿当前页面已嗅探到的资源。
  ///
  /// 入队那一刻资源列表可能还不全（用户手快，点了视频轨时音频轨还没请求到），
  /// 真正开始下载时再查一次，能覆盖这种时序。
  final List<MediaItem> Function()? _poolSupplier;

  final List<DownloadTask> _tasks = <DownloadTask>[];
  final Map<String, CancelToken> _tokens = <String, CancelToken>{};

  /// 已经排过合并的视频任务 id，防止音频/视频两边都触发一次。
  final Set<String> _mergeScheduled = <String>{};

  /// 已经判定为「不配对」的视频任务，避免入队和开跑时各记一遍日志。
  final Set<String> _pairRejected = <String>{};

  int _runningCount = 0;
  bool _disposed = false;

  List<DownloadTask> get tasks => List<DownloadTask>.unmodifiable(_tasks);

  /// 界面展示用的任务：伴随任务（自动补的音频轨）是实现细节，不单独列出。
  List<DownloadTask> get visibleTasks =>
      _tasks.where((DownloadTask t) => !t.isCompanion).toList();

  int get activeCount => _tasks
      .where((DownloadTask t) =>
          t.status == DownloadStatus.running || t.status == DownloadStatus.pending)
      .length;

  bool get hasRunning => _runningCount > 0;

  /// 入队。同一 mediaId 已在队列中则不重复添加，直接返回已有任务。
  ///
  /// [pool] 是当前页面的嗅探结果，用来给 DASH 分片配对音频轨。
  /// 传了就自动补一条伴随任务并在两条都完成后合并；不传就是普通单文件下载。
  DownloadTask enqueue(
    MediaItem item, {
    Map<String, String>? extraHeaders,
    List<MediaItem>? pool,
  }) {
    final DownloadTask? existing = _findByMedia(item.id);
    if (existing != null &&
        existing.status != DownloadStatus.canceled &&
        existing.status != DownloadStatus.failed) {
      return existing;
    }

    final DownloadTask task = _createTask(item, extraHeaders: extraHeaders);
    _tasks.insert(0, task);

    // DASH：画面和声音是两条独立请求，只下视频轨得到的是哑的。
    final MediaItem? audio = DashPairer.findAudioFor(
      item,
      pool ?? _poolSupplier?.call() ?? const <MediaItem>[],
    );
    if (audio != null) {
      _attachCompanion(task, audio, extraHeaders: extraHeaders);
    }

    _safeNotify();
    _pump();
    return task;
  }

  DownloadTask _createTask(MediaItem item, {Map<String, String>? extraHeaders}) {
    final Map<String, String> headers =
        <String, String>{...item.requestHeaders, ...?extraHeaders};
    if (item.pageUrl != null &&
        !headers.keys.any((String k) => k.toLowerCase() == 'referer')) {
      headers['Referer'] = item.pageUrl!;
    }

    final String fileName =
        item.fileName ?? _fallbackFileName(item.url, item.type);

    return DownloadTask(
      id: HashUtil.md5Short(
          '${item.id}_${DateTime.now().microsecondsSinceEpoch}'),
      mediaId: item.id,
      url: item.url,
      type: item.type,
      fileName: fileName,
      createdAt: DateTime.now(),
      pageUrl: item.pageUrl,
      headers: headers,
      isStream: item.type.isStream,
    );
  }

  /// 给视频轨补一条音频轨任务，两条都完成后合并成一个带声音的 mp4。
  void _attachCompanion(
    DownloadTask video,
    MediaItem audio, {
    Map<String, String>? extraHeaders,
  }) {
    if (_pairRejected.contains(video.id)) return;

    // 用户可能已经自己点过这条音频轨（他的诉求是单独下音频转 MP3），
    // 这时不要抢过来合并 —— 合并成功后会把音频文件删掉。
    final DownloadTask? existing = _findByMedia(audio.id);
    if (existing != null) {
      _pairRejected.add(video.id);
      logInfo('Download', '音轨已被单独加入队列，不自动配对: ${audio.fileName}');
      return;
    }

    final DownloadTask companion = _createTask(audio, extraHeaders: extraHeaders);
    companion.isCompanion = true;
    companion.pairedTaskId = video.id;
    video.pairedTaskId = companion.id;

    _tasks.insert(0, companion);
    logInfo('Download', '已配对音轨 ${audio.fileName}，下载完成后自动合并');
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
    _forgetPairState(task);
    task.dispose();
    _safeNotify();
  }

  void clearFinished() {
    final List<DownloadTask> finished = _tasks
        .where((DownloadTask t) => t.status.isFinished)
        .toList();
    for (final DownloadTask task in finished) {
      _tasks.remove(task);
      _forgetPairState(task);
      task.dispose();
    }
    _safeNotify();
  }

  /// 任务从列表里消失后清掉配对相关的记账，避免长时间使用后无限增长。
  void _forgetPairState(DownloadTask task) {
    _mergeScheduled.remove(task.id);
    _pairRejected.remove(task.id);
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
    // 入队时没配上、这一会儿页面上又出现了音频轨，这里补一次。
    _retryPairFromPool(task);

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
      _afterTaskSettled(task);
      _pump();
    }
  }

  /// 下载开始时再查一次配对。
  ///
  /// 用户点下载那一刻，音频轨的请求可能还没发出去；等排队轮到它时通常已经
  /// 出现在嗅探列表里了。只处理「视频轨 + 明确的 m4s」这一种，别的一概不管。
  void _retryPairFromPool(DownloadTask task) {
    if (task.isCompanion || task.pairedTaskId != null) return;
    if (task.type != MediaType.video) return;
    if (!DashPairer.isDashSegmentUrl(task.url)) return;

    final List<MediaItem>? pool = _poolSupplier?.call();
    if (pool == null || pool.isEmpty) return;

    MediaItem? self;
    for (final MediaItem item in pool) {
      if (item.id == task.mediaId) {
        self = item;
        break;
      }
    }
    if (self == null) return;

    final MediaItem? audio = DashPairer.findAudioFor(self, pool);
    if (audio == null) {
      // 这条是排查「为什么我下的视频没声音」的关键线索：
      // 要么页面里本来就只有一条视频轨（站点把音轨内嵌了），
      // 要么嗅探侧没认出音频轨（移动端拿不到 MIME 时会把 m4s 都当成视频）。
      logInfo(
        'Download',
        'DASH 视频轨没找到配对的音频轨，将按单轨下载（无声）: ${task.fileName}',
      );
      return;
    }
    _attachCompanion(task, audio);
  }

  /// 一条任务落定后，看看配对的那条是不是也好了，好了就合并。
  void _afterTaskSettled(DownloadTask task) {
    final String? peerId = task.pairedTaskId;
    if (peerId == null) return;
    final DownloadTask? peer = _findById(peerId);
    if (peer == null) return;

    if (task.status != DownloadStatus.completed) {
      _handlePairFailure(task, peer);
      return;
    }
    if (peer.status != DownloadStatus.completed) return;

    final DownloadTask video = task.isCompanion ? peer : task;
    final DownloadTask audio = task.isCompanion ? task : peer;
    _scheduleMerge(video, audio);
  }

  /// 配对里有一条失败了。
  ///
  /// 原则是「能用的那半不许被拖死」：视频轨失败就把没意义还在排队的音频取消；
  /// 音频轨失败就让视频照常完成 —— 无声总比没有好，用户至少能看。
  void _handlePairFailure(DownloadTask task, DownloadTask peer) {
    if (task.isCompanion) {
      logWarn('Download', '音轨未下成，${peer.fileName} 将没有声音');
      peer.mergedAudio = false;
      _dropLater(task);
    } else if (peer.status == DownloadStatus.pending ||
        peer.status == DownloadStatus.running) {
      logWarn('Download', '视频轨未下成，取消配对的音轨');
      cancel(peer.id);
    }
    _safeNotify();
  }

  void _scheduleMerge(DownloadTask video, DownloadTask audio) {
    final TranscodeQueue? transcoder = _transcoder;
    if (transcoder == null) return;

    final String? videoPath = video.savedPath;
    final String? audioPath = audio.savedPath;
    if (videoPath == null || audioPath == null) return;
    if (!_mergeScheduled.add(video.id)) return;

    // 输出先落到临时目录：合并完直接覆盖回视频轨路径，下载任务持有的路径
    // 不用改，导出和后续转 MP3 都还能直接用。
    final File out =
        File(p.join(StoragePaths.temp.path, '${video.id}.merge.mp4'));
    logInfo('Download', '音视频都已就绪，开始合并: ${video.fileName}');

    transcoder.enqueue(
      sourcePath: videoPath,
      secondarySourcePath: audioPath,
      kind: TranscodeKind.dashMerge,
      sourceTaskId: video.id,
      displayName: video.fileName,
      outputPath: out.path,
      replaceSource: true,
      onFinished: (TranscodeStatus status) {
        if (_disposed) return;
        final bool ok = status == TranscodeStatus.completed;
        video.mergedAudio = ok;
        if (ok) {
          video.container = 'mp4';
          video.needsRemux = false;
          // 音频轨已经被合进 mp4，原始分片留在列表里只会让人困惑。
          _dropLater(audio);
        } else {
          logWarn('Download', '合并失败（${status.label}），保留原始分片');
        }
        _safeNotify();
      },
    );
  }

  /// 延后一步移除任务。
  ///
  /// 调用点常常在任务自己的 finally 里，当场 dispose 会让后续的 token 清理
  /// 碰到已销毁的 notifier。留一拍给调用链走完。
  void _dropLater(DownloadTask task) {
    Future<void>.microtask(() {
      if (_disposed) return;
      if (_tasks.remove(task)) {
        _forgetPairState(task);
        task.dispose();
        _safeNotify();
      }
    });
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
      // 落盘前做内容校验：URL 说 .mp4 不代表内容真是 mp4
      expectType: task.type,
      onProgress: (int received, int total) {
        task.updateBytes(received, total > 0 ? total : null);

        // 速度按 500ms 采样，直接用累计值算平均会让前半段数字虚高。
        final int elapsed = stopwatch.elapsedMilliseconds;
        if (elapsed - lastSampleMs >= 500) {
          final double seconds = (elapsed - lastSampleMs) / 1000;
          if (seconds > 0) {
            // 走方法而不是直写 notifier：下载中途队列被 dispose 时这里还会被调用
            task.setSpeed((received - lastSampleBytes) / seconds);
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
