import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/core/platform/webview_cookies.dart';

void main() {
  group('Cookie 展示摘要', () {
    test('带未来过期时间的 Cookie 才算持久登录态', () {
      final CookieSummary persistent = CookieSummary(
        name: 'session',
        domain: '.example.com',
        expires: DateTime.now().add(const Duration(days: 7)),
        isHttpOnly: true,
      );
      expect(persistent.isPersistent, isTrue);
      expect(persistent.expiryLabel, isNot('未标注过期时间'));
    });

    test('过期或会话 Cookie 不算持久登录态', () {
      final CookieSummary expired = CookieSummary(
        name: 'old',
        expires: DateTime.now().subtract(const Duration(days: 1)),
      );
      final CookieSummary session = CookieSummary(
        name: 'sid',
        isSessionOnly: true,
      );
      expect(expired.isPersistent, isFalse);
      expect(session.isPersistent, isFalse);
      expect(session.expiryLabel, '仅本次会话');
    });
  });
}
