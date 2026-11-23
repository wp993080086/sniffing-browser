import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../logging/app_log.dart';
import 'platform_info.dart';

/// Cookie 的展示用摘要。**不保存 value** —— 那是登录凭证，
/// 只在下载时按 URL 现取并注入请求头，绝不落到界面或日志里。
class CookieSummary {
  const CookieSummary({
    required this.name,
    this.domain,
    this.expires,
    this.isSessionOnly,
    this.isSecure,
    this.isHttpOnly,
  });

  final String name;
  final String? domain;
  final DateTime? expires;
  final bool? isSessionOnly;
  final bool? isSecure;
  final bool? isHttpOnly;

  /// 有明确过期时间、且还没过期 —— 「下次自动登录」靠的就是这种 Cookie。
  bool get isPersistent =>
      expires != null && expires!.isAfter(DateTime.now());

  String get expiryLabel {
    final DateTime? value = expires;
    if (value == null) return isSessionOnly == true ? '仅本次会话' : '未标注过期时间';
    return value.toLocal().toString().substring(0, 16);
  }
}

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

  /// 只有 Android 的 CookieManager 在本项目里被验证过。
  /// 其余平台返回空列表，UI 给出说明而不是报一个平台异常。
  static bool get isSupported => PlatformInfo.current == AppPlatform.android;

  /// 返回 `name=value; name2=value2`，取不到给 null。
  static Future<String?> forUrl(String url) async {
    if (!isSupported) return null;

    try {
      final List<Cookie> cookies = await CookieManager.instance().getCookies(
        url: WebUri(url),
      );
      if (cookies.isEmpty) return null;
      return cookies.map((Cookie c) => '${c.name}=${c.value}').join('; ');
    } catch (e) {
      // 取不到就当作没有，让下载按原样发；把异常抛出去只会让用户看到
      // 一个与真实原因无关的报错。但必须留日志：否则后续 403 时
      // 根本看不出是 Cookie 没取到还是站点真的拒绝。
      logWarn('Cookie', '按 URL 读取 Cookie 失败 $url: $e');
      return null;
    }
  }

  /// 列出某个站点会被一起带上的 Cookie（只含名字和时效）。
  static Future<List<CookieSummary>> forSite(String url) async {
    if (!isSupported) return const <CookieSummary>[];
    try {
      final List<Cookie> cookies = await CookieManager.instance().getCookies(
        url: WebUri(url),
      );
      return cookies.map(_summarize).toList();
    } catch (e) {
      logWarn('Cookie', '读取站点 Cookie 摘要失败 $url: $e');
      return const <CookieSummary>[];
    }
  }

  /// 全部 Cookie。按域名分组展示用，不暴露值。
  static Future<List<CookieSummary>> all() async {
    if (!isSupported) return const <CookieSummary>[];
    try {
      final List<Cookie> cookies = await CookieManager.instance().getAllCookies();
      return cookies.map(_summarize).toList();
    } catch (e) {
      logWarn('Cookie', '读取全部 Cookie 失败: $e');
      return const <CookieSummary>[];
    }
  }

  /// 清掉这个 URL 生效范围内的 Cookie。返回是否真的删了。
  static Future<bool> clearSite(String url) async {
    if (!isSupported) return false;
    try {
      return await CookieManager.instance().deleteCookies(url: WebUri(url));
    } catch (e) {
      logWarn('Cookie', '清除站点 Cookie 失败 $url: $e');
      return false;
    }
  }

  /// 清掉 WebView 的全部登录态。
  static Future<bool> clearAll() async {
    if (!isSupported) return false;
    try {
      return await CookieManager.instance().deleteAllCookies();
    } catch (e) {
      logWarn('Cookie', '清除全部 Cookie 失败: $e');
      return false;
    }
  }

  static CookieSummary _summarize(Cookie c) => CookieSummary(
        name: c.name,
        domain: c.domain,
        expires:
            c.expiresDate == null ? null : DateTime.fromMillisecondsSinceEpoch(c.expiresDate!),
        isSessionOnly: c.isSessionOnly,
        isSecure: c.isSecure,
        isHttpOnly: c.isHttpOnly,
      );
}
