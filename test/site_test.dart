import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/core/utils/site.dart';

void main() {
  group('isSameSite', () {
    test('同一主机视为同站', () {
      expect(
        isSameSite('https://missav.live/cn/abc', 'https://missav.live/cn/def'),
        isTrue,
      );
    });

    test('子域与主域视为同站', () {
      expect(
        isSameSite('https://www.missav.live/a', 'https://missav.live/b'),
        isTrue,
      );
    });

    test('不同注册域视为跨站', () {
      // 这就是 popunder 的形态：正片页 → 广告落地页。
      expect(
        isSameSite('https://wheelroot.com/api/v1/direct/x', 'https://missav.live/cn/1'),
        isFalse,
      );
    });

    test('常见两级后缀按三段比较', () {
      expect(
        isSameSite('https://a.example.com.cn/x', 'https://b.example.com.cn/y'),
        isTrue,
      );
      expect(
        isSameSite('https://example.com.cn/x', 'https://other.com.cn/y'),
        isFalse,
      );
    });

    test('IP 整体比较', () {
      expect(
        isSameSite('http://192.168.1.10:8080/a', 'http://192.168.1.10/b'),
        isTrue,
      );
      expect(
        isSameSite('http://192.168.1.10/a', 'http://192.168.1.11/b'),
        isFalse,
      );
    });

    test('解析不出主机名时按同站处理（宁可不拦）', () {
      expect(isSameSite('about:blank', 'https://missav.live'), isTrue);
      expect(isSameSite('', ''), isTrue);
    });
  });
}
