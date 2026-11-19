import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'platform_info.dart';

/// 从 WebView 的 CookieManager 里按 URL 取 Cookie。
///
/// 为什么必须有这一层：Android 的 `WebResourceRequest.getRequestHeaders()`
/// **不返回 Cookie** —— 那些是原生网络栈按 CookieManager 的内容自己注入的，
/// Dart 侧根本看不到。所以嗅探缓存下来的请求头里永远缺这一段，下载
/// m3u8 / m4s 这类要登录态或校验 Cookie 的地址必然 403。
///
/// 桌面不走这条路：Windows 的嗅探走 CDP，`requestWillBeSent` 的 headers
/// 自带 Cookie，Dart 侧本来就拿得到。
class WebViewCookies {
  const WebViewCookies._();

  /// 返回 `name=value; name2=value2`，取不到给 null。
  static Future<String?> forUrl(String url) async {
    if (PlatformInfo.current != AppPlatform.android) return null;

    try {
      final List<Cookie> cookies =
          await CookieManager.instance().getCookies(url: WebUri(url));
      if (cookies.isEmpty) return null;
      return cookies.map((Cookie c) => '${c.name}=${c.value}').join('; ');
    } catch (_) {
      // 取不到就当作没有，让下载按原样发；把异常抛出去只会让用户看到
      // 一个与真实原因无关的报错。
      return null;
    }
  }
}
