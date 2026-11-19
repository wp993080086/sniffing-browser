import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/app/providers.dart';
import 'package:sniffing_browser/features/browser/data/bookmark_service.dart';
import 'package:sniffing_browser/features/browser/data/history_service.dart';
import 'package:sniffing_browser/features/browser/presentation/bookmark_page.dart';
import 'package:sniffing_browser/features/browser/presentation/history_page.dart';
import 'package:sniffing_browser/features/browser/presentation/home_page.dart';

/// 用纯内存的 service 覆盖全局 provider。
///
/// 默认实现会去读写 `StoragePaths.root`，测试环境没初始化过路径，
/// 一旦触发防抖落盘就会抛 StateError。
Widget _wrap(
  Widget child, {
  HistoryService? history,
  BookmarkService? bookmarks,
}) {
  return ProviderScope(
    overrides: <Override>[
      historyProvider.overrideWith((Ref ref) => history ?? HistoryService()),
      bookmarkProvider.overrideWith(
        (Ref ref) => bookmarks ?? BookmarkService(),
      ),
    ],
    child: MaterialApp(home: child),
  );
}

void main() {
  testWidgets('首页输入框下方有历史和收藏入口', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const Scaffold(body: HomePage())));

    expect(find.text('历史记录'), findsOneWidget);
    expect(find.text('收藏夹'), findsOneWidget);
    expect(find.text('输入网址或搜索词'), findsOneWidget);
  });

  testWidgets('点「历史记录」进入历史页', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const Scaffold(body: HomePage())));

    await tester.tap(find.text('历史记录'));
    await tester.pumpAndSettle();

    expect(find.byType(HistoryPage), findsOneWidget);
  });

  testWidgets('点「收藏夹」进入收藏页', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const Scaffold(body: HomePage())));

    await tester.tap(find.text('收藏夹'));
    await tester.pumpAndSettle();

    expect(find.byType(BookmarkPage), findsOneWidget);
  });

  testWidgets('历史页按天分组并显示条目标题', (WidgetTester tester) async {
    final HistoryService history = HistoryService();
    history.record(url: 'https://a.com/x', title: '一个页面');
    history.record(url: 'https://b.com/y', title: '另一个页面');

    await tester.pumpWidget(_wrap(const HistoryPage(), history: history));

    expect(find.text('今天'), findsOneWidget);
    expect(find.text('另一个页面'), findsOneWidget);
    expect(find.text('一个页面'), findsOneWidget);
  });

  testWidgets('收藏页空态给出收藏方式', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const BookmarkPage()));

    expect(find.text('还没有收藏'), findsOneWidget);
    expect(find.text('点地址栏右侧的星标收藏当前页'), findsOneWidget);
  });
}
