import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/logging/app_log.dart';
import '../../../core/platform/browser_headers.dart';
import '../../../core/platform/platform_info.dart';
import '../../../core/platform/proxy_rule.dart';
import '../../sniffer/domain/media_type.dart';
import 'media_validator.dart';

/// 按 URL 取一份 `name=value; name2=value2` 形式的 Cookie。
///
/// Android 上必须由 WebView 的 `CookieManager` 提供：`WebResourceRequest`
/// 的 `getRequestHeaders()` 不含 Cookie（那些是原生网络栈自己注入的），
/// 所以嗅探缓存下来的头永远缺这一段，纯靠它下载必然 403。
typedef CookieLoader = Future<String?> Function(String url);

/// 普通单文件下载（图片 / mp3 / mp4 / 分片）。
///
/// 先写 `.part` 再 rename —— 中途失败不会留下一个看似完整的半截文件，
/// 这对“下载完成后自动导出到相册”尤其重要。
class FileDownloader {
  FileDownloader({Dio? dio, CookieLoader? cookieLoader})
    : _dio = dio ?? createDio(),
      _cookieLoader = cookieLoader;

  final Dio _dio;

  /// 缺省为 null（纯 Dart 环境、单测、桌面不需要）：此时行为与之前完全一致。
  final CookieLoader? _cookieLoader;

  /// 建一个默认配置的 [Dio]。
  ///
  /// [proxy] 为 null 时与以前完全一致。传了就在每次连接前问一次当前代理：
  /// Dart 的 `HttpClient` 不会自动读系统代理，桌面端 `HTTP_PROXY` 也就一直
  /// 没生效（Android 的 Wi-Fi 代理同理，走设置页手动填）。用回调而不是固定值，
  /// 是为了让设置页改完立刻对**新请求**生效，不用重建下载器。
  static Dio createDio({ProxyRule Function()? proxy}) {
    final Dio dio = Dio(
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
    if (proxy != null) {
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final HttpClient client = HttpClient();
          client.findProxy = (Uri uri) => proxy().directiveFor(uri);
          return client;
        },
      );
    }
    return dio;
  }

  /// 下载到 [target]。返回最终文件。
  ///
  /// 支持字节级续传：`.part` 里已有多少就从 `Range: bytes=<offset>-` 接着下，
  /// 只认 206 且 `Content-Range` 起点对得上 —— 有的站点忽略 Range 直接回 200，
  /// 那种情况 append 会把文件写坏，只能丢掉重来。
  ///
  /// 网络类失败在这里只做短重试（2s / 6s），**长时间的等待交给调用方**：
  /// 任务级「等网络」要落成可见状态，藏在 IO 层等两分钟，界面就只能干挂着。
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

    // Cookie 只取一次，重试沿用同一份：每次重试都过一遍 WebView 通道没有收益。
    final Map<String, String> requestHeaders = _sanitizeHeaders(
      await _withCookies(url, headers),
    );

    final List<Map<String, String>> plans = <Map<String, String>>[
      requestHeaders,
      ..._retryPlan(requestHeaders, url),
    ];

    DioException? last;
    for (int i = 0; i < plans.length; i++) {
      try {
        final File file = await _downloadOnce(
          url: url,
          part: part,
          target: target,
          headers: plans[i],
          cancelToken: cancelToken,
          onProgress: onProgress,
          retries: i == 0 ? retries : 1,
          expectType: expectType,
        );
        if (i > 0) logInfo('Download', '403 后第 $i 套请求头成功: $url');
        return file;
      } on DioException catch (error) {
        if (CancelToken.isCancel(error)) rethrow;
        last = error;
        // 只有 403 值得换头重试：404 换头不会变好，超时换头也没意义。
        if (error.response?.statusCode != 403) break;
      }
    }

    final String? hint403 = await _explain403(last, url, plans.last);
    throw DownloadException(
      _describeError(last, hint403: hint403),
      url: url,
      cause: last,
      network: last != null && _isNetworkFailure(last),
    );
  }

  /// 单套请求头的下载循环。失败时抛最后一个 [DioException]，由外层决定要不要换头。
  Future<File> _downloadOnce({
    required String url,
    required File part,
    required File target,
    required Map<String, String> headers,
    required CancelToken? cancelToken,
    required void Function(int received, int total)? onProgress,
    required int retries,
    required MediaType? expectType,
  }) async {
    /// 发一次请求。[offset] > 0 表示接着已下的字节下。
    Future<Response<dynamic>> fetch(int offset) {
      return _dio.download(
        url,
        part.path,
        options: Options(
          headers: offset > 0
              ? <String, String>{...headers, 'Range': 'bytes=$offset-'}
              : headers,
          responseType: ResponseType.stream,
        ),
        cancelToken: cancelToken,
        // 中断时**不删**已写字节：它们是完整前缀，下一次从 offset 接着下。
        // 之前的写法每次重试都从头来，站点按连接时长/字节数掐断时必然三次
        // 断在同一处，用户看到的就是"过一会儿报错、点重试也没用"。
        deleteOnError: false,
        fileAccessMode: offset > 0
            ? FileAccessMode.append
            : FileAccessMode.write,
        // 续传时 total 只是剩余字节，进度得补上 offset，否则进度条往回跳。
        onReceiveProgress: offset > 0
            ? (int received, int total) => onProgress?.call(
                offset + received,
                total > 0 ? offset + total : total,
              )
            : onProgress,
      );
    }

    Object? lastError;
    for (int attempt = 0; attempt <= retries; attempt++) {
      try {
        int offset = await _partLength(part);
        Response<dynamic> response = await fetch(offset);

        // 服务端忽略 Range 时回 200 全量，append 会把整段接在旧字节后面 ——
        // 文件看着更大，实际已损坏。这种情况只能丢掉重来。
        if (offset > 0 && !_resumedCorrectly(response, offset)) {
          await _deleteQuietly(part);
          offset = 0;
          response = await fetch(0);
        }

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
        // 416：残留的 .part 比资源本身还长（地址换过 / 文件被改过），
        // 不删掉的话每次续传都会被拒，只能从头下。
        if (e.response?.statusCode == 416) await _deleteQuietly(part);
        if (attempt == retries) break;
        // 等待期间用户可能点了取消，别白等一轮再撞上 cancel。
        if (cancelToken?.isCancelled ?? false) break;
        await Future<void>.delayed(_backoff(e, attempt, 400));
      }
    }

    _logTimeout(lastError, url);
    throw lastError is DioException
        ? lastError
        : DownloadException(_describeError(lastError), url: url);
  }

  /// `.part` 里已有多少字节。取不到就当作 0，从零下。
  static Future<int> _partLength(File part) async {
    try {
      return await part.exists() ? await part.length() : 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删不掉就交给下一次 416 兜底
    }
  }

  /// 续传响应是否真的接在 [offset] 后面。
  ///
  /// 只认 206 + `Content-Range` 起点对得上：有的 CDN 会忽略 Range 回 200，
  /// 有的会把范围往回收（回 206 但起点是 0），这两种情况直接 append 都会得到
  /// 一个大小看着正常、内容错位的坏文件。
  static bool _resumedCorrectly(Response<dynamic> response, int offset) {
    if (response.statusCode != 206) return false;
    final String? range = response.headers.value('content-range');
    if (range == null) return true;
    return range.replaceAll(' ', '').startsWith('bytes$offset-');
  }

  /// 直接取字节。用于小资源（playlist、密钥）。
  Future<List<int>> fetchBytes({
    required String url,
    Map<String, String> headers = const <String, String>{},
    CancelToken? cancelToken,
    int retries = 2,
  }) async {
    final Map<String, String> requestHeaders = _sanitizeHeaders(
      await _withCookies(url, headers),
    );

    final List<Map<String, String>> plans = <Map<String, String>>[
      requestHeaders,
      ..._retryPlan(requestHeaders, url),
    ];

    DioException? last;
    for (int i = 0; i < plans.length; i++) {
      try {
        final List<int> bytes = await _fetchBytesOnce(
          url: url,
          headers: plans[i],
          cancelToken: cancelToken,
          retries: i == 0 ? retries : 1,
        );
        if (i > 0) logInfo('Download', '403 后第 $i 套请求头成功: $url');
        return bytes;
      } on DioException catch (error) {
        if (CancelToken.isCancel(error)) rethrow;
        last = error;
        if (error.response?.statusCode != 403) break;
      }
    }

    final String? hint403 = await _explain403(last, url, plans.last);
    throw DownloadException(
      _describeError(last, hint403: hint403),
      url: url,
      cause: last,
      network: last != null && _isNetworkFailure(last),
    );
  }

  Future<List<int>> _fetchBytesOnce({
    required String url,
    required Map<String, String> headers,
    required CancelToken? cancelToken,
    required int retries,
  }) async {
    Object? lastError;
    for (int attempt = 0; attempt <= retries; attempt++) {
      try {
        final Response<List<int>> response = await _dio.get<List<int>>(
          url,
          options: Options(headers: headers, responseType: ResponseType.bytes),
          cancelToken: cancelToken,
        );
        return response.data ?? <int>[];
      } on DioException catch (e) {
        lastError = e;
        if (CancelToken.isCancel(e)) rethrow;
        if (attempt == retries) break;
        if (cancelToken?.isCancelled ?? false) break;
        await Future<void>.delayed(_backoff(e, attempt, 300));
      }
    }
    _logTimeout(lastError, url);
    throw lastError is DioException
        ? lastError
        : DownloadException(_describeError(lastError), url: url);
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

  /// 把 WebView 侧同域的 Cookie 合并进请求头。
  ///
  /// HLS 的分片经常换到 CDN 域名，所以按**每个请求的 URL** 现取，而不是复用
  /// playlist 那一份。取不到就按原样发 —— Cookie 获取失败绝不能挡住下载。
  Future<Map<String, String>> _withCookies(
    String url,
    Map<String, String> headers,
  ) async {
    final CookieLoader? loader = _cookieLoader;
    if (loader == null) return headers;

    String? fromJar;
    try {
      fromJar = await loader(url);
    } catch (_) {
      return headers;
    }
    if (fromJar == null || fromJar.isEmpty) {
      _logCookieMiss(url);
      return headers;
    }

    final Map<String, String> result = Map<String, String>.from(headers);
    String? existing;
    for (final String key in result.keys.toList()) {
      if (key.toLowerCase() != 'cookie') continue;
      existing = result.remove(key);
    }

    final Map<String, String> merged = mergeCookies(existing, fromJar);
    if (merged.isEmpty) return result;
    result['Cookie'] = merged.entries
        .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
        .join('; ');
    return result;
  }

  /// 403 之后的换头顺序。顺序是踩出来的，不是排出来的：
  ///
  /// 1. 补齐浏览器该带、而 Dart 默认不带的头 —— 有的站点 WAF 就卡这几个；
  /// 2. 换成中性 UA —— Cloudflare 的 Browser Integrity Check 会比对「UA 声称
  ///    的浏览器」与客户端指纹，`dart:io` 带着 Chrome UA 出去会被判成伪装
  ///    直接 403，换成不冒充浏览器的 UA（`okhttp/4.12.0`）反而通得过。
  ///
  /// 第 2 条是在真机上对比出来的：同一地址、同一 Referer，`Dart/3.9` 与
  /// `okhttp/4.12.0` 是 200，Chrome / Firefox / Safari 的 UA 一律 403。
  List<Map<String, String>> _retryPlan(
    Map<String, String> headers,
    String url,
  ) {
    final List<Map<String, String>> plan = <Map<String, String>>[];
    final Map<String, String> withExtras = withBrowserHeaders(
      headers,
      url: url,
    );
    if (!identical(withExtras, headers)) plan.add(withExtras);
    final Map<String, String>? neutral = withNeutralUserAgent(withExtras);
    if (neutral != null) plan.add(neutral);
    return plan;
  }

  /// 403 时把「实际发出去哪些头」记下来，再要一次响应体看拦截原因。
  ///
  /// Cookie 只打名字不打值：写进日志是隐患。
  /// 返回本次 403 的诊断结论。不能存实例字段：多条任务共用同一个
  /// FileDownloader，后写先读会让错误文案张冠李戴。
  Future<String?> _explain403(
    DioException? error,
    String url,
    Map<String, String> headers,
  ) async {
    if (error?.response?.statusCode != 403) return null;

    String referer = '(无)';
    String cookieNames = '(无)';
    headers.forEach((String key, String value) {
      final String lower = key.toLowerCase();
      if (lower == 'referer') referer = value;
      if (lower == 'cookie') cookieNames = _cookieNames(value);
    });
    // 有的站点是 Cloudflare / 字节 CDN 在拦，Server 和 CF-Ray 能直接区分
    // 「自己的头不对」和「被 WAF 挡了」这两种完全不同的原因。
    final Response<dynamic>? response = error?.response;
    final String server = response?.headers.value('server') ?? '-';
    final String cfRay = response?.headers.value('cf-ray') ?? '-';
    logWarn(
      'Download',
      '403 $url Referer=$referer Cookie=[$cookieNames] Server=$server CF-Ray=$cfRay',
    );

    // 光看状态码分不清「WAF 按 IP 拦」和「客户端特征被拦」，两者的修法完全
    // 相反。Cloudflare 的拦截页里有 error code，值得再花一个请求拿回来。
    return _probe403Body(url, headers);
  }

  Future<String?> _probe403Body(String url, Map<String, String> headers) async {
    try {
      final Response<String> probe = await _dio.get<String>(
        url,
        options: Options(
          headers: headers,
          responseType: ResponseType.plain,
          receiveTimeout: const Duration(seconds: 8),
          validateStatus: (int? code) => code != null && code < 500,
        ),
      );
      final String body = (probe.data ?? '').replaceAll(RegExp(r'\s+'), ' ');
      final String snippet = body.length > 240
          ? '${body.substring(0, 240)}…'
          : body;
      final String? code = _cloudflareCode(body);
      final String? hint = switch (code) {
        // 1010：浏览器特征校验没过（UA / 头对不上）。
        '1010' => '站点校验客户端特征未通过',
        // 1020：按 IP / ASN 的规则直接拒 —— 换网络环境才有用。
        '1020' => '站点按 IP 拦截，当前网络出口被拒',
        '1015' => '站点限流',
        _ => null,
      };
      logWarn(
        'Download',
        '403 诊断 $url status=${probe.statusCode} '
            'cf-mitigated=${probe.headers.value('cf-mitigated') ?? '-'} '
            'cf-code=${code ?? '-'} body=$snippet',
      );
      return hint;
    } catch (e) {
      logDebug('Download', '403 诊断请求失败 $url: $e');
      return null;
    }
  }

  /// 从 Cloudflare 拦截页里抠出 4 位 error code。拿不到就返回 null。
  static String? _cloudflareCode(String body) {
    final RegExpMatch? match = RegExp(
      r'(?:Error code|error code|"code")\D{0,10}(\d{4})',
    ).firstMatch(body);
    return match?.group(1);
  }

  static String _cookieNames(String header) {
    final List<String> names = <String>[];
    for (final String part in header.split(';')) {
      final int eq = part.indexOf('=');
      if (eq <= 0) continue;
      names.add(part.substring(0, eq).trim());
    }
    return names.join(',');
  }

  /// 某个域名始终取不到 Cookie 时记一条。分片动辄几百个请求，不能每个都打。
  static final Set<String> _cookieMissLogged = <String>{};

  void _logCookieMiss(String url) {
    final String host = Uri.tryParse(url)?.host ?? url;
    if (!_cookieMissLogged.add(host)) return;
    logDebug('Download', 'WebView 里没有 $host 的 Cookie');
  }

  /// 缺省 UA。移动端必须给移动 UA：`onLoadResource` 只给 URL、拿不到头时
  /// 会落到这里，而 WebView 自己发的就是移动 UA，很多站点按 UA 决定返回
  /// 内容、甚至参与签名校验，用桌面 UA 会直接 403。
  static String get _defaultUserAgent {
    if (PlatformInfo.isMobile) {
      return 'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
    }
    return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  }

  /// 失败后的等待时长。
  ///
  /// 网络类（超时 / 连接失败 / 断流）只做两次很短的退避：真正「按分钟等网络
  /// 恢复」的是下载队列，那里有可见状态。这里再拉长只会让「等待网络」晚几秒
  /// 出现在界面上，用户看到的是「点了下载没反应」。
  ///
  /// 站点类（403 / 404 / 5xx）仍按 [baseMs] 线性递增。
  static Duration _backoff(DioException error, int attempt, int baseMs) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.unknown:
        return Duration(milliseconds: 500 + attempt * 1000);
      default:
        return Duration(milliseconds: baseMs * (attempt + 1));
    }
  }

  /// 是不是「网络本身断了」而不是「站点拒绝了这次请求」。
  ///
  /// `unknown` 要拆开看：dio 把响应体阶段的所有异常都塞进这一类，`error` 上
  /// 挂的是 [SocketException] / [HandshakeException] / [TlsException]。
  /// 熄屏时系统回收 socket、切网时 TLS 握手被打断，都会走到这里；而 4xx/5xx
  /// 是 [DioExceptionType.badResponse]，不在此列。
  ///
  /// 结论会带到 [DownloadException.network] 上，由下载队列决定「等网络还是放弃」。
  static bool _isNetworkFailure(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.unknown:
        final Object? cause = error.error;
        if (cause is SocketException ||
            cause is TlsException ||
            cause is HandshakeException) {
          return true;
        }
        // 流里抛出的异常经过几层包装后有时只剩 message，靠关键字兜底。
        final String raw = _rawCause(error);
        return raw.contains('Connection closed') ||
            raw.contains('Connection reset') ||
            raw.contains('Broken pipe') ||
            raw.contains('HandshakeException');
      default:
        return false;
    }
  }

  /// 记录「根本没连上」这类失败。
  ///
  /// 之前只记 403，用户反馈「重试一直失败」时日志里什么都没有，分不清是
  /// 站点拒绝、DNS 挂了还是隧道断了。只记主机名，不记完整 URL 的 query。
  ///
  /// `unknown` 单独把底层异常带上：`Connection closed while receiving data`
  /// （对方主动断）和 `Connection reset by peer`（线路或系统回收了连接）
  /// 是两个不同的原因，不记下来就只能靠猜。
  static void _logTimeout(Object? error, String url) {
    if (error is! DioException) return;
    final String host = Uri.tryParse(url)?.host ?? url;
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        logWarn('Download', '请求失败 ${error.type.name} $host');
      case DioExceptionType.unknown:
        logWarn('Download', '请求失败 unknown $host ${_rawCause(error)}');
      default:
        return;
    }
  }

  /// 把 dio 吞掉的底层异常取出来。
  ///
  /// 响应体中途断开时，dio 抛的是 `type = unknown` 且 `message` 为空的
  /// [DioException]（真实原因在 `error.error` 里）。直接取 `message` 就只能
  /// 给用户一句「未知错误」，等于没报错。
  static String _rawCause(DioException error) {
    final Object? cause = error.error;
    final String raw = error.message ?? (cause?.toString() ?? '');
    return raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _describeError(Object? error, {String? hint403}) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.transformTimeout:
          return '连接超时，站点可能限制了该地址；稍后重试，或回原页面重新嗅探';
        case DioExceptionType.badResponse:
          final int? code = error.response?.statusCode;
          if (code == 403) {
            // 补过浏览器头还是被拒，说明不是「少个请求头」这么简单：
            // 把本次 403 诊断出的结论带上，用户才知道该换网络还是该反馈。
            return hint403 == null
                ? '403 拒绝访问，站点拒绝了这次请求'
                : '403 拒绝访问（$hint403）';
          }
          if (code == 404) return '404 资源不存在';
          return 'HTTP $code';
        case DioExceptionType.connectionError:
          return '网络连接失败';
        case DioExceptionType.badCertificate:
          return '证书校验失败';
        case DioExceptionType.cancel:
          return '已取消';
        case DioExceptionType.unknown:
          return _describeUnknown(error);
      }
    }
    return error?.toString() ?? '未知错误';
  }

  /// `unknown` 的实际含义几乎只有一个：连接在某个阶段没了。
  ///
  /// 已下的字节留在 `.part` 里，重试会从断点接着下，所以文案直接告诉用户
  /// 「重试就行」，而不是让他回原页面重新嗅探。
  static String _describeUnknown(DioException error) {
    final String raw = _rawCause(error);
    if (raw.isEmpty) return '未知错误';
    final String detail = raw.length > 120 ? '${raw.substring(0, 120)}…' : raw;
    // 握手阶段被中断：连接还没建起来就没了。熄屏、切网、飞行模式都会这样，
    // 和「响应体下到一半断掉」是两回事，但对用户来说处理方式一样。
    if (raw.contains('HandshakeException')) {
      return '连接在 TLS 握手阶段被中断，通常是熄屏断网或网络切换；'
          '已下的部分会保留，重试可接着下（$detail）';
    }
    if (raw.contains('Connection closed') ||
        raw.contains('Connection reset') ||
        raw.contains('Broken pipe')) {
      return '连接被中途断开，已下的部分会保留；重试可接着下（$detail）';
    }
    if (raw.contains('Network is unreachable') ||
        raw.contains('Failed host lookup')) {
      return '当前没有可用网络，已下的部分会保留；恢复网络后重试可接着下（$detail）';
    }
    return '未知错误（$detail）';
  }
}

/// 下载异常。带 URL，日志里能直接定位到哪个资源失败。
class DownloadException implements Exception {
  DownloadException(this.message, {this.url, this.cause, this.network = false});

  final String message;
  final String? url;
  final Object? cause;

  /// 失败原因是「网络断了」而不是「站点拒绝 / 内容不对」。
  ///
  /// 下载队列据此决定要不要等网络恢复再自动重试：断网等一会儿就能好，
  /// 403 / 404 等多久都一样。判定见 [FileDownloader._isNetworkFailure]。
  final bool network;

  /// 站点返回 403。
  ///
  /// 队列会给有限轮次的重试机会：每轮重新从 WebView 取 Cookie，
  /// 会话轮换 / 短暂限流造成的 403 有机会自愈；签名过期的则几轮后照旧失败。
  bool get forbidden {
    final Object? reason = cause;
    return reason is DioException && reason.response?.statusCode == 403;
  }

  @override
  String toString() => url == null ? message : '$message ($url)';
}

/// 合并两份 Cookie：[existing]（嗅探到的那份，页面当时真实生效）同名优先。
@visibleForTesting
Map<String, String> mergeCookies(String? existing, String fromJar) {
  final Map<String, String> merged = _parseCookieHeader(fromJar);
  if (existing != null) {
    _parseCookieHeader(existing).forEach((String name, String value) {
      merged[name] = value;
    });
  }
  return merged;
}

Map<String, String> _parseCookieHeader(String raw) {
  final Map<String, String> out = <String, String>{};
  for (final String part in raw.split(';')) {
    final int eq = part.indexOf('=');
    // eq == 0 是非法的 "=value"，直接丢。
    if (eq <= 0) continue;
    final String name = part.substring(0, eq).trim();
    if (name.isEmpty) continue;
    out[name] = part.substring(eq + 1).trim();
  }
  return out;
}
