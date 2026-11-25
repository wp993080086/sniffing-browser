import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/features/browser/providers/browser_provider.dart';

void main() {
  late BrowserController browser;

  setUp(() => browser = BrowserController());
  tearDown(() => browser.dispose());

  group('normalizeInput', () {
    test('空输入返回空串（回自写首页）', () {
      expect(browser.normalizeInput('   '), '');
    });

    test('带协议的地址原样返回', () {
      expect(
        browser.normalizeInput('https://example.com/a.mp4'),
        'https://example.com/a.mp4',
      );
      expect(
        browser.normalizeInput('http://example.com'),
        'http://example.com',
      );
    });

    test('域名补 https', () {
      expect(
        browser.normalizeInput('example.com/x.jpg'),
        'https://example.com/x.jpg',
      );
    });

    test('默认用百度搜索', () {
      const String keyword = 'flutter 教程';
      expect(
        browser.normalizeInput(keyword),
        'https://www.baidu.com/s?wd=${Uri.encodeQueryComponent(keyword)}',
      );
    });

    test('切换到 Bing 后按 Bing 搜索', () {
      browser.setSearchEngine(SearchEngine.bing);
      expect(
        browser.normalizeInput('flutter'),
        'https://www.bing.com/search?q=flutter',
      );
    });
  });

  group('首页状态流转', () {
    test('导航到网址后离开首页', () async {
      await browser.navigate('example.com');
      expect(browser.isHomePage, isFalse);
      expect(browser.currentUrl, 'https://example.com');
    });

    test('空输入导航回首页', () async {
      await browser.navigate('example.com');
      await browser.navigate('  ');
      expect(browser.isHomePage, isTrue);
      expect(browser.currentUrl, '');
    });
  });
}
