import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/features/browser/providers/browser_tab.dart';
import 'package:sniffing_browser/features/browser/providers/tab_manager.dart';

void main() {
  group('常驻起始页', () {
    test('启动时只有起始页，没有网页页签，也不占 WebView', () {
      final TabManager tabs = TabManager();

      expect(tabs.tabs.length, 1);
      expect(tabs.tabCount, 0, reason: '起始页不算用户开出来的窗口');
      expect(tabs.isHomeActive, isTrue);
      expect(tabs.homeTab.pinned, isTrue);
      // 起始页是 Flutter 画的，底下不需要 WebView。
      expect(tabs.liveTabs, isEmpty);

      tabs.dispose();
    });

    test('起始页关不掉', () {
      final TabManager tabs = TabManager();

      tabs.closeTab(tabs.homeTab.id);

      expect(tabs.tabs.length, 1);
      expect(tabs.isHomeActive, isTrue);

      tabs.dispose();
    });

    test('在起始页输入地址会新开页签，起始页留在原地', () async {
      final TabManager tabs = TabManager();
      final BrowserTab home = tabs.homeTab;

      await tabs.navigate('https://example.com/x');

      expect(tabs.tabCount, 1);
      expect(tabs.isHomeActive, isFalse);
      expect(tabs.currentUrl, 'https://example.com/x');
      expect(tabs.tabs.first.id, home.id, reason: '起始页必须还在原位');
      expect(tabs.activeId, isNot(home.id));

      tabs.dispose();
    });

    test('新建空白页签等价于回起始页，不会多出一个空白窗口', () {
      final TabManager tabs = TabManager();
      final BrowserTab? page = tabs.createTab(url: 'https://example.com/');
      expect(page, isNotNull);

      final BrowserTab? back = tabs.createTab();

      expect(back!.id, tabs.homeTab.id);
      expect(tabs.activeId, tabs.homeTab.id);
      expect(tabs.tabCount, 1, reason: '只算那个网页页签');

      tabs.dispose();
    });

    test('关光所有网页页签后落回起始页', () {
      final TabManager tabs = TabManager();
      final BrowserTab a = tabs.createTab(url: 'https://a.example/')!;
      final BrowserTab b = tabs.createTab(url: 'https://b.example/')!;

      tabs.closeTab(b.id);
      tabs.closeTab(a.id);

      expect(tabs.tabCount, 0);
      expect(tabs.isHomeActive, isTrue);

      tabs.dispose();
    });
  });

  group('页签生命周期', () {
    test('新建页签会切过去，并记住它要加载的地址', () {
      final TabManager tabs = TabManager();
      final BrowserTab home = tabs.homeTab;

      final BrowserTab? page = tabs.createTab(url: 'https://example.com/a');

      expect(page, isNotNull);
      expect(tabs.tabCount, 1);
      expect(tabs.activeId, page!.id);
      expect(page.pendingUrl, 'https://example.com/a');
      // 从外部地址进来的页签不该被起始页盖住。
      expect(page.page.isHomePage, isFalse);
      expect(home.page.isHomePage, isTrue);

      tabs.dispose();
    });

    test('关闭当前页签后落到相邻的那个', () {
      final TabManager tabs = TabManager();
      final BrowserTab first = tabs.createTab(url: 'https://a.example/')!;
      final BrowserTab second = tabs.createTab(url: 'https://b.example/')!;

      tabs.closeTab(second.id);

      expect(tabs.tabCount, 1);
      expect(tabs.activeId, first.id);

      tabs.dispose();
    });

    test('页签数到上限后拒绝新建，上限不含起始页', () {
      final TabManager tabs = TabManager(maxTabs: 2);

      expect(tabs.createTab(url: 'https://a.example/'), isNotNull);
      expect(tabs.createTab(url: 'https://b.example/'), isNotNull);
      expect(tabs.createTab(url: 'https://c.example/'), isNull);
      expect(tabs.tabCount, 2);

      tabs.dispose();
    });
  });

  group('嗅探结果按页签隔离', () {
    test('各页签只看到自己捕获的资源', () {
      final TabManager tabs = TabManager();
      final BrowserTab first = tabs.createTab(url: 'https://a.example/')!;
      first.sniffer.capture(url: 'https://a.example/1.jpg');

      final BrowserTab second = tabs.createTab(url: 'https://b.example/')!;
      second.sniffer.capture(url: 'https://b.example/2.mp4');

      expect(tabs.activeSniffer.count, 1);
      expect(tabs.activeSniffer.items.first.url, 'https://b.example/2.mp4');

      tabs.activateTab(first.id);

      expect(tabs.activeSniffer.count, 1);
      expect(tabs.activeSniffer.items.first.url, 'https://a.example/1.jpg');

      tabs.dispose();
    });
  });

  group('存活 WebView 的回收', () {
    test('超过 maxLive 时淘汰最久没被看过的页签，但页签本身还在', () {
      final TabManager tabs = TabManager(maxLive: 2);
      final BrowserTab first = tabs.createTab(url: 'https://one.example/')!;

      final BrowserTab second = tabs.createTab(url: 'https://two.example/')!;
      expect(second.id, isNot(first.id));

      final BrowserTab third = tabs.createTab(url: 'https://three.example/')!;

      expect(tabs.tabCount, 3);
      expect(tabs.liveTabs.length, 2);
      expect(
        tabs.liveTabs.any((BrowserTab tab) => tab.id == first.id),
        isFalse,
        reason: '最久没活跃的页签应该被回收',
      );
      // 现场要留下来，重新激活时靠它恢复。
      expect(first.pendingUrl, 'https://one.example/');
      expect(third.id, tabs.activeId);

      tabs.dispose();
    });

    test('重新激活被回收的页签会重新占一个存活位', () {
      final TabManager tabs = TabManager(maxLive: 2);
      final BrowserTab first = tabs.createTab(url: 'https://one.example/')!;

      tabs.createTab(url: 'https://two.example/');
      tabs.createTab(url: 'https://three.example/');

      expect(
        tabs.liveTabs.any((BrowserTab tab) => tab.id == first.id),
        isFalse,
      );

      tabs.activateTab(first.id);

      expect(tabs.liveTabs.length, 2);
      expect(tabs.liveTabs.any((BrowserTab tab) => tab.id == first.id), isTrue);
      expect(tabs.activeId, first.id);

      tabs.dispose();
    });
  });

  group('搜索引擎', () {
    test('切换后同步到每个页签，地址栏输入才会用同一个引擎', () {
      final TabManager tabs = TabManager();
      final BrowserTab first = tabs.createTab(url: 'https://a.example/')!;
      final BrowserTab second = tabs.createTab(url: 'https://b.example/')!;

      tabs.setSearchEngine(SearchEngine.bing);

      expect(tabs.searchEngine, SearchEngine.bing);
      expect(first.page.searchEngine, SearchEngine.bing);
      expect(second.page.searchEngine, SearchEngine.bing);

      tabs.dispose();
    });
  });

  group('返回手势', () {
    test('没有 WebView 时退不动，交给系统处理', () async {
      final TabManager tabs = TabManager();

      expect(await tabs.handleBack(), isFalse);

      tabs.dispose();
    });
  });
}
