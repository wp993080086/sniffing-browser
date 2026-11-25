import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/core/platform/proxy_rule.dart';

void main() {
  group('ProxyRule', () {
    test('空配置就是直连', () {
      expect(ProxyRule.direct.directiveFor(Uri.parse('https://a.com')), 'DIRECT');
    });

    test('普通 host:port 转成 PROXY 指令', () {
      const ProxyRule rule = ProxyRule(proxy: '127.0.0.1:7890');
      expect(
        rule.directiveFor(Uri.parse('https://surrit.com/v.mp4')),
        'PROXY 127.0.0.1:7890',
      );
    });

    test('带 scheme 的写法也能认，socks 走 SOCKS5', () {
      expect(
        const ProxyRule(
          proxy: 'http://127.0.0.1:7890',
        ).directiveFor(Uri.parse('https://a.com')),
        'PROXY 127.0.0.1:7890',
      );
      expect(
        const ProxyRule(
          proxy: 'socks5://127.0.0.1:1080',
        ).directiveFor(Uri.parse('https://a.com')),
        'SOCKS5 127.0.0.1:1080',
      );
    });

    test('no_proxy 支持 localhost / 后缀 / 通配', () {
      const ProxyRule rule = ProxyRule(
        proxy: '127.0.0.1:7890',
        noProxy: 'localhost, .corp.com,*.cdn.com',
      );
      expect(rule.directiveFor(Uri.parse('http://localhost:8080/x')), 'DIRECT');
      expect(
        rule.directiveFor(Uri.parse('https://a.corp.com/x')),
        'DIRECT',
        reason: '后缀规则要能匹配子域',
      );
      expect(rule.directiveFor(Uri.parse('https://img.cdn.com/x')), 'DIRECT');
      expect(
        rule.directiveFor(Uri.parse('https://surrit.com/x')),
        'PROXY 127.0.0.1:7890',
      );
      expect(
        const ProxyRule(
          proxy: '127.0.0.1:7890',
          noProxy: '*',
        ).directiveFor(Uri.parse('https://surrit.com/x')),
        'DIRECT',
      );
    });

    test('环境变量：https_proxy 优先，no_proxy 一起读', () {
      final ProxyRule rule = ProxyRule.fromEnvironment(<String, String>{
        'HTTP_PROXY': 'http://10.0.0.1:8080',
        'HTTPS_PROXY': 'http://10.0.0.2:8080',
        'NO_PROXY': '.corp.com',
      });
      expect(rule.proxy, 'http://10.0.0.2:8080');
      expect(rule.noProxy, '.corp.com');
    });

    test('环境变量为空时不会误判成代理', () {
      final ProxyRule rule = ProxyRule.fromEnvironment(<String, String>{});
      expect(rule.proxy, isEmpty);
      expect(rule.directiveFor(Uri.parse('https://a.com')), 'DIRECT');
    });
  });
}
