import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/features/browser/providers/browser_tab.dart';
import 'package:sniffing_browser/features/browser/providers/tab_manager.dart';

void main() {
  group('页签生命周期', () {
    test('启动时自带一个首页页签，并处于存活状态', () {
      final TabManager tabs = TabManager();

      expect(tabs.tabCount, 1);
      expect(tabs.activeTab.page.isHomePage, isTrue);
      expect(tabs.liveTabs.length, 1);
      expect(tabs.liveTabs.first.id, tabs.activeId);

      tabs.dispose();
    });

    test('新建页签会切过去，并记住它要加载的地址', () {
      final TabManager tabs = TabManager();
      final BrowserTab first = tabs.activeTab;

      final BrowserTab? second = tabs.createTab(url: 'https://example.com/a');

      expect(second, isNotNull);
      expect(tabs.tabCount, 2);
      expect(tabs.activeId, second!.id);
      expect(second.pendingUrl, 'https://example.com/a');
      // 从外部地址进来的页签不该被首页盖住。
      expect(second.page.isHomePage, isFalse);
      expect(first.page.isHomePage, isTrue);

      tabs.dispose();
    });

    test('关闭当前页签后落到相邻的那个', () {
      final TabManager tabs = TabManager();
      final BrowserTab first = tabs.activeTab;
      final BrowserTab? second = tabs.createTab();

      tabs.closeTab(second!.id);

      expect(tabs.tabCount, 1);
      expect(tabs.activeId, first.id);

      tabs.dispose();
    });

    test('关掉最后一个页签会自动补一个首页', () {
      final TabManager tabs = TabManager();
      final BrowserTab first = tabs.activeTab;

      tabs.closeTab(first.id);

      expect(tabs.tabCount, 1);
      expect(tabs.activeTab.id, isNot(first.id));
      expect(tabs.activeTab.page.isHomePage, isTrue);

      tabs.dispose();
    });

    test('页签数到上限后拒绝新建，交给调用方降级', () {
      final TabManager tabs = TabManager(maxTabs: 2);

      expect(tabs.createTab(), isNotNull);
      expect(tabs.createTab(), isNull);
      expect(tabs.tabCount, 2);

      tabs.dispose();
    });
  });

  group('嗅探结果按页签隔离', () {
    test('各页签只看到自己捕获的资源', () {
      final TabManager tabs = TabManager();
      final BrowserTab first = tabs.activeTab;
      first.sniffer.capture(url: 'https://a.example/1.jpg');

      final BrowserTab second = tabs.createTab()!;
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
      final BrowserTab first = tabs.activeTab;
      first.page.markExternal('https://one.example/');

      final BrowserTab second = tabs.createTab()!;
      second.page.markExternal('https://two.example/');

      final BrowserTab third = tabs.createTab()!;

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
      final BrowserTab first = tabs.activeTab;
      first.page.markExternal('https://one.example/');

      tabs.createTab(url: 'https://two.example/');
      tabs.createTab(url: 'https://three.example/');

      expect(tabs.liveTabs.any((BrowserTab tab) => tab.id == first.id), isFalse);

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
      final BrowserTab first = tabs.activeTab;
      final BrowserTab second = tabs.createTab()!;

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
