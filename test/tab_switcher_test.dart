import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/app/providers.dart';
import 'package:sniffingbrowser/features/browser/presentation/tab_switcher.dart';
import 'package:sniffingbrowser/features/browser/providers/browser_tab.dart';
import 'package:sniffingbrowser/features/browser/providers/tab_manager.dart';

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
    final BrowserTab home = tabs.homeTab;
    tabs.createTab(url: 'https://example.com/b');
    expect(tabs.activeId, isNot(home.id));

    await _pumpEntry(tester, tabs);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    // 起始页卡片 + 网页页签卡片，都渲染出来了。
    expect(find.text('起始页'), findsOneWidget);
    expect(find.text('嗅探浏览器'), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('未命名页面'), findsOneWidget);
    // 头部的计数只算网页页签。
    expect(find.text('1'), findsWidgets);

    // 两栏：两张卡片不在同一列。
    final double homeX = tester.getCenter(find.text('起始页')).dx;
    final double siteX = tester.getCenter(find.text('example.com')).dx;
    expect((homeX - siteX).abs(), greaterThan(40));

    await tester.tap(find.text('起始页'));
    await tester.pumpAndSettle();

    expect(tabs.activeId, home.id);
    // 选中后面板自动关闭。
    expect(find.text('起始页'), findsNothing);
  });

  testWidgets('卡片上的叉能关掉页签，面板不关', (WidgetTester tester) async {
    final TabManager tabs = TabManager();
    tabs.createTab(url: 'https://example.com/b');
    expect(tabs.tabCount, 1);

    await _pumpEntry(tester, tabs);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    // 起始页卡片没有关闭键，所以这里只找得到一个。
    expect(find.byTooltip('关闭页签'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭页签'));
    await tester.pumpAndSettle();

    expect(tabs.tabCount, 0);
    expect(tabs.isHomeActive, isTrue);
    // 面板还在，可以继续管理。
    expect(find.text('页签'), findsOneWidget);
  });

  testWidgets('新建按钮回到起始页并关掉面板', (WidgetTester tester) async {
    final TabManager tabs = TabManager();
    tabs.createTab(url: 'https://example.com/b');
    expect(tabs.isHomeActive, isFalse);

    await _pumpEntry(tester, tabs);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();

    // 起始页是常驻的那一个，新建不会再复制一个空白页签。
    expect(tabs.tabCount, 1);
    expect(tabs.isHomeActive, isTrue);
    expect(find.text('新建'), findsNothing);
  });
}
