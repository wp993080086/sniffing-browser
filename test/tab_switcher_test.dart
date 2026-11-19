import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/app/providers.dart';
import 'package:sniffing_browser/features/browser/presentation/tab_switcher.dart';
import 'package:sniffing_browser/features/browser/providers/browser_tab.dart';
import 'package:sniffing_browser/features/browser/providers/tab_manager.dart';

Future<void> _pumpEntry(WidgetTester tester, TabManager tabs) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[tabManagerProvider.overrideWith((Ref ref) => tabs)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showTabSwitcher(context),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('两栏展示页签，点卡片切换过去', (WidgetTester tester) async {
    final TabManager tabs = TabManager();
    final BrowserTab first = tabs.activeTab;
    tabs.createTab(url: 'https://example.com/b');
    expect(tabs.activeId, isNot(first.id));

    await _pumpEntry(tester, tabs);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    // 一个起始页 + 一个网页页签，都渲染成了卡片。
    expect(find.text('起始页'), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('未命名页面'), findsOneWidget);
    expect(find.text('2'), findsWidgets);

    // 两栏：两张卡片不在同一列。
    final double homeX = tester.getCenter(find.text('起始页')).dx;
    final double siteX = tester.getCenter(find.text('example.com')).dx;
    expect((homeX - siteX).abs(), greaterThan(40));

    await tester.tap(find.text('起始页'));
    await tester.pumpAndSettle();

    expect(tabs.activeId, first.id);
    // 选中后面板自动关闭。
    expect(find.text('起始页'), findsNothing);
  });

  testWidgets('卡片上的叉能关掉页签，面板不关', (WidgetTester tester) async {
    final TabManager tabs = TabManager();
    tabs.createTab(url: 'https://example.com/b');
    expect(tabs.tabCount, 2);

    await _pumpEntry(tester, tabs);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('关闭页签').first);
    await tester.pumpAndSettle();

    expect(tabs.tabCount, 1);
    // 面板还在，可以继续管理。
    expect(find.text('页签'), findsOneWidget);
  });

  testWidgets('新建按钮加一个页签并关掉面板', (WidgetTester tester) async {
    final TabManager tabs = TabManager();

    await _pumpEntry(tester, tabs);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();

    expect(tabs.tabCount, 2);
    expect(tabs.activeTab.page.isHomePage, isTrue);
    expect(find.text('新建'), findsNothing);
  });
}
