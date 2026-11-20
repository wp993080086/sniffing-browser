import 'dart:io';

/// HTTP 代理配置。
///
/// 存在的理由：Dart 的 `HttpClient` 不会自动读系统或环境变量里的代理，
/// 需要代理的网络环境（公司内网、本机 7890 那个端口）以前只能干瞪着直连。
class ProxyRule {
  const ProxyRule({this.proxy = '', this.noProxy = ''});

  /// 形如 `127.0.0.1:7890`。空串表示直连。
  final String proxy;

  /// 逗号分隔的直连后缀，支持 `localhost`、`.corp.com`、`*`。
  final String noProxy;

  static const ProxyRule direct = ProxyRule();

  /// 从环境变量拼一份。Android 上没有这些变量，返回 [direct]。
  ///
  /// 优先 https_proxy：本项目几乎全是 https。
  factory ProxyRule.fromEnvironment([Map<String, String>? env]) {
    final Map<String, String> vars = env ?? Platform.environment;

    String pick(List<String> keys) {
      for (final String key in keys) {
        final String? value = vars[key];
        if (value != null && value.trim().isNotEmpty) return value.trim();
      }
      return '';
    }

    return ProxyRule(
      proxy: pick(<String>[
        'https_proxy',
        'HTTPS_PROXY',
        'http_proxy',
        'HTTP_PROXY',
        'all_proxy',
        'ALL_PROXY',
      ]),
      noProxy: pick(<String>['no_proxy', 'NO_PROXY']),
    );
  }

  /// 转成 `HttpClient.findProxy` 要的指令。
  ///
  /// 接受 `127.0.0.1:7890`、`http://127.0.0.1:7890`、`socks5://127.0.0.1:1080`
  /// 三种写法 —— 用户从别处复制过来多半带着 scheme。
  String directiveFor(Uri uri) {
    if (proxy.isEmpty) return 'DIRECT';
    if (_bypasses(uri.host)) return 'DIRECT';

    String type = 'PROXY';
    String address = proxy;
    final int schemeEnd = address.indexOf('://');
    if (schemeEnd > 0) {
      final String scheme = address.substring(0, schemeEnd).toLowerCase();
      address = address.substring(schemeEnd + 3);
      if (scheme.startsWith('socks')) type = 'SOCKS5';
    }
    address = address.replaceAll(RegExp(r'/+$'), '');
    return '$type $address';
  }

  bool _bypasses(String host) {
    if (host.isEmpty || noProxy.isEmpty) return false;
    final String target = host.toLowerCase();
    for (final String raw in noProxy.split(',')) {
      final String rule = raw.trim().toLowerCase();
      if (rule.isEmpty) continue;
      if (rule == '*') return true;
      // 允许写成 `.corp.com` 或 `*.corp.com`
      final String suffix = rule
          .replaceFirst('*', '')
          .replaceFirst(RegExp(r'^\.'), '');
      if (target == suffix || target.endsWith('.$suffix')) return true;
    }
    return false;
  }
}
