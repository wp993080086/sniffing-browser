/// 浏览器会自动带、而 `dart:io` 的 HttpClient / Dio 默认不带的请求头。
///
/// 站点 WAF（Cloudflare 的 Browser Integrity Check 最典型）会把「一个请求
/// 却没有任何 `Sec-Fetch-*` 与客户端提示」当成脚本流量直接拒掉。这类 403
/// 与 Referer、Cookie 无关 —— 只盯着这两个头排查，永远查不出结果。
///
/// 所以这里只在「按原样请求已经被拒」之后才补，正常站点不会平白多几个头。
library;

import '../utils/site.dart';

/// 客户端提示里声明的 Chrome 版本。与下载器默认 UA 保持一致，
/// 否则 `sec-ch-ua` 和 UA 对不上，反而成了新的异常特征。
const String _chromeMajor = '126';

/// 把 [browserHeaders] 里缺的那些补进 [headers]。
///
/// 返回**新 Map**（调用方那份在多次重试间复用，就地改会污染基线）；
/// 本来就齐了则原样返回同一个实例，调用方可以据此判断「补了没用」。
Map<String, String> withBrowserHeaders(
  Map<String, String> headers, {
  required String url,
}) {
  final Map<String, String> extras = browserHeaders(
    url: url,
    referer: _valueOf(headers, 'referer'),
  );
  if (extras.keys.every((String key) => _hasKey(headers, key))) return headers;

  final Map<String, String> merged = Map<String, String>.from(headers);
  extras.forEach((String key, String value) {
    if (!_hasKey(merged, key)) merged[key] = value;
  });
  return merged;
}

/// 不冒充浏览器的 UA。
///
/// Cloudflare 的 Browser Integrity Check 会把「UA 声称自己是 Chrome、客户端
/// 指纹却不是」直接判成伪装并返回 403。`dart:io` 的 TLS 指纹不是 Chrome，
/// 所以带着浏览器 UA 出去反而被拦；换成中性的客户端 UA 才通得过。
///
/// 这个结论是从真机日志对比出来的，不是猜的：同一个地址、同一个 Referer，
/// `Dart/3.9` 与 `okhttp/4.12.0` 返回 200，Chrome / Firefox / Safari 的 UA
/// 一律 403。
const String kNeutralUserAgent = 'okhttp/4.12.0';

/// 把 UA 换成 [kNeutralUserAgent]，用于 403 后的第二次尝试。
///
/// 客户端提示（`sec-ch-ua*`）和 `Sec-Fetch-*` 一并去掉：它们和中性 UA 放
/// 在一起就是自相矛盾，等于换个姿势继续冒充浏览器。
///
/// 本来就是中性 UA（不含 `Mozilla/`）、或者压根没设 UA 时返回 null：
/// 这两种情况 `dart:io` 发出去的已经是 `Dart/...`，再换一遍没有意义。
Map<String, String>? withNeutralUserAgent(Map<String, String> headers) {
  final String? current = _valueOf(headers, 'user-agent');
  if (current == null || !current.contains('Mozilla/')) return null;

  return Map<String, String>.from(headers)
    ..removeWhere((String name, String _) {
      final String key = name.toLowerCase();
      return key == 'user-agent' ||
          key.startsWith('sec-ch-ua') ||
          key.startsWith('sec-fetch-');
    })
    ..['User-Agent'] = kNeutralUserAgent;
}

/// 一组通用头。[referer] 只用来判断 `Sec-Fetch-Site`。
Map<String, String> browserHeaders({required String url, String? referer}) {
  return <String, String>{
    // 媒体 / 分片都是 XHR 式请求，浏览器的默认 Accept 就是 */*。
    'Accept': '*/*',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'sec-ch-ua': '"Chromium";v="$_chromeMajor", "Not;A=Brand";v="24"',
    'sec-ch-ua-mobile': '?1',
    'sec-ch-ua-platform': '"Android"',
    'Sec-Fetch-Dest': 'empty',
    'Sec-Fetch-Mode': 'cors',
    'Sec-Fetch-Site': _fetchSite(url, referer),
  };
}

String _fetchSite(String url, String? referer) {
  if (referer == null || referer.isEmpty) return 'none';
  if (isSameSite(url, referer)) {
    return _hostOf(url) == _hostOf(referer) ? 'same-origin' : 'same-site';
  }
  return 'cross-site';
}

String _hostOf(String url) => Uri.tryParse(url)?.host.toLowerCase() ?? '';

bool _hasKey(Map<String, String> headers, String name) {
  return headers.keys.any(
    (String key) => key.toLowerCase() == name.toLowerCase(),
  );
}

String? _valueOf(Map<String, String> headers, String name) {
  for (final MapEntry<String, String> entry in headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
  }
  return null;
}
