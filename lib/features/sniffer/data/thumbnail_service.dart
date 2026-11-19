import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import '../../../core/logging/app_log.dart';
import '../../../core/platform/platform_info.dart';
import '../../../core/utils/serial_gate.dart';
import '../../transcoder/data/system_ffmpeg_engine.dart';
import '../domain/media_item.dart';
import '../domain/media_type.dart';

/// 把一条捕获资源变成可显示的小图。
///
/// 各类型的取图方式完全不同，所以按类型分派：
/// - 图片：带 Referer/Cookie 重新请求一次，解码时直接降到 [maxWidth]，
///   避免一张 4K 原图把内存顶起来；
/// - 视频（mp4 等直链）：抽第一帧。Android 走原生 `MediaMetadataRetriever`，
///   桌面走本机 ffmpeg —— 两者都不下载整段视频，只读取必要字节；
/// - 音频 / HLS / DASH：没有便宜的封面来源（m3u8 要先下分片再解码），
///   直接返回 null，列表继续用类型图标。
class ThumbnailService {
  const ThumbnailService._();

  static const MethodChannel _channel =
      MethodChannel('sniffing_browser/thumbnailer');

  /// 单张原图的读取上限。超过了宁可显示类型图标，也不为一张缩略图
  /// 在手机上啃几 MB 流量。
  static const int _maxImageBytes = 3 * 1024 * 1024;
  static const Duration _fetchTimeout = Duration(seconds: 8);
  static const Duration _frameTimeout = Duration(seconds: 15);

  /// 「会和实际目标域名/长度冲突」的头，和 `FileDownloader` 保持一致。
  static const Set<String> _blockedHeaders = <String>{
    'host',
    'content-length',
    'connection',
    'accept-encoding',
  };

  static Future<Uint8List?> load(
    MediaItem item, {
    int maxWidth = 160,
  }) async {
    switch (item.type) {
      case MediaType.image:
        return _image(item, maxWidth);
      case MediaType.video:
        return videoFrame(item, maxWidth: maxWidth);
      case MediaType.audio:
      case MediaType.hls:
      case MediaType.dash:
      case MediaType.other:
        return null;
    }
  }

  /// 视频抽帧的串行闸门。
  ///
  /// 这里的限制比 [ThumbnailCache.maxConcurrent] 更严，是刻意的：图片是几个
  /// HTTP 请求，并发 3 没问题；视频抽帧每个都要起进程 / 打开媒体源，
  /// 一个视频列表页面上来几十条，并发跑会把 CPU 占满，列表反而更卡。
  static final SerialGate _frameGate = SerialGate();

  /// 单独暴露视频抽帧，方便按平台排查。
  static Future<Uint8List?> videoFrame(
    MediaItem item, {
    int maxWidth = 160,
  }) {
    return _frameGate.run(() => _videoFrameNow(item, maxWidth: maxWidth));
  }

  static Future<Uint8List?> _videoFrameNow(
    MediaItem item, {
    required int maxWidth,
  }) {
    switch (PlatformInfo.current) {
      case AppPlatform.android:
        return _nativeFrame(item, maxWidth);
      case AppPlatform.windows:
      case AppPlatform.macos:
      case AppPlatform.linux:
        return _ffmpegFrame(item, maxWidth);
      case AppPlatform.ohos:
      case AppPlatform.other:
        // 鸿蒙侧没有原生实现，入口一律不承诺能力。
        return Future<Uint8List?>.value(null);
    }
  }

  static Future<Uint8List?> _image(MediaItem item, int maxWidth) async {
    final Uri? uri = Uri.tryParse(item.url);
    if (uri == null || !uri.hasScheme) return null;

    final HttpClient client = HttpClient()
      ..connectionTimeout = _fetchTimeout
      ..autoUncompress = true;
    try {
      final HttpClientRequest request = await client.getUrl(uri);
      requestHeaders(item).forEach((String key, String value) {
        try {
          request.headers.set(key, value);
        } catch (_) {
          // 少数头 HttpClient 不允许手工设置，跳过即可 —— 缩略图不值得为它报错。
        }
      });

      final HttpClientResponse response =
          await request.close().timeout(_fetchTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        logDebug('Thumb', '图片 ${response.statusCode} ${item.url}');
        return null;
      }
      final int declared = response.contentLength;
      if (declared > _maxImageBytes) {
        logDebug('Thumb', '图片过大 ${declared}B，跳过 ${item.url}');
        return null;
      }

      final BytesBuilder builder = BytesBuilder(copy: false);
      int total = 0;
      await for (final List<int> chunk in response.timeout(_fetchTimeout)) {
        total += chunk.length;
        if (total > _maxImageBytes) {
          logDebug('Thumb', '图片超过上限，中止 ${item.url}');
          return null;
        }
        builder.add(chunk);
      }
      if (total == 0) return null;
      return await _downscale(builder.takeBytes(), maxWidth);
    } catch (e, s) {
      logDebug('Thumb', '取图失败 ${item.url}: $e\n$s');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 解码时降采样，只保留需要的宽度。原图动辄几千像素，直接 decode 会爆内存。
  static Future<Uint8List?> _downscale(Uint8List bytes, int maxWidth) async {
    final ui.Codec codec =
        await ui.instantiateImageCodec(bytes, targetWidth: maxWidth);
    try {
      final ui.FrameInfo frame = await codec.getNextFrame();
      try {
        final ByteData? data =
            await frame.image.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  static Future<Uint8List?> _nativeFrame(MediaItem item, int maxWidth) async {
    try {
      return await _channel.invokeMethod<Uint8List>(
        'extractFrame',
        <String, Object?>{
          'url': item.url,
          'headers': requestHeaders(item),
          'maxWidth': maxWidth,
        },
      );
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      logDebug('Thumb', '原生抽帧失败 ${e.code}: ${e.message}');
      return null;
    }
  }

  /// 桌面用 ffmpeg 抽第一帧，直接输出 PNG 到管道，不落临时文件。
  static Future<Uint8List?> _ffmpegFrame(MediaItem item, int maxWidth) async {
    final String? ffmpeg = await SystemFfmpegEngine.locateFfmpeg();
    if (ffmpeg == null) return null;

    final String headerBlock = _ffmpegHeaders(item);
    final List<String> args = <String>[
      '-v', 'error',
      '-nostdin',
      if (headerBlock.isNotEmpty) ...<String>['-headers', headerBlock],
      '-i', item.url,
      '-frames:v', '1',
      '-vf', 'scale=$maxWidth:-2',
      '-f', 'image2pipe',
      '-vcodec', 'png',
      'pipe:1',
    ];

    Process? process;
    try {
      final Process started = await Process.start(ffmpeg, args);
      process = started;
      final BytesBuilder out = BytesBuilder(copy: false);
      final Future<void> collect = started.stdout.forEach(out.add);
      final Future<void> discard = started.stderr.drain<void>();

      // 拉流阶段可能长时间没响应，超时就杀掉，别让 ffmpeg 进程挂在那儿。
      final int code = await started.exitCode.timeout(
        _frameTimeout,
        onTimeout: () {
          started.kill();
          return -1;
        },
      );
      await collect;
      await discard;
      if (code != 0) return null;

      final Uint8List bytes = out.takeBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (e, s) {
      logDebug('Thumb', '抽帧失败 ${item.url}: $e\n$s');
      process?.kill();
      return null;
    }
  }

  /// 嗅探时缓存的请求头就是资源真实可用的那一套，必须带上，否则多数站点 403。
  static Map<String, String> requestHeaders(MediaItem item) {
    final Map<String, String> result = <String, String>{};
    item.requestHeaders.forEach((String key, String value) {
      if (_blockedHeaders.contains(key.toLowerCase())) return;
      result[key] = value;
    });
    final bool hasReferer =
        result.keys.any((String k) => k.toLowerCase() == 'referer');
    if (!hasReferer && item.pageUrl != null) {
      result['Referer'] = item.pageUrl!;
    }
    return result;
  }

  /// ffmpeg 的 `-headers` 是「多行字符串」，不是单个头，格式必须是 `Key: Value\r\n`。
  static String _ffmpegHeaders(MediaItem item) {
    const Set<String> wanted = <String>{'referer', 'cookie', 'user-agent'};
    final StringBuffer buffer = StringBuffer();
    requestHeaders(item).forEach((String key, String value) {
      if (!wanted.contains(key.toLowerCase())) return;
      buffer.write('$key: $value\r\n');
    });
    return buffer.toString();
  }
}
