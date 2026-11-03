import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../../../core/constants/app_constants.dart';
import '../../sniffer/domain/media_type.dart';
import 'media_validator.dart';

/// 普通单文件下载（图片 / mp3 / mp4 / 分片）。
///
/// 先写 `.part` 再 rename —— 中途失败不会留下一个看似完整的半截文件，
/// 这对“下载完成后自动导出到相册”尤其重要。
class FileDownloader {
  FileDownloader({Dio? dio}) : _dio = dio ?? createDio();

  final Dio _dio;

  static Dio createDio() {
    return Dio(
      BaseOptions(
        connectTimeout: AppConstants.connectTimeout,
        receiveTimeout: AppConstants.receiveTimeout,
        followRedirects: true,
        maxRedirects: 5,
        // 交给我们自己判断状态码，便于给出更准确的错误信息
        validateStatus: (int? code) => code != null && code < 400,
        responseType: ResponseType.bytes,
      ),
    );
  }

  /// 下载到 [target]。返回最终文件。
  ///
  /// 不支持单文件断点续传：Range 的返回值需要逐站验证（有的站点忽略 Range 直接
  /// 返 200，然后 append 就会把文件写坏）。需要续传的是 HLS 分片，那里按分片粒度
  /// 做续传，更可靠。
  Future<File> download({
    required String url,
    required File target,
    Map<String, String> headers = const <String, String>{},
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
    int retries = 2,
    MediaType? expectType,
  }) async {
    await target.parent.create(recursive: true);
    final File part = File('${target.path}.part');
    if (await part.exists()) {
      await part.delete();
    }

    Object? lastError;
    for (int attempt = 0; attempt <= retries; attempt++) {
      try {
        final Response<dynamic> response = await _dio.download(
          url,
          part.path,
          options: Options(
            headers: _sanitizeHeaders(headers),
            responseType: ResponseType.stream,
          ),
          cancelToken: cancelToken,
          deleteOnError: true,
          onReceiveProgress: onProgress,
        );

        if (!await part.exists()) {
          throw const FileSystemException('下载完成但文件不存在');
        }

        // 内容校验：站点把 404 兜底成首页时，`.mp4` 里装的是整页 HTML。
        // 这种文件存下来只会得到"此文件无法播放"，必须在落盘前拦掉。
        if (expectType != null) {
          final String? problem = await MediaValidator.validate(
            part,
            type: expectType,
            contentType: response.headers.value(Headers.contentTypeHeader),
          );
          if (problem != null) {
            await part.delete();
            throw DownloadException(problem, url: url);
          }
        }

        if (await target.exists()) {
          await target.delete();
        }
        return part.rename(target.path);
      } on DioException catch (e) {
        lastError = e;
        if (CancelToken.isCancel(e)) rethrow;
        if (attempt == retries) break;
        await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
      }
    }

    throw DownloadException(
      _describeError(lastError),
      url: url,
      cause: lastError,
    );
  }

  /// 直接取字节。用于小资源（playlist、密钥）。
  Future<List<int>> fetchBytes({
    required String url,
    Map<String, String> headers = const <String, String>{},
    CancelToken? cancelToken,
    int retries = 2,
  }) async {
    Object? lastError;
    for (int attempt = 0; attempt <= retries; attempt++) {
      try {
        final Response<List<int>> response = await _dio.get<List<int>>(
          url,
          options: Options(
            headers: _sanitizeHeaders(headers),
            responseType: ResponseType.bytes,
          ),
          cancelToken: cancelToken,
        );
        return response.data ?? <int>[];
      } on DioException catch (e) {
        lastError = e;
        if (CancelToken.isCancel(e)) rethrow;
        if (attempt == retries) break;
        await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
      }
    }
    throw DownloadException(_describeError(lastError), url: url, cause: lastError);
  }

  Future<String> fetchString({
    required String url,
    Map<String, String> headers = const <String, String>{},
    CancelToken? cancelToken,
  }) async {
    final List<int> bytes = await fetchBytes(
      url: url,
      headers: headers,
      cancelToken: cancelToken,
    );
    // 宽松解码：playlist 里偶尔有站点的奇怪注释，严格解码会直接崩。
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 去掉这些非法/会引发问题的头。
  /// `host` 手动设会和实际目标域名冲突，`content-length` 会对不上。
  Map<String, String> _sanitizeHeaders(Map<String, String> headers) {
    const Set<String> blocked = <String>{
      'host',
      'content-length',
      'connection',
      'accept-encoding',
    };
    final Map<String, String> result = <String, String>{};
    headers.forEach((String key, String value) {
      if (blocked.contains(key.toLowerCase())) return;
      result[key] = value;
    });
    if (!result.keys.any((String k) => k.toLowerCase() == 'user-agent')) {
      result['User-Agent'] = _defaultUserAgent;
    }
    return result;
  }

  static const String _defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  String _describeError(Object? error) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.transformTimeout:
          return '连接超时，站点可能限制了这个地址';
        case DioExceptionType.badResponse:
          final int? code = error.response?.statusCode;
          if (code == 403) return '403 拒绝访问，缺少 Referer 或 Cookie';
          if (code == 404) return '404 资源不存在';
          return 'HTTP $code';
        case DioExceptionType.connectionError:
          return '网络连接失败';
        case DioExceptionType.badCertificate:
          return '证书校验失败';
        case DioExceptionType.cancel:
          return '已取消';
        case DioExceptionType.unknown:
          return error.message ?? '未知错误';
      }
    }
    return error?.toString() ?? '未知错误';
  }
}

/// 下载异常。带 URL，日志里能直接定位到哪个资源失败。
class DownloadException implements Exception {
  DownloadException(this.message, {this.url, this.cause});

  final String message;
  final String? url;
  final Object? cause;

  @override
  String toString() => url == null ? message : '$message ($url)';
}
