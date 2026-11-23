import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/constants/app_constants.dart';
import '../../../core/logging/app_log.dart';
import '../../../core/platform/download_foreground_service.dart';
import '../../../core/platform/media_exporter.dart';
import '../../../core/platform/storage_paths.dart';
import '../../../core/utils/hash_util.dart';
import '../../settings/data/site_rule.dart';
import '../../sniffer/domain/media_item.dart';
import '../../sniffer/domain/media_type.dart';
import '../../transcoder/data/transcode_queue.dart';
import '../../transcoder/domain/transcode_job.dart';
import '../domain/dash_pair.dart';
import '../domain/download_status.dart';
import '../domain/download_task.dart';
import 'dash/dash_downloader.dart';
import 'download_store.dart';
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
    DashDownloader? dashDownloader,
    TranscodeQueue? transcoder,
    List<MediaItem> Function()? poolSupplier,
    DownloadStore? store,
    int Function()? segmentConcurrency,
    List<SiteRule> Function()? siteRules,
    List<Duration> networkWaits = defaultNetworkWaits,
  }) : _downloader = downloader ?? FileDownloader(),
       _transcoder = transcoder,
       _poolSupplier = poolSupplier,
       _store = store,
       _siteRules = siteRules,
       _networkWaits = networkWaits {
    // HLS 缺省复用同一个 downloader：Cookie / 超时 / 重试策略必须和单文件
    // 一致，否则会出现「playlist 拿得到、分片 403」这种难查的差异。
    _hls =
        hlsDownloader ??
        HlsDownloader(
          downloader: _downloader,
          segmentConcurrency: segmentConcurrency,
        );
    // DASH 也复用同一个 downloader：Cookie、代理、403 换头策略必须一致。
    _dash =
        dashDownloader ??
        DashDownloader(
          downloader: _downloader,
          segmentConcurrency: segmentConcurrency,
        );
    // 通知栏按钮是全局操作，反调这里；platform 层不持有队列引用。
    DownloadForegroundService.setActionHandler(
      onPauseAll: pauseAll,
      onResumeAll: resumeAll,
      onCancelAll: cancelAll,
    );
  }

  final FileDownloader _downloader;
  late final HlsDownloader _hls;
  late final DashDownloader _dash;

  /// 任务记录的落盘。为 null 表示不持久化（测试用）。
  final DownloadStore? _store;

  /// 合并音视频用。缺省时退化为「只下载不合并」，不影响单轨下载。
  final TranscodeQueue? _transcoder;

  /// 断网后的重试节奏，第 4 次之后固定一分钟一次。见 [defaultNetworkWaits]。
  final List<Duration> _networkWaits;

  /// 断网重试的等待表。
  ///
  /// 先密后疏：早期断流多半几秒就恢复，等一分钟纯粹浪费；真长时间断网
  /// （熄屏、进隧道）再怎么等也都是等，一分钟一次足够，不烧电。
  static const List<Duration> defaultNetworkWaits = <Duration>[
    Duration(seconds: 3),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];

  /// 拿当前页面已嗅探到的资源。
  ///
  /// 入队那一刻资源列表可能还不全（用户手快，点了视频轨时音频轨还没请求到），
  /// 真正开始下载时再查一次，能覆盖这种时序。
  final List<MediaItem> Function()? _poolSupplier;

  /// 站点规则现取：设置页改完对下一个新任务立刻生效，不重建队列。
  final List<SiteRule> Function()? _siteRules;

  final List<DownloadTask> _tasks = <DownloadTask>[];
  final Map<String, CancelToken> _tokens = <String, CancelToken>{};

  /// 已经排过合并的视频任务 id，防止音频/视频两边都触发一次。
  final Set<String> _mergeScheduled = <String>{};

  /// 已经判定为「不配对」的视频任务，避免入队和开跑时各记一遍日志。
  final Set<String> _pairRejected = <String>{};

  int _runningCount = 0;
  bool _disposed = false;
  bool _restored = false;
  bool _persistScheduled = false;

  /// 被用户暂停的任务 id。token 取消时靠它区分「暂停」和「取消」，
  /// 否则 _start 的 catch 会把暂停也标成已取消。
  final Set<String> _pausedIds = <String>{};
  DateTime? _lastNotificationPush;

  List<DownloadTask> get tasks => List<DownloadTask>.unmodifiable(_tasks);

  /// 界面展示用的任务：伴随任务（自动补的音频轨）是实现细节，不单独列出。
  List<DownloadTask> get visibleTasks =>
      _tasks.where((DownloadTask t) => !t.isCompanion).toList();

  int get activeCount => _tasks
      .where(
        (DownloadTask t) =>
            t.status == DownloadStatus.running ||
            t.status == DownloadStatus.waitingNetwork ||
            t.status == DownloadStatus.pending,
      )
      .length;

  bool get hasRunning => _runningCount > 0;

  bool get hasPaused => _tasks.any(
    (DownloadTask t) => t.status == DownloadStatus.paused,
  );

  /// 通知栏的全局暂停。运行中/等网络的中断请求，等待中的直接改状态；
  /// 全部落到 paused，点继续后从 .part 断点续传。
  void pauseAll() {
    final List<DownloadTask> targets = _tasks
        .where(
          (DownloadTask t) =>
              t.status == DownloadStatus.running ||
              t.status == DownloadStatus.waitingNetwork ||
              t.status == DownloadStatus.pending,
        )
        .toList();
    if (targets.isEmpty) return;

    for (final DownloadTask task in targets) {
      _pausedIds.add(task.id);
      task.setStatus(DownloadStatus.paused);
      task.speed.value = 0;
      _tokens[task.id]?.cancel('pause');
    }
    _safeNotify();
    _schedulePersist();
    _pushNotificationProgress(force: true);
  }

  /// 通知栏的全局继续。paused 退回 pending 重新调度，进度不清零 —— 单文件靠
  /// 未删的 .part 续传，HLS 靠同一 workDir 里已下的分片。
  void resumeAll() {
    bool changed = false;
    for (final DownloadTask task in _tasks) {
      if (task.status != DownloadStatus.paused) continue;
      _pausedIds.remove(task.id);
      task.setStatus(DownloadStatus.pending);
      changed = true;
    }
    if (!changed) return;
    _safeNotify();
    _schedulePersist();
    _pump();
  }

  /// 通知栏的「取消全部」。和 [pauseAll] 的区别是不保留断点标记。
  void cancelAll() {
    final List<DownloadTask> targets = _tasks
        .where(
          (DownloadTask t) =>
              t.status != DownloadStatus.completed &&
              t.status != DownloadStatus.canceled,
        )
        .toList();
    if (targets.isEmpty) return;

    for (final DownloadTask task in targets) {
      _pausedIds.remove(task.id);
      if (task.status.isRunningOrWaiting) {
        _tokens[task.id]?.cancel('user');
      } else {
        task.setStatus(DownloadStatus.canceled);
      }
    }
    _safeNotify();
    _schedulePersist();
  }

  /// token 被取消后任务该落在哪个状态。暂停走 paused，其余走 canceled。
  ///
  /// [token] 用于挡竞态：暂停后立刻点继续会起一个新 token，旧取消的 catch
  /// 晚到时不能把新状态覆盖掉。
  void _settleCancel(DownloadTask task, CancelToken token) {
    if (!identical(_tokens[task.id], token)) return;
    if (_pausedIds.remove(task.id)) {
      task.setStatus(DownloadStatus.paused);
    } else {
      task.setStatus(DownloadStatus.canceled);
    }
  }

  /// 把聚合进度推给通知栏。字节进度不触发 notifyListeners，必须单独走
  /// MethodChannel；太频繁会拖慢主 isolate，所以 1 秒一次。
  void _pushNotificationProgress({bool force = false}) {
    if (_disposed) return;
    final DateTime now = DateTime.now();
    if (!force &&
        _lastNotificationPush != null &&
        now.difference(_lastNotificationPush!) < const Duration(seconds: 1)) {
      return;
    }
    _lastNotificationPush = now;

    int done = 0;
    int total = 0;
    double speed = 0;
    int count = 0;
    for (final DownloadTask task in _tasks) {
      // 等待网络 / 暂停也是「还在队列里」的任务：只统计 running 的话，
      // 断网重试期间通知栏会显示 0 项，用户以为任务全没了。
      if (task.status != DownloadStatus.running &&
          task.status != DownloadStatus.waitingNetwork &&
          task.status != DownloadStatus.paused) {
        continue;
      }
      count++;
      done += task.receivedBytes;
      total += task.totalBytes ?? 0;
      speed += task.speed.value;
    }
    unawaited(
      DownloadForegroundService.update(
        done: done,
        total: total,
        speed: speed,
        count: count,
      ),
    );
  }

  /// 从磁盘恢复上次的下载记录。
  ///
  /// 规则和转换队列不同，因为两者的「未完成」含义不一样：
  /// - `completed`：产物还在就能直接看、导出、转码；文件被清掉了（用户清
  ///   `Android/data`、系统回收空间）就标成失败，否则点导出才发现是空的。
  /// - 其余（pending / running / paused）：**一律标成「已中断，可重试」，
  ///   不自动重跑**。下载是随进程走的，应用被杀之后不可能还在跑；而且这些
  ///   地址（m3u8 / m4s）多半带签名，隔一段时间就过期，重启后自动跑只会刷
  ///   一屏 403，还可能在移动网络下白耗流量。
  ///
  /// 用户点重试时任务 id 不变，HLS 的临时分片目录（`tmp/<taskId>/seg_*.part`）
  /// 还在，所以那是真正的分片级续传，不是从头再来。
  Future<void> restore() async {
    final DownloadStore? store = _store;
    if (store == null || _restored || _disposed) return;
    _restored = true;

    final List<DownloadTask> tasks = await store.load();
    if (_disposed || tasks.isEmpty) return;

    for (final DownloadTask task in tasks) {
      if (task.status == DownloadStatus.completed) {
        final String? path = task.savedPath;
        if (path == null || !await File(path).exists()) {
          task
            ..savedPath = null
            ..fail('文件已被删除，可重新下载');
          // 不留在 100%：失败的任务挂个满进度条会让人以为是「下完了」。
          task.progress.value = 0;
        }
      } else if (task.status != DownloadStatus.canceled &&
          task.status != DownloadStatus.failed) {
        task.fail('应用重启，下载已中断，可重试');
      }
      _tasks.add(task);
    }
    logInfo('Download', '已恢复 ${_tasks.length} 条下载记录');
    _safeNotify();
    _schedulePersist();
  }

  /// 入队。同一 mediaId 已在队列中则不重复添加，直接返回已有任务。
  ///
  /// [pool] 是当前页面的嗅探结果，用来给 DASH 分片配对音频轨。
  /// 传了就自动补一条伴随任务并在两条都完成后合并；不传就是普通单文件下载。
  ///
  /// [pageTitle] 是来源页标题，只用于给 HLS 文件名加上辨识度（所有站点都叫
  /// playlist.m3u8 根本分不清）。下载时才能可靠拿到标题 —— 嗅探那一刻
  /// `onLoadStart` 刚触发，`getTitle()` 还是上一页的。
  DownloadTask enqueue(
    MediaItem item, {
    Map<String, String>? extraHeaders,
    List<MediaItem>? pool,
    String? pageTitle,
  }) {
    final DownloadTask? existing = _findByMedia(item.id);
    if (existing != null &&
        existing.status != DownloadStatus.canceled &&
        existing.status != DownloadStatus.failed) {
      return existing;
    }

    final DownloadTask task = _createTask(
      item,
      extraHeaders: extraHeaders,
      pageTitle: pageTitle,
    );
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
    _schedulePersist();
    _pump();
    return task;
  }

  DownloadTask _createTask(
    MediaItem item, {
    Map<String, String>? extraHeaders,
    String? pageTitle,
  }) {
    Map<String, String> headers = <String, String>{
      ...item.requestHeaders,
      ...?extraHeaders,
    };
    if (item.pageUrl != null &&
        !headers.keys.any((String k) => k.toLowerCase() == 'referer')) {
      headers['Referer'] = item.pageUrl!;
    }
    // 站点规则最后套：它优先级最高，专门覆盖自动那套搞不定的特例。
    final List<SiteRule>? rules = _siteRules?.call();
    if (rules != null && rules.isNotEmpty) {
      headers = applySiteRules(headers, item.url, rules);
    }

    final String fileName = fileNameWithPageTitle(
      item.fileName ?? _fallbackFileName(item.url, item.type),
      item.type,
      pageTitle,
    );

    return DownloadTask(
      id: HashUtil.md5Short(
        '${item.id}_${DateTime.now().microsecondsSinceEpoch}',
      ),
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

    final DownloadTask companion = _createTask(
      audio,
      extraHeaders: extraHeaders,
    );
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

    if (task.status.isRunningOrWaiting) {
      // 等待网络时 token 还在：取消要能打断那个最长一分钟的 sleep，
      // 否则用户点了取消，还得干等满一轮才变成「已取消」。
      _tokens[taskId]?.cancel('user');
    } else if (task.status == DownloadStatus.pending) {
      task.setStatus(DownloadStatus.canceled);
      _safeNotify();
      _schedulePersist();
    }
  }

  /// 暂停单条。运行中的取消请求，等待/排队中的直接改状态，都落到 paused。
  /// 和 [pauseAll] 共用同一套标记与 catch 分流。
  void pause(String taskId) {
    final DownloadTask? task = _findById(taskId);
    if (task == null) return;
    if (!task.status.isRunningOrWaiting && task.status != DownloadStatus.pending) {
      return;
    }
    _pausedIds.add(taskId);
    task.setStatus(DownloadStatus.paused);
    task.speed.value = 0;
    _tokens[taskId]?.cancel('pause');
    _safeNotify();
    _schedulePersist();
    _pushNotificationProgress(force: true);
  }

  /// 继续单条。只放这一条回 pending，其他 paused 的不动。
  void resume(String taskId) {
    final DownloadTask? task = _findById(taskId);
    if (task == null || task.status != DownloadStatus.paused) return;
    _pausedIds.remove(taskId);
    task.setStatus(DownloadStatus.pending);
    _safeNotify();
    _schedulePersist();
    _pump();
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
    // 重来一次可能配到上次还没出现的音频轨，结论要重新得出。
    task.mergedAudio = null;
    _pairRejected.remove(task.id);
    task.setStatus(DownloadStatus.pending);
    _safeNotify();
    _schedulePersist();
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
    _schedulePersist();
    // 分片临时目录不会自己消失：删了记录还留着就是纯占空间。
    unawaited(StoragePaths.cleanTemp(taskId));
  }

  void clearFinished() {
    final List<DownloadTask> finished = _tasks
        .where((DownloadTask t) => t.status.isFinished)
        .toList();
    for (final DownloadTask task in finished) {
      _tasks.remove(task);
      _forgetPairState(task);
      task.dispose();
      unawaited(StoragePaths.cleanTemp(task.id));
    }
    _safeNotify();
    _schedulePersist();
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
    _schedulePersist();
    return result;
  }

  /// 攒一批写：入队 → 开始 → 结束往往是连着几次状态变更，
  /// 每次都落盘会反复打开同一个文件。
  void _schedulePersist() {
    if (_store == null || _persistScheduled || _disposed) return;
    _persistScheduled = true;
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      _persistScheduled = false;
      if (_disposed) return;
      unawaited(_store.save(_tasks));
    });
  }

  void _pump() {
    if (_disposed) return;
    while (_runningCount < AppConstants.maxConcurrentDownloads) {
      final DownloadTask? next = _nextPending();
      if (next == null) break;
      unawaited(_start(next));
    }
    _syncForegroundService();
  }

  /// 有任务在跑就挂前台服务，跑完就撤。
  ///
  /// 放在 [_pump] 里而不是 `_start` 的 finally 里：调度是「一条结束立刻起下一条」，
  /// 在 finally 里撤会让下一轮又马上挂上，通知跟着闪一下。
  void _syncForegroundService() {
    if (_runningCount > 0) {
      unawaited(DownloadForegroundService.start());
    } else {
      unawaited(DownloadForegroundService.stop());
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
    // 把「下载中」也落盘：万一应用被系统杀掉，下次启动才知道这条是中断，
    // 而不是把它当成还没开始的 pending 又自动跑一遍。
    _schedulePersist();

    final CancelToken token = CancelToken();
    _tokens[task.id] = token;

    try {
      await _runWithNetworkRecovery(task, token);
    } on DownloadException catch (e) {
      if (token.isCancelled) {
        _settleCancel(task, token);
      } else {
        task.fail(e.toString());
      }
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        _settleCancel(task, token);
      } else {
        task.fail(e.message ?? '网络错误');
      }
    } catch (e) {
      if (token.isCancelled) {
        _settleCancel(task, token);
      } else {
        task.fail(e.toString());
      }
    } finally {
      _runningCount--;
      _tokens.remove(task.id);
      _safeNotify();
      _afterTaskSettled(task);
      _schedulePersist();
      // 这条不再算 running，通知栏要立刻反映（否则会停在最后采样的进度）。
      _pushNotificationProgress(force: true);
      _pump();
    }
  }

  /// 网络断了不放弃：置为「等待网络」，隔一会儿自己重来，直到成功或被取消。
  ///
  /// 为什么放在任务层而不是下载器里：只有这里能改状态、能在卡片上写「等待网络，
  /// 30 秒后重试」。藏在 IO 层里等，用户看到的是进度冻住、像卡死，和真的挂了
  /// 区分不开。
  ///
  /// 不设总时长上限：熄屏、进电梯、过隧道都可能是几分钟级，断在哪一秒不由我们
  /// 决定。用户随时能取消，卡片上也一直显示在等，不存在「悄悄挂死」。
  Future<void> _runWithNetworkRecovery(
    DownloadTask task,
    CancelToken token,
  ) async {
    int round = 0;
    while (true) {
      try {
        await _runOnce(task, token);
        return;
      } on DownloadException catch (e) {
        // 站点拒绝（403 / 404）、内容不对、已取消：等多久都不会变好，直接失败。
        if (!e.network || token.isCancelled) rethrow;

        final Duration wait = _networkWaitFor(round);
        round++;
        task.waitForNetwork(wait.inSeconds);
        _safeNotify();
        logWarn(
          'Download',
          '网络中断，${wait.inSeconds}s 后自动重试'
          '（第 $round 次）: ${task.fileName}',
        );

        await _sleepUnlessCancelled(wait, token);
        if (token.isCancelled) throw DownloadException('已取消');

        task.setStatus(DownloadStatus.running);
        _safeNotify();
      }
    }
  }

  Future<void> _runOnce(DownloadTask task, CancelToken token) async {
    if (task.type == MediaType.hls) {
      await _runHls(task, token);
    } else if (task.type == MediaType.dash) {
      await _runDash(task, token);
    } else {
      await _runFile(task, token);
    }
  }

  /// 断网后的第 [round] 次重试该等多久，超出表长就按最后一档。
  Duration _networkWaitFor(int round) {
    if (_networkWaits.isEmpty) return Duration.zero;
    final int index = round < _networkWaits.length
        ? round
        : _networkWaits.length - 1;
    return _networkWaits[index];
  }

  /// 可被取消打断的等待，否则点了取消还要干等满 60 秒。
  static Future<void> _sleepUnlessCancelled(
    Duration wait,
    CancelToken token,
  ) {
    return Future.any<void>(<Future<void>>[
      Future<void>.delayed(wait),
      token.whenCancel.then<void>((_) {}),
    ]);
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
      logInfo('Download', 'DASH 视频轨没找到配对的音频轨，将按单轨下载（无声）: ${task.fileName}');
      // 记下「确实没有音轨」，下载列表就不会对这个文件提供「转为 MP3」
      // —— 那条路径必然因为找不到音频流而失败。
      task.mergedAudio = false;
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
    final File out = File(
      p.join(StoragePaths.temp.path, '${video.id}.merge.mp4'),
    );
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
        _schedulePersist();
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
    final _SpeedSampler speed = _SpeedSampler(
      window: const Duration(milliseconds: 500),
      onSpeed: task.setSpeed,
    );

    await _downloader.download(
      url: task.url,
      target: target,
      headers: task.headers,
      cancelToken: token,
      // 落盘前做内容校验：URL 说 .mp4 不代表内容真是 mp4
      expectType: task.type,
      onProgress: (int received, int total) {
        task.updateBytes(received, total > 0 ? total : null);
        speed.sample(received);
        _pushNotificationProgress();
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
    final File rawOutput = File(
      p.join(StoragePaths.temp.path, '${task.id}.out'),
    );

    // 分片动辄几 MB，并发 6 路下 500ms 内经常一片都没落盘，
    // 所以窗口取 1 秒；续传首帧只做基线，不算速度。
    final _SpeedSampler speed = _SpeedSampler(
      window: const Duration(seconds: 1),
      onSpeed: task.setSpeed,
      skipFirstFrame: true,
    );

    final HlsDownloadResult result = await _hls.download(
      playlistUrl: task.url,
      workDir: workDir,
      output: rawOutput,
      headers: task.headers,
      userCancelToken: token,
      onProgress: (HlsProgress progress) {
        task.updateSegments(
          progress.done,
          progress.total,
          bytes: progress.bytes,
        );
        speed.sample(progress.bytes);
        _pushNotificationProgress();
      },
    );

    final String baseName = p.basenameWithoutExtension(task.fileName);
    final File target = StoragePaths.uniqueFile(
      '$baseName.${result.container}',
    );
    if (await target.exists()) {
      await target.delete();
    }
    await result.file.rename(target.path);

    task.needsRemux = result.needsRemux;
    task.complete(target.path, containerExt: result.container);
  }

  Future<void> _runDash(DownloadTask task, CancelToken token) async {
    final Directory workDir = StoragePaths.tempDirFor(task.id);
    // 输出放在 workDir 之外：下载器成功后会删掉整个 workDir。
    final File rawVideo = File(
      p.join(StoragePaths.temp.path, '${task.id}.dash.out'),
    );
    final File rawAudio = File(
      p.join(StoragePaths.temp.path, '${task.id}.dash.audio.out'),
    );

    final _SpeedSampler speed = _SpeedSampler(
      window: const Duration(seconds: 1),
      onSpeed: task.setSpeed,
      skipFirstFrame: true,
    );

    final DashDownloadResult result = await _dash.download(
      manifestUrl: task.url,
      workDir: workDir,
      output: rawVideo,
      audioOutput: rawAudio,
      headers: task.headers,
      userCancelToken: token,
      onProgress: (DashProgress progress) {
        task.updateSegments(
          progress.done,
          progress.total,
          bytes: progress.bytes,
        );
        speed.sample(progress.bytes);
        _pushNotificationProgress();
      },
    );

    final String baseName = p.basenameWithoutExtension(task.fileName);
    final File target = StoragePaths.uniqueFile(
      '$baseName.${result.container}',
    );
    if (await target.exists()) {
      await target.delete();
    }
    await result.file.rename(target.path);

    task.complete(target.path, containerExt: result.container);
    task.mergedAudio = result.hasAudio ? false : null;
    if (result.audioError != null) {
      logWarn('Download', '${task.fileName} 的音轨没下成：${result.audioError}');
    }

    if (result.audioFile != null) {
      _scheduleDashMerge(
        task,
        videoPath: target.path,
        audioPath: result.audioFile!.path,
      );
    }
  }

  /// MPD 下载产生的两条轨合并。和嗅探分片那套 [_scheduleMerge] 的区别是
  /// 这里没有单独的音轨任务，音频文件由 DashDownloader 直接产出。
  void _scheduleDashMerge(
    DownloadTask task, {
    required String videoPath,
    required String audioPath,
  }) {
    final TranscodeQueue? transcoder = _transcoder;
    if (transcoder == null) return;
    final File out = File(
      p.join(StoragePaths.temp.path, '${task.id}.dash.merge.mp4'),
    );
    logInfo('Download', 'DASH 音视频都已就绪，开始合并: ${task.fileName}');

    transcoder.enqueue(
      sourcePath: videoPath,
      secondarySourcePath: audioPath,
      kind: TranscodeKind.dashMerge,
      sourceTaskId: task.id,
      displayName: task.fileName,
      outputPath: out.path,
      replaceSource: true,
      onFinished: (TranscodeStatus status) {
        if (_disposed) return;
        final bool ok = status == TranscodeStatus.completed;
        task.mergedAudio = ok;
        if (ok) {
          task.container = 'mp4';
          task.needsRemux = false;
        } else {
          logWarn('Download', 'DASH 合并失败（${status.label}），保留无声视频');
        }
        _safeNotify();
        _schedulePersist();
      },
    );
  }

  /// HLS / DASH 清单文件名带上来源页标题：`playlist.m3u8` → `playlist_某某视频.m3u8`。
  ///
  /// 只处理清单 —— 图片/音频/普通视频的文件名本身通常就有辨识度，
  /// 而 m3u8 / mpd 几乎每个站都叫 playlist / index / manifest，
  /// 不加来源根本分不清。
  @visibleForTesting
  static String fileNameWithPageTitle(
    String fileName,
    MediaType type,
    String? pageTitle,
  ) {
    final String title = pageTitle?.trim() ?? '';
    if ((type != MediaType.hls && type != MediaType.dash) || title.isEmpty) {
      return fileName;
    }
    final String ext = p.extension(fileName);
    final String base = p.basenameWithoutExtension(fileName);
    return StoragePaths.sanitizeFileName('${base}_$title$ext');
  }

  String _fallbackFileName(String url, MediaType type) {
    final Uri? uri = Uri.tryParse(url);
    final String guessed = (uri != null && uri.pathSegments.isNotEmpty)
        ? uri.pathSegments.last
        : '';
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
    // 任务 settle 之后不会再把 _pump 跑起来（_disposed 拦住了），
    // 前台服务只能在这里撤，否则会留一条永远不消失的通知。
    unawaited(DownloadForegroundService.stop());
    for (final DownloadTask task in _tasks) {
      task.dispose();
    }
    _tasks.clear();
    super.dispose();
  }
}

/// 用累计字节做差算瞬时速度，不用「总量 / 总时间」——后者会把起步阶段
/// 算得虚高。分片下载要 [skipFirstFrame]：续传首帧带的是旧分片字节，
/// 从 0 开始算会冒出几 GB/s 的假速度。
class _SpeedSampler {
  _SpeedSampler({
    required this.window,
    required this.onSpeed,
    this.skipFirstFrame = false,
  });

  final Duration window;
  final void Function(double bytesPerSecond) onSpeed;
  final bool skipFirstFrame;

  final Stopwatch _stopwatch = Stopwatch()..start();
  int _lastMs = 0;
  int _lastBytes = 0;
  late bool _first = skipFirstFrame;

  void sample(int bytes) {
    final int elapsed = _stopwatch.elapsedMilliseconds;
    if (_first) {
      _first = false;
      _lastMs = elapsed;
      _lastBytes = bytes;
      return;
    }
    if (elapsed - _lastMs < window.inMilliseconds) return;
    final double seconds = (elapsed - _lastMs) / 1000;
    if (seconds > 0) onSpeed((bytes - _lastBytes) / seconds);
    _lastMs = elapsed;
    _lastBytes = bytes;
  }
}
