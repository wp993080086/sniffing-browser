import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/core/platform/browser_headers.dart';

void main() {
  group('withBrowserHeaders', () {
    test('补齐浏览器该带而 Dart 不带的头', () {
      final Map<String, String> out = withBrowserHeaders(<String, String>{
        'Referer': 'https://missav.ws/a',
      }, url: 'https://b.surrit.com/a.m3u8');

      expect(out['Accept'], '*/*');
      expect(out['Accept-Language'], contains('zh-CN'));
      expect(out['Sec-Fetch-Site'], 'cross-site');
      expect(out['sec-ch-ua'], contains('Chromium'));
      expect(out['Referer'], 'https://missav.ws/a');
    });

    test('同主机判成 same-origin，同注册域判成 same-site', () {
      expect(
        browserHeaders(
          url: 'https://a.site.com/x',
          referer: 'https://a.site.com/p',
        )['Sec-Fetch-Site'],
        'same-origin',
      );
      expect(
        browserHeaders(
          url: 'https://a.site.com/x',
          referer: 'https://b.site.com/p',
        )['Sec-Fetch-Site'],
        'same-site',
      );
    });

    test('没有 Referer 时是 none', () {
      expect(browserHeaders(url: 'https://a.com/x')['Sec-Fetch-Site'], 'none');
    });

    test('已有的头不覆盖', () {
      final Map<String, String> out = withBrowserHeaders(<String, String>{
        'Accept': 'image/avif',
      }, url: 'https://a.com/x');

      expect(out['Accept'], 'image/avif');
    });

    test('头已齐时返回同一个实例，调用方据此跳过重试', () {
      final Map<String, String> base = <String, String>{
        'Referer': 'https://a.com/p',
      };
      final Map<String, String> once = withBrowserHeaders(
        base,
        url: 'https://a.com/x',
      );

      expect(
        identical(withBrowserHeaders(once, url: 'https://a.com/x'), once),
        isTrue,
      );
    });
  });

  group('withNeutralUserAgent', () {
    test('浏览器 UA 换成中性 UA，并去掉客户端提示', () {
      final Map<String, String> out = withNeutralUserAgent(<String, String>{
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36',
        'sec-ch-ua': '"Chromium";v="126"',
        'Sec-Fetch-Site': 'cross-site',
        'Referer': 'https://a.com/p',
      })!;

      expect(out['User-Agent'], kNeutralUserAgent);
      expect(out.containsKey('sec-ch-ua'), isFalse);
      expect(out.containsKey('Sec-Fetch-Site'), isFalse);
      expect(out['Referer'], 'https://a.com/p');
    });

    test('本来就是中性 UA 时返回 null，不重复请求', () {
      expect(
        withNeutralUserAgent(<String, String>{'User-Agent': kNeutralUserAgent}),
        isNull,
      );
      expect(withNeutralUserAgent(const <String, String>{}), isNull);
    });
  });
}
