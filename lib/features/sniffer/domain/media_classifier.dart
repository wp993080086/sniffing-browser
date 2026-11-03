import 'package:path/path.dart' as p;

import 'media_type.dart';

/// URL / MIME 到媒体类型的判定。
///
/// 判定顺序很重要：先看扩展名（最可靠），再看 MIME，最后看 query 参数。
/// 反过来会误判 —— 很多 CDN 的 URL 后缀是 `.jpg` 但 MIME 报 `application/octet-stream`。
class MediaClassifier {
  const MediaClassifier._();

  static const Set<String> _imageExtensions = <String>{
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'avif', 'heic', 'heif', 'svg',
  };

  static const Set<String> _audioExtensions = <String>{
    'mp3', 'm4a', 'aac', 'flac', 'wav', 'ogg', 'oga', 'opus', 'wma', 'amr',
    'ape', 'dsf',
  };

  static const Set<String> _videoExtensions = <String>{
    'mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi', 'flv', 'wmv', 'mpg', 'mpeg',
    '3gp', 'rmvb', 'ts', 'm2ts',
  };

  static const Set<String> _hlsExtensions = <String>{'m3u8', 'm3u'};

  static const Set<String> _dashExtensions = <String>{'mpd'};

  /// 明显不是媒体的资源，直接不进列表。
  /// 只做减法：即便漏掉一些，后面的类型白名单也会挡掉，这里主要是省掉无用计算。
  static const Set<String> _ignoredExtensions = <String>{
    'html', 'htm', 'php', 'asp', 'aspx', 'jsp',
    'js', 'mjs', 'css', 'map',
    'json', 'xml', 'txt', 'csv',
    'woff', 'woff2', 'ttf', 'otf', 'eot',
    'ico',
  };

  /// 广告与统计域名。命中就不显示。
  static const List<String> _blockedHostKeywords = <String>[
    'google-analytics',
    'googletagmanager',
    'doubleclick',
    'googlesyndication',
    'adservice',
    'adsystem',
    'scorecardresearch',
    'umeng',
    'cnzz',
    'baidustatic.com/hm',
    'hm.baidu.com',
    'talkingdata',
    'sentry.io',
    'bugly',
    'fbcdn.net/tr',
  ];

  /// MIME 已经明确是「网页 / 接口报文」时，扩展名说了不算。
  ///
  /// 典型场景：SPA 站点把不存在的 `/_nuxt/videos/banner.xxx.mp4`
  /// 兜底成首页（200 + text/html）。扩展名伪装得完美，内容却是一整页 HTML，
  /// 下了也放不出来 —— 这种条目根本不该出现在资源列表里。
  static const List<String> _textualMimes = <String>[
    'text/html',
    'application/xhtml',
    'application/json',
    'text/xml',
    'application/xml',
  ];

  /// 主判定入口。
  ///
  /// [mimeType] 通常拿不到（ArkWeb / WebView 都只给 URL 和请求头），
  /// 所以扩展名必须能独立支撑判断。
  static MediaType classifyUrl(String url, {String? mimeType}) {
    if (url.isEmpty) return MediaType.other;

    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return MediaType.other;

    final String scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return MediaType.other;

    if (mimeType != null && mimeType.isNotEmpty) {
      final String mime = mimeType.toLowerCase();
      for (final String textual in _textualMimes) {
        if (mime.contains(textual)) return MediaType.other;
      }
    }

    final String ext = extensionOf(url);
    if (ext.isNotEmpty) {
      if (_hlsExtensions.contains(ext)) return MediaType.hls;
      if (_dashExtensions.contains(ext)) return MediaType.dash;
      if (_imageExtensions.contains(ext)) return MediaType.image;
      if (_audioExtensions.contains(ext)) return MediaType.audio;
      if (_videoExtensions.contains(ext)) return MediaType.video;
      if (_ignoredExtensions.contains(ext)) return MediaType.other;
    }

    // 扩展名没命中，看 MIME。
    if (mimeType != null && mimeType.isNotEmpty) {
      final MediaType byMime = classifyMime(mimeType);
      if (byMime != MediaType.other) return byMime;
    }

    // 最后一招：query 里的 format / type 参数。部分 CDN 会这么写：
    // /media?id=123&format=mp4
    for (final String key in const <String>['format', 'type', 'ext', 'fm']) {
      final String? value = uri.queryParameters[key]?.toLowerCase();
      if (value == null || value.isEmpty) continue;
      final MediaType byQuery = classifyUrl(
        'https://placeholder.invalid/x.$value',
        mimeType: mimeType,
      );
      if (byQuery != MediaType.other) return byQuery;
    }

    return MediaType.other;
  }

  static MediaType classifyMime(String mimeType) {
    final String mime = mimeType.split(';').first.trim().toLowerCase();
    if (mime.startsWith('image/')) return MediaType.image;
    if (mime.startsWith('audio/')) return MediaType.audio;
    if (mime.startsWith('video/')) {
      // HLS 的 playlist 有的站点会报 video/mp2t 或 application/vnd.apple.mpegurl
      return MediaType.video;
    }
    if (mime.contains('mpegurl')) return MediaType.hls;
    if (mime.contains('dash+xml')) return MediaType.dash;
    return MediaType.other;
  }

  /// 扩展名本身指向媒体（用来给「被 MIME 否决」的条目写诊断日志）。
  static bool hasMediaExtension(String url) {
    final String ext = extensionOf(url);
    if (ext.isEmpty) return false;
    return _imageExtensions.contains(ext) ||
        _audioExtensions.contains(ext) ||
        _videoExtensions.contains(ext) ||
        _hlsExtensions.contains(ext) ||
        _dashExtensions.contains(ext);
  }

  /// MIME 是否属于「网页 / 接口报文」。这类响应即使扩展名像媒体也不是媒体。
  static bool isTextualMime(String mimeType) {
    final String mime = mimeType.toLowerCase();
    for (final String textual in _textualMimes) {
      if (mime.contains(textual)) return true;
    }
    return false;
  }

  /// 取 URL path 的扩展名，小写，不含点。
  static String extensionOf(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return '';
    final String path = uri.path;
    if (path.isEmpty) return '';
    final String ext = p.extension(path);
    if (ext.length < 2) return '';
    return ext.substring(1).toLowerCase();
  }

  /// 该 URL 是否应该被完全忽略（不显示、不下载）。
  static bool isIgnorable(String url) {
    if (url.isEmpty) return true;
    final String lower = url.toLowerCase();
    if (lower.startsWith('blob:') ||
        lower.startsWith('data:') ||
        lower.startsWith('javascript:') ||
        lower.startsWith('about:') ||
        lower.startsWith('file:') ||
        lower.startsWith('ws:') ||
        lower.startsWith('wss:')) {
      return true;
    }

    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return true;
    final String host = uri.host.toLowerCase();
    if (host.isEmpty) return true;
    final String hostAndPath = '$host${uri.path}'.toLowerCase();
    for (final String keyword in _blockedHostKeywords) {
      if (hostAndPath.contains(keyword)) return true;
    }
    return false;
  }

  /// 从 URL 猜一个可读的文件名。猜不出来时用类型默认扩展名兜底。
  static String guessFileName(String url, MediaType type) {
    String name = '';
    final Uri? uri = Uri.tryParse(url);
    if (uri != null && uri.pathSegments.isNotEmpty) {
      name = uri.pathSegments.last;
    }
    name = Uri.decodeComponent(name);

    if (name.isEmpty) {
      name = 'media_${DateTime.now().millisecondsSinceEpoch}';
    }

    String ext = p.extension(name);
    if (ext.isEmpty || ext.length < 2) {
      final String fallback = type.defaultExtension;
      name = '$name.$fallback';
    } else if (ext.length > 6) {
      // 形如 `video.1234567890` 这种不是扩展名
      name = '$name.${type.defaultExtension}';
    }
    return name;
  }
}
