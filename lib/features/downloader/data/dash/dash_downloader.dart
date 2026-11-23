import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../../../core/constants/app_constants.dart';
import '../../../../core/logging/app_log.dart';
import '../file_downloader.dart';
import '../hls/segment_merger.dart';
import '../segment_writer.dart';
import 'mpd_models.dart';
import 'mpd_parser.dart';

class DashProgress {
  const DashProgress({required this.done, required this.total, this.bytes = 0});

  final int done;
  final int total;

  /// 当前已落盘的累计字节数，命中 `.part` 的分片也计入（估算总大小要用）。
  /// 速度由队列以首帧为基线，不会因为续传瞬间多出旧分片而虚高。
  final int bytes;

  double get fraction => total <= 0 ? 0 : (done / total).clamp(0.0, 1.0);
}

class DashDownloadResult {
  const DashDownloadResult({
    required this.file,
    required this.container,
    required this.hasAudio,
    this.audioFile,
    this.audioError,
    this.variantLabel,
  });

  final File file;
  final String container;

  /// MPD 里确实列了音频轨（即使下载失败也算有）。
  final bool hasAudio;

  /// 音频轨成功落盘时才非空，交给下载队列走 dashMerge。
  final File? audioFile;

  /// 音频轨失败的原因。视频照常交付，只是没声音。
  final String? audioError;
  final String? variantLabel;

  bool get needsMerge => audioFile != null;

  /// fMP4 分片拼接后就是标准 mp4，不需要转封装。
  bool get needsRemux => false;
}

class _DashTrackPlan {
  const _DashTrackPlan({
    required this.id,
    required this.baseUri,
    required this.bandwidth,
    required this.initUrl,
    required this.segmentUrls,
    required this.isAudio,
  });

  final String id;
  final Uri baseUri;
  final int? bandwidth;
  final Uri? initUrl;
  final List<Uri> segmentUrls;
  final bool isAudio;
}

class _SegmentJob {
  const _SegmentJob(this.track, this.index, this.uri);

  final int track;
  final int index;
  final Uri uri;
}

/// DASH 点播流下载。
///
/// MPD → 选码率 → 展开 `$Number$`/`$Time$` 分片地址 → 并发下载 `.m4s`
/// → init 段 + 分片二进制拼接。音视频是两条独立轨，各自拼成 mp4 后
/// 由下载队列用 FFmpeg `-c copy` 合成为最终文件（复用 dashMerge）。
class DashDownloader {
  DashDownloader({
    FileDownloader? downloader,
    MpdParser? parser,
    int Function()? segmentConcurrency,
  })  : _downloader = downloader ?? FileDownloader(),
        _parser = parser ?? const MpdParser(),
        _segmentConcurrency = segmentConcurrency;

  final FileDownloader _downloader;
  final MpdParser _parser;
  final int Function()? _segmentConcurrency;

  /// 防住写错 duration 的 MPD 一次生成几十万个任务把内存打爆。
  static const int maxSegments = 20000;

  Future<DashDownloadResult> download({
    required String manifestUrl,
    required Directory workDir,
    required File output,
    File? audioOutput,
    Map<String, String> headers = const <String, String>{},
    CancelToken? userCancelToken,
    void Function(DashProgress progress)? onProgress,
  }) async {
    await workDir.create(recursive: true);

    final CancelToken internal = CancelToken();
    userCancelToken?.whenCancel.then((_) {
      if (!internal.isCancelled) internal.cancel('user canceled');
    });

    final String text = await _downloader.fetchString(
      url: manifestUrl,
      headers: headers,
      cancelToken: internal,
    );
    final Uri manifestUri = Uri.parse(manifestUrl);
    final MpdManifest manifest = _parser.parse(text, baseUri: manifestUri);
    if (manifest.isDynamic &&
        manifest.periods.every((MpdPeriod p) => p.duration == null)) {
      throw const MpdParseException(
        '这是直播 DASH 流，没有固定分片数，无法完整下载',
      );
    }

    final MpdSelectedTracks selected = _parser.selectTracks(manifest);
    final List<_DashTrackPlan> plans = <_DashTrackPlan>[];
    if (selected.video != null) plans.add(_planFor(selected.video!));
    // 纯音轨清单没有视频轨，音轨就落在 index 0，不能把「音轨」写死成 1。
    final int? audioTrack = selected.audio == null ? null : plans.length;
    if (selected.audio != null) plans.add(_planFor(selected.audio!));

    for (final _DashTrackPlan plan in plans) {
      if (plan.segmentUrls.isEmpty) {
        throw MpdParseException('轨道 ${plan.id} 展开后没有分片');
      }
    }

    // 1. 初始化段。必须在合并结果最前面，且两条轨各有自己的 init。
    final List<File?> initFiles = <File?>[];
    for (int t = 0; t < plans.length; t++) {
      final Directory dir = Directory(p.join(workDir.path, 't$t'));
      await dir.create(recursive: true);
      final Uri? initUrl = plans[t].initUrl;
      if (initUrl == null) {
        initFiles.add(null);
        continue;
      }
      final File init = File(p.join(dir.path, 'init.part'));
      if (!await init.exists() || await init.length() == 0) {
        final List<int> bytes = await _downloader.fetchBytes(
          url: initUrl.toString(),
          headers: headers,
          cancelToken: internal,
        );
        await writeSegmentAtomically(init, bytes);
      }
      initFiles.add(init);
    }

    // 2. 并发下载分片。音视频放在同一个池子里，避免一条轨把并发占满。
    final List<_SegmentJob> jobs = <_SegmentJob>[];
    for (int t = 0; t < plans.length; t++) {
      final List<Uri> urls = plans[t].segmentUrls;
      for (int i = 0; i < urls.length; i++) {
        jobs.add(_SegmentJob(t, i, urls[i]));
      }
    }
    final int total = jobs.length;
    int next = 0;
    int done = 0;
    int fetchedBytes = 0;
    Object? videoError;
    Object? audioError;
    bool audioFailed = false;

    Future<void> worker() async {
      while (true) {
        if (internal.isCancelled || videoError != null) return;
        if (next >= total) return;
        final _SegmentJob job = jobs[next++];
        // 音轨出错就跳过剩下的音频分片：无声总比整个视频下不成好。
        if (audioTrack != null && job.track == audioTrack && audioFailed) {
          continue;
        }

        try {
          final int written = await _prepareSegment(
            job: job,
            workDir: workDir,
            headers: headers,
            token: internal,
          );
          done++;
          fetchedBytes += written;
          onProgress?.call(
            DashProgress(done: done, total: total, bytes: fetchedBytes),
          );
        } catch (e) {
          if (internal.isCancelled ||
              (userCancelToken?.isCancelled ?? false)) {
            videoError ??= e;
            return;
          }
          if (audioTrack != null && job.track == audioTrack) {
            audioFailed = true;
            audioError ??= e;
            if (selected.video == null) {
              // 纯音轨流没有视频可退，音轨坏了就是整个任务失败。
              videoError ??= e;
              if (!internal.isCancelled) internal.cancel('audio failed');
              return;
            }
            logWarn(
              'Download',
              'DASH 音轨分片 ${job.index + 1} 失败，将只交付视频轨: $e',
            );
          } else {
            videoError ??= e;
            final String detail = e is DownloadException ? e.message : '$e';
            logWarn('Download', 'DASH 分片 ${job.index + 1}/$total 失败: $detail');
            if (!internal.isCancelled) internal.cancel('segment failed');
            return;
          }
        }
      }
    }

    final int limit =
        _segmentConcurrency?.call() ?? AppConstants.maxConcurrentSegments;
    // 下限兜到 1：0 会让 Future.wait 空跑，整个任务卡死。
    final int concurrency = limit < 1 ? 1 : (total < limit ? total : limit);
    await Future.wait<void>(
      <Future<void>>[for (int i = 0; i < concurrency; i++) worker()],
    );

    if (videoError != null) throw videoError!;
    if (userCancelToken?.isCancelled ?? false) {
      throw DownloadException('已取消');
    }

    // 3. 主轨拼接：有视频时是视频，纯音轨清单时就是音轨本身。
    //    失败就是整个任务失败。
    await SegmentMerger.merge(
      segments: _parts(workDir, 0, plans[0].segmentUrls.length),
      output: output,
      initSegment: initFiles.isEmpty ? null : initFiles[0],
    );

    File? audioFile;
    String? mergeError;
    if (!audioFailed && plans.length == 2 && audioOutput != null) {
      try {
        await SegmentMerger.merge(
          segments: _parts(workDir, 1, plans[1].segmentUrls.length),
          output: audioOutput,
          initSegment: initFiles.length > 1 ? initFiles[1] : null,
        );
        audioFile = audioOutput;
      } catch (e) {
        mergeError = '$e';
        logWarn('Download', 'DASH 音轨拼接失败，将只交付视频轨: $e');
      }
    }

    // 音频失败时进度停在一个不完整的值，补到 100% 免得 UI 一直转圈。
    if (audioFailed || mergeError != null) {
      onProgress?.call(DashProgress(done: total, total: total, bytes: fetchedBytes));
    }

    try {
      await workDir.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响交付：下一次下载会用新 id 建目录，
      // 这批残留交给存储管理页清理即可。
    }

    return DashDownloadResult(
      file: output,
      container: selected.video == null ? 'm4a' : 'mp4',
      hasAudio: selected.audio != null,
      audioFile: audioFile,
      audioError: audioError == null ? mergeError : '$audioError',
      variantLabel: selected.video?.label,
    );
  }

  /// 把一条 Representation 展开成 init + 分片 URL 列表。
  _DashTrackPlan _planFor(MpdSelectedTrack track) {
    final MpdSegmentInfo info = track.segment;
    if (info.hasSegmentBase) {
      throw UnsupportedError(
        '这个 DASH 流用 SegmentBase 单文件封装，需要按字节区间取片段，暂不支持',
      );
    }

    final String? media;
    String? init;
    final int startNumber;
    List<({int number, int time})> addresses = <({int number, int time})>[];

    if (info.list != null && info.list!.media.isNotEmpty) {
      media = null;
      init = info.list!.initialization;
      startNumber = 1;
      for (int i = 0; i < info.list!.media.length; i++) {
        addresses.add((number: startNumber + i, time: 0));
      }
    } else {
      final MpdSegmentTemplate? template = info.template;
      if (template == null || template.media == null) {
        throw MpdParseException(
          'Representation ${track.id} 没有可下载的分片地址',
        );
      }
      media = template.media;
      init = template.initialization;
      startNumber = template.startNumber;
      final int timescale = template.timescale > 0 ? template.timescale : 1;

      if (template.timeline.isNotEmpty) {
        int cursor = 0;
        int number = startNumber;
        for (final MpdTimelineEntry entry in template.timeline) {
          if (entry.r == -1) {
            throw UnsupportedError(
              '直播 DASH 流（SegmentTimeline 无界重复）无法完整下载',
            );
          }
          final int start = entry.t ?? cursor;
          final int repeats = entry.r < 0 ? 0 : entry.r;
          for (int k = 0; k <= repeats; k++) {
            if (addresses.length >= maxSegments) {
              throw MpdParseException('MPD 展开出超过 $maxSegments 个分片，疑似数据异常');
            }
            addresses.add((number: number++, time: start + k * entry.d));
          }
          cursor = start + (repeats + 1) * entry.d;
        }
      } else if (template.duration != null &&
          template.duration! > 0 &&
          track.periodDuration != null) {
        final double units =
            track.periodDuration!.inMicroseconds * timescale / 1000000.0;
        final int count = (units / template.duration!).ceil();
        if (count > maxSegments) {
          throw MpdParseException('MPD 展开出 $count 个分片，超过 $maxSegments 上限');
        }
        for (int i = 0; i < count; i++) {
          addresses.add((
            number: startNumber + i,
            time: i * template.duration!,
          ));
        }
      } else {
        throw const MpdParseException(
          '无法确定 DASH 分片数量：MPD 既没有时长也没有 SegmentTimeline',
        );
      }
    }

    final List<Uri> urls = <Uri>[];
    for (final ({int number, int time}) address in addresses) {
      final String source = info.list == null
          ? media!
          : info.list!.media[address.number - startNumber];
      final String expanded = _parser.expandTemplate(
        source,
        representationId: track.id,
        number: address.number,
        time: address.time,
        bandwidth: track.bandwidth,
      );
      urls.add(track.baseUri.resolve(expanded));
    }

    Uri? initUrl;
    if (init != null && init.isNotEmpty) {
      final String expanded = _parser.expandTemplate(
        init,
        representationId: track.id,
        number: startNumber,
        time: 0,
        bandwidth: track.bandwidth,
      );
      initUrl = track.baseUri.resolve(expanded);
    }

    return _DashTrackPlan(
      id: track.id,
      baseUri: track.baseUri,
      bandwidth: track.bandwidth,
      initUrl: initUrl,
      segmentUrls: urls,
      isAudio: track.kind == DashTrackKind.audio,
    );
  }

  static List<File> _parts(Directory workDir, int track, int count) {
    return <File>[
      for (int i = 0; i < count; i++)
        File(p.join(workDir.path, 't$track', 'seg_$i.part')),
    ];
  }

  /// 命中已有分片就跳过，返回它已落盘的字节数供总大小估算。
  /// 速度由调用方用首帧做基线，不会因为续传瞬间多出一批旧分片而虚高。
  Future<int> _prepareSegment({
    required _SegmentJob job,
    required Directory workDir,
    required Map<String, String> headers,
    required CancelToken token,
  }) async {
    final File part = File(
      p.join(workDir.path, 't${job.track}', 'seg_${job.index}.part'),
    );
    if (await part.exists()) {
      final int cached = await part.length();
      if (cached > 0) return cached;
    }
    final List<int> bytes = await _downloader.fetchBytes(
      url: job.uri.toString(),
      headers: headers,
      cancelToken: token,
    );
    await writeSegmentAtomically(part, bytes);
    return bytes.length;
  }
}
