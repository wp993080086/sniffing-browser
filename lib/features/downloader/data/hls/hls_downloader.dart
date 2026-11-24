import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../../../core/constants/app_constants.dart';
import '../../../../core/logging/app_log.dart';
import '../file_downloader.dart';
import '../segment_writer.dart';
import 'aes_decryptor.dart';
import 'm3u8_models.dart';
import 'm3u8_parser.dart';
import 'segment_merger.dart';

class HlsProgress {
  const HlsProgress({required this.done, required this.total, this.bytes = 0});

  final int done;
  final int total;

  /// 当前已落盘的累计字节数，命中 `.part` 的分片也计入（估算总大小要用）。
  /// 速度由队列以首帧为基线，不会因为续传瞬间多出旧分片而虚高。
  final int bytes;

  double get fraction => total <= 0 ? 0 : (done / total).clamp(0.0, 1.0);
}

class HlsDownloadResult {
  const HlsDownloadResult({
    required this.file,
    required this.container,
    required this.isFmp4,
    this.variantLabel,
  });

  final File file;

  /// `ts` 或 `mp4`。
  final String container;

  /// fMP4 分片拼出来就是标准 mp4，不需要再转封装。
  final bool isFmp4;

  final String? variantLabel;

  bool get needsRemux => !isFmp4;
}

/// HLS 下载器。
///
/// 流程：拉 playlist → 选码率 → 逐片下载 → AES-128 解密 → 二进制合并。
/// 不做 TS→MP4 转封装，那是 TranscodeQueue 的事。
class HlsDownloader {
  HlsDownloader({
    FileDownloader? downloader,
    this.parser = const M3u8Parser(),
    int Function()? segmentConcurrency,
  }) : _downloader = downloader ?? FileDownloader(),
       _segmentConcurrency = segmentConcurrency;

  final FileDownloader _downloader;
  final M3u8Parser parser;

  /// 分片并发数，取设置页里的值。用回调而不是固定值：改完设置不用重建下载器。
  final int Function()? _segmentConcurrency;

  /// 已下载的密钥，按 URL 缓存。同一路流的几百个分片共用一个 key。
  final Map<String, Uint8List> _keyCache = <String, Uint8List>{};

  Future<HlsDownloadResult> download({
    required String playlistUrl,
    required Directory workDir,
    required File output,
    Map<String, String> headers = const <String, String>{},
    CancelToken? userCancelToken,
    void Function(HlsProgress progress)? onProgress,
    String? preferredVariantUri,
  }) async {
    await workDir.create(recursive: true);

    // 内部 token：用户取消要能穿透，分片失败时也要能中断其余 worker。
    final CancelToken internal = CancelToken();
    userCancelToken?.whenCancel.then((_) {
      if (!internal.isCancelled) internal.cancel('user canceled');
    });

    final ({M3u8Playlist playlist, String? variantLabel}) loaded =
        await _loadPlaylist(
          playlistUrl,
          headers,
          internal,
          preferredVariantUri: preferredVariantUri,
        );
    final M3u8Playlist playlist = loaded.playlist;

    if (playlist.segments.isEmpty) {
      throw M3u8ParseException('playlist 里没有分片，可能是 live 流的空窗口');
    }

    // SAMPLE-AES 需要完整解密器，提前失败比下完几百片再报错好。
    for (final M3u8Segment segment in playlist.segments) {
      if (segment.key != null && segment.key!.isSampleAes) {
        throw UnsupportedError('该流使用 SAMPLE-AES 加密，无法解密');
      }
    }

    // 1. 初始化段（fMP4 必需，必须排在合并结果最前面）
    File? initFile;
    if (playlist.initSegmentUrl != null) {
      initFile = File(p.join(workDir.path, 'init.part'));
      if (!await initFile.exists() || await initFile.length() == 0) {
        final List<int> bytes = await _downloader.fetchBytes(
          url: playlist.initSegmentUrl!,
          headers: headers,
          cancelToken: internal,
        );
        await initFile.writeAsBytes(bytes, flush: true);
      }
    }

    // 2. 并发下载分片
    final int total = playlist.segments.length;
    int nextIndex = 0;
    int done = 0;
    int fetchedBytes = 0;
    Object? firstError;

    Future<void> worker() async {
      while (true) {
        if (firstError != null || internal.isCancelled) return;
        if (nextIndex >= total) return;
        final int index = nextIndex++;
        try {
          final int written = await _prepareSegment(
            index: index,
            segment: playlist.segments[index],
            workDir: workDir,
            headers: headers,
            cancelToken: internal,
          );
          done++;
          fetchedBytes += written;
          onProgress?.call(
            HlsProgress(done: done, total: total, bytes: fetchedBytes),
          );
        } catch (e) {
          if (firstError == null) {
            firstError = e;
            // 分片序号是排查「为什么这条任务总断」的关键：断在固定位置
            // 说明是站点对某个分片限流，随机位置说明是线路或系统回收连接。
            final String detail = e is DownloadException ? e.message : '$e';
            logWarn('Download', '第 ${index + 1}/$total 个分片失败: $detail');
            if (!internal.isCancelled) internal.cancel('segment failed');
          }
          return;
        }
      }
    }

    // 并发数来自设置页。下限兜到 1：0 会让 Future.wait 空跑，整个任务卡死。
    final int limit =
        _segmentConcurrency?.call() ?? AppConstants.maxConcurrentSegments;
    final int concurrency = limit < 1 ? 1 : (total < limit ? total : limit);
    await Future.wait(<Future<void>>[
      for (int i = 0; i < concurrency; i++) worker(),
    ]);

    if (firstError != null) {
      throw firstError!;
    }
    if (userCancelToken?.isCancelled ?? false) {
      throw DownloadException('已取消');
    }

    // 3. 合并
    final List<File> parts = <File>[
      for (int i = 0; i < total; i++) File(p.join(workDir.path, 'seg_$i.part')),
    ];
    // 缺片会让输出文件静默变短（能播但内容缺失），提前拦掉。
    for (int i = 0; i < parts.length; i++) {
      if (!await parts[i].exists() || await parts[i].length() == 0) {
        throw DownloadException('第 $i 个分片缺失，请重试');
      }
    }

    await SegmentMerger.merge(
      segments: parts,
      output: output,
      initSegment: initFile,
    );

    // 成功后清理临时目录；失败时保留，下次续传用。
    try {
      await workDir.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响结果
    }

    return HlsDownloadResult(
      file: output,
      container: playlist.containerExtension,
      isFmp4: playlist.isFmp4,
      variantLabel: loaded.variantLabel,
    );
  }

  /// 探一次 master playlist：可选的清晰度（变体）与字幕轨。
  ///
  /// 一次请求同时给出两类选项，避免「列清晰度」和「列字幕」各拉一遍清单。
  /// 不是 master（没有变体）时两者都是空。
  Future<({List<M3u8Variant> variants, List<M3u8Media> subtitles})> probe({
    required String playlistUrl,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final String text = await _downloader.fetchString(
      url: playlistUrl,
      headers: headers,
    );
    if (!text.trimLeft().startsWith('#EXTM3U')) {
      return (variants: const <M3u8Variant>[], subtitles: const <M3u8Media>[]);
    }
    final M3u8Playlist playlist = parser.parse(text, Uri.parse(playlistUrl));
    return (
      variants: playlist.variants,
      // 没有 URI 的字幕轨（EXT-X-MEDIA 允许省略，表示在子 playlist 里）下不了。
      subtitles: playlist.media
          .where((M3u8Media m) => m.isSubtitle && m.uri != null)
          .toList(),
    );
  }

  /// 下载一条字幕 playlist，输出 `.vtt` 文件。
  ///
  /// 复用普通分片下载：字幕 playlist 的分片本身就是 `WEBVTT` 文本，按顺序
  /// 二进制拼接就是合法的 vtt。不校验内容，坏文本交给播放器判断。
  Future<File> downloadSubtitle({
    required String playlistUrl,
    required Directory workDir,
    required File output,
    Map<String, String> headers = const <String, String>{},
    CancelToken? userCancelToken,
  }) async {
    final HlsDownloadResult result = await download(
      playlistUrl: playlistUrl,
      workDir: workDir,
      output: output,
      headers: headers,
      userCancelToken: userCancelToken,
    );
    return result.file;
  }

  Future<({M3u8Playlist playlist, String? variantLabel})> _loadPlaylist(
    String url,
    Map<String, String> headers,
    CancelToken cancelToken, {
    String? preferredVariantUri,
  }) async {
    final String text = await _downloader.fetchString(
      url: url,
      headers: headers,
      cancelToken: cancelToken,
    );
    // 有的站点会把不存在的 m3u8 兜底成首页 HTML。直接交给 parser 也行，
    // 但报出来只会是"没有分片"，定位不到真正原因。
    if (!text.trimLeft().startsWith('#EXTM3U')) {
      final String preview = text.trimLeft().replaceAll(RegExp(r'\s+'), ' ');
      throw DownloadException(
        '该地址返回的不是 m3u8（开头是“${_clip(preview)}”），'
        '站点可能返回了错误页或要求登录',
        url: url,
      );
    }
    M3u8Playlist playlist = parser.parse(text, Uri.parse(url));
    String? variantLabel;

    if (playlist.isMaster) {
      M3u8Variant? chosen;
      if (preferredVariantUri != null) {
        for (final M3u8Variant variant in playlist.variants) {
          if (variant.uri.toString() == preferredVariantUri) {
            chosen = variant;
            break;
          }
        }
      }
      // 用户选的变体可能已经不在清单里（站点重排了清晰度），退回自动挑最好的，
      // 而不是让整个任务失败。
      chosen ??= parser.pickBestVariant(playlist);
      variantLabel = chosen.label;
      final String childText = await _downloader.fetchString(
        url: chosen.uri.toString(),
        headers: headers,
        cancelToken: cancelToken,
      );
      playlist = parser.parse(childText, chosen.uri);
    }

    if (playlist.segments.isEmpty && !playlist.isMaster) {
      throw M3u8ParseException('子 playlist 里没有分片');
    }

    return (playlist: playlist, variantLabel: variantLabel);
  }

  /// 下载 + 解密单个分片，返回它当前落盘的字节数。
  ///
  /// `.part` 已存在且非空就直接跳过 —— 文件在就是完成，比记录已完成序号可靠。
  /// 命中缓存时也返回已有字节供总大小估算；速度由队列以首帧为基线，
  /// 不会因为续传瞬间多出一批旧分片而虚高。
  Future<int> _prepareSegment({
    required int index,
    required M3u8Segment segment,
    required Directory workDir,
    required Map<String, String> headers,
    required CancelToken cancelToken,
  }) async {
    final File partFile = File(p.join(workDir.path, 'seg_$index.part'));
    if (await partFile.exists()) {
      final int cached = await partFile.length();
      if (cached > 0) return cached;
    }

    final Map<String, String> segmentHeaders = Map<String, String>.from(
      headers,
    );
    final M3u8ByteRange? range = segment.byteRange;
    if (range != null) {
      final int start = range.offset ?? 0;
      segmentHeaders['Range'] = 'bytes=$start-${start + range.length - 1}';
    }

    final List<int> raw = await _downloader.fetchBytes(
      url: segment.uri.toString(),
      headers: segmentHeaders,
      cancelToken: cancelToken,
      // 分片小，重试成本远低于让整条任务失败重来。
      retries: AppConstants.segmentRetryCount,
    );

    final M3u8Key? key = segment.key;
    List<int> plain = raw;
    if (key != null && key.isAes128) {
      final Uint8List keyBytes = await _loadKey(key, headers, cancelToken);
      final Uint8List iv = key.iv != null
          ? Uint8List.fromList(key.iv!)
          : AesDecryptor.ivFromSequence(segment.sequence);
      plain = AesDecryptor.decrypt(
        data: Uint8List.fromList(raw),
        key: keyBytes,
        iv: iv,
      );
    }

    await writeSegmentAtomically(partFile, plain);
    return plain.length;
  }

  Future<Uint8List> _loadKey(
    M3u8Key key,
    Map<String, String> headers,
    CancelToken cancelToken,
  ) async {
    final Uri? uri = key.uri;
    if (uri == null) {
      throw M3u8ParseException('AES-128 缺少密钥 URI');
    }
    final String cacheKey = uri.toString();
    final Uint8List? cached = _keyCache[cacheKey];
    if (cached != null) return cached;

    final List<int> bytes = await _downloader.fetchBytes(
      url: cacheKey,
      headers: headers,
      cancelToken: cancelToken,
    );
    if (bytes.length != 16) {
      throw M3u8ParseException('密钥长度应为 16 字节，实际 ${bytes.length}');
    }
    final Uint8List result = Uint8List.fromList(bytes);
    _keyCache[cacheKey] = result;
    return result;
  }
}

/// 把响应内容截成一小段，塞进错误信息里给用户看开头是什么。
String _clip(String text, [int max = 60]) =>
    text.length <= max ? text : '${text.substring(0, max)}…';
