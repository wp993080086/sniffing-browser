import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../../../core/constants/app_constants.dart';
import '../file_downloader.dart';
import 'aes_decryptor.dart';
import 'm3u8_models.dart';
import 'm3u8_parser.dart';
import 'segment_merger.dart';

class HlsProgress {
  const HlsProgress({required this.done, required this.total});

  final int done;
  final int total;

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
  HlsDownloader({FileDownloader? downloader, this.parser = const M3u8Parser()})
      : _downloader = downloader ?? FileDownloader();

  final FileDownloader _downloader;
  final M3u8Parser parser;

  /// 已下载的密钥，按 URL 缓存。同一路流的几百个分片共用一个 key。
  final Map<String, Uint8List> _keyCache = <String, Uint8List>{};

  Future<HlsDownloadResult> download({
    required String playlistUrl,
    required Directory workDir,
    required File output,
    Map<String, String> headers = const <String, String>{},
    CancelToken? userCancelToken,
    void Function(HlsProgress progress)? onProgress,
  }) async {
    await workDir.create(recursive: true);

    // 内部 token：用户取消要能穿透，分片失败时也要能中断其余 worker。
    final CancelToken internal = CancelToken();
    userCancelToken?.whenCancel.then((_) {
      if (!internal.isCancelled) internal.cancel('user canceled');
    });

    final ({M3u8Playlist playlist, String? variantLabel}) loaded =
        await _loadPlaylist(playlistUrl, headers, internal);
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
    Object? firstError;

    Future<void> worker() async {
      while (true) {
        if (firstError != null || internal.isCancelled) return;
        if (nextIndex >= total) return;
        final int index = nextIndex++;
        try {
          await _prepareSegment(
            index: index,
            segment: playlist.segments[index],
            workDir: workDir,
            headers: headers,
            cancelToken: internal,
          );
          done++;
          onProgress?.call(HlsProgress(done: done, total: total));
        } catch (e) {
          if (firstError == null) {
            firstError = e;
            if (!internal.isCancelled) internal.cancel('segment failed');
          }
          return;
        }
      }
    }

    final int concurrency =
        total < AppConstants.maxConcurrentSegments ? total : AppConstants.maxConcurrentSegments;
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

  Future<({M3u8Playlist playlist, String? variantLabel})> _loadPlaylist(
    String url,
    Map<String, String> headers,
    CancelToken cancelToken,
  ) async {
    final String text = await _downloader.fetchString(
      url: url,
      headers: headers,
      cancelToken: cancelToken,
    );
    M3u8Playlist playlist = parser.parse(text, Uri.parse(url));
    String? variantLabel;

    if (playlist.isMaster) {
      final M3u8Variant best = parser.pickBestVariant(playlist);
      variantLabel = best.label;
      final String childText = await _downloader.fetchString(
        url: best.uri.toString(),
        headers: headers,
        cancelToken: cancelToken,
      );
      playlist = parser.parse(childText, best.uri);
    }

    if (playlist.segments.isEmpty && !playlist.isMaster) {
      throw M3u8ParseException('子 playlist 里没有分片');
    }

    return (playlist: playlist, variantLabel: variantLabel);
  }

  /// 下载 + 解密单个分片，产出 `seg_<index>.part`。
  ///
  /// 支持分片级断点续传：`.part` 已存在且非空就直接跳过。
  /// 这比记录“已完成序号列表”可靠 —— 文件在就是完成，文件不在就重下。
  Future<void> _prepareSegment({
    required int index,
    required M3u8Segment segment,
    required Directory workDir,
    required Map<String, String> headers,
    required CancelToken cancelToken,
  }) async {
    final File partFile = File(p.join(workDir.path, 'seg_$index.part'));
    if (await partFile.exists() && await partFile.length() > 0) {
      return;
    }

    final Map<String, String> segmentHeaders = Map<String, String>.from(headers);
    final M3u8ByteRange? range = segment.byteRange;
    if (range != null) {
      final int start = range.offset ?? 0;
      segmentHeaders['Range'] = 'bytes=$start-${start + range.length - 1}';
    }

    final List<int> raw = await _downloader.fetchBytes(
      url: segment.uri.toString(),
      headers: segmentHeaders,
      cancelToken: cancelToken,
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

    await partFile.writeAsBytes(plain, flush: true);
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
