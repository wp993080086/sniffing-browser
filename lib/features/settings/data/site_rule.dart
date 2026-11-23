/// 按域名覆盖下载请求头的规则。
///
/// 只在自动请求头明显不够时用：自动那套（嗅探缓存头 + WebView Cookie +
/// 403 换头）已经覆盖了绝大多数站点，规则是给极少数特例兜底的。
///
/// 不存 Cookie：Cookie 是登录凭证，明文写进 settings.json 风险太大，而且
/// 会自动过期。登录态仍走 WebView 的 CookieManager 现取。规则只管
/// UA / Referer / 额外请求头这三类「不会过期、也不敏感」的东西。
class SiteRule {
  const SiteRule({
    required this.domain,
    this.userAgent = '',
    this.referer = '',
    this.headers = const <String, String>{},
  });

  /// 匹配的域名，例如 `example.com` 或 `cdn.example.com`。
  /// 支持子域：`example.com` 也能匹配 `v.example.com`。
  final String domain;
  final String userAgent;
  final String referer;

  /// 额外请求头，逐项覆盖嗅探到的值。键名大小写不敏感。
  final Map<String, String> headers;

  bool get isValid => domain.trim().isNotEmpty;

  static SiteRule fromJson(Map<String, Object?> json) {
    String text(String key) {
      final Object? value = json[key];
      return value == null ? '' : '$value'.trim();
    }

    final Map<String, String> headers = <String, String>{};
    final Object? rawHeaders = json['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((Object? key, Object? value) {
        if (key == null || value == null) return;
        headers['$key'] = '$value';
      });
    }

    return SiteRule(
      domain: text('domain'),
      userAgent: text('userAgent'),
      referer: text('referer'),
      headers: headers,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'domain': domain,
    'userAgent': userAgent,
    'referer': referer,
    'headers': headers,
  };
}

/// URL 是否命中规则。用项目已有的注册域归一，避免手写
/// `endsWith('.$domain')` 在带端口、带路径的 URL 上出错。
bool ruleMatches(SiteRule rule, String url) {
  final String host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return false;
  final String domain = rule.domain.trim().toLowerCase();
  if (domain.isEmpty) return false;

  if (host == domain) return true;
  // 只用「点号边界」的后缀匹配，防 `evil-example.com` 命中 `example.com`。
  return host.endsWith('.$domain');
}

/// 把命中的规则套到请求头上。
///
/// 覆盖顺序：规则 > 嗅探缓存头 > 自动补全。cookie 归 WebView 现取，这里不碰；
/// 规则里若真填了 Cookie（从 JSON 恢复的老数据），也会保留但不写进日志。
Map<String, String> applySiteRules(
  Map<String, String> headers,
  String url,
  Iterable<SiteRule> rules,
) {
  for (final SiteRule rule in rules) {
    if (!rule.isValid || !ruleMatches(rule, url)) continue;
    // 规则没有任何实际内容时返回原实例，让调用方省掉一次复制。
    if (rule.userAgent.isEmpty &&
        rule.referer.isEmpty &&
        rule.headers.isEmpty) {
      return headers;
    }
    final Map<String, String> result = Map<String, String>.from(headers);
    if (rule.userAgent.isNotEmpty) result['User-Agent'] = rule.userAgent;
    if (rule.referer.isNotEmpty) result['Referer'] = rule.referer;
    for (final MapEntry<String, String> entry in rule.headers.entries) {
      // 同名（忽略大小写）先删再加，避免留下两个只差大小写的头。
      result.removeWhere(
        (String key, String _) => key.toLowerCase() == entry.key.toLowerCase(),
      );
      result[entry.key] = entry.value;
    }
    return result;
  }
  return headers;
}
