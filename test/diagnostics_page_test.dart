import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/core/logging/app_log.dart';
import 'package:sniffingbrowser/core/platform/storage_paths.dart';
import 'package:sniffingbrowser/features/diagnostics/presentation/diagnostics_page.dart';
import 'package:sniffingbrowser/features/diagnostics/presentation/log_exports_page.dart';
import 'package:sniffingbrowser/features/diagnostics/presentation/log_view_page.dart';

/// 日志页的关键行为：条数太多时能按关键字和级别收敛到想看的那几条。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sniff_log_page_');
    await StoragePaths.initWithRoot(root);
    AppLog.instance.resetForTesting();

    logInfo('Sniffer', '捕获到 m3u8 资源');
    logWarn('Download', '第 3 个分片失败');
    logError('Download', '403 站点拒绝');
  });

  tearDown(() async {
    // 不 reset 的话，日志的 flush 定时器会让 testWidgets 报「Timer still pending」。
    AppLog.instance.resetForTesting();
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {
      // Windows 上预览页可能还占着文件句柄，临时目录留给系统清理。
    }
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: DiagnosticsPage()));
    await tester.pump();
  }

  int logRows(WidgetTester tester) =>
      tester.widgetList(find.byType(SelectableText)).length;

  testWidgets('默认展示全部日志', (WidgetTester tester) async {
    await pumpPage(tester);

    expect(logRows(tester), 3);
    expect(find.text('运行日志'), findsOneWidget);
  });

  testWidgets('关键字搜索按 tag 与正文匹配', (WidgetTester tester) async {
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), '403');
    await tester.pump();

    expect(logRows(tester), 1);
    expect(findLog('403 站点拒绝'), findsOneWidget);
  });

  testWidgets('搜索不到时给出提示', (WidgetTester tester) async {
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), '不存在的关键字');
    await tester.pump();

    expect(logRows(tester), 0);
    expect(find.text('没有匹配的日志'), findsOneWidget);
  });

  testWidgets('级别过滤只看警告以上', (WidgetTester tester) async {
    await pumpPage(tester);

    await tester.tap(find.byIcon(Icons.filter_alt_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('警告以上').last);
    await tester.pumpAndSettle();

    expect(logRows(tester), 2);
    expect(findLog('捕获到 m3u8 资源'), findsNothing);
  });

  testWidgets('级别过滤只看错误', (WidgetTester tester) async {
    await pumpPage(tester);

    await tester.tap(find.byIcon(Icons.filter_alt_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅错误').last);
    await tester.pumpAndSettle();

    expect(logRows(tester), 1);
    expect(findLog('403 站点拒绝'), findsOneWidget);
  });

  testWidgets('导出后直接进应用内预览，不再只弹分享面板', (WidgetTester tester) async {
    await pumpPage(tester);

    // 导出要写真实文件，fake async 下推不动，必须放到 runAsync 里等。
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('导出为 txt'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(LogViewPage), findsOneWidget);
  });

  testWidgets('更多菜单里有导出记录入口', (WidgetTester tester) async {
    await pumpPage(tester);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('导出记录'), findsOneWidget);

    await tester.tap(find.text('导出记录'));
    await tester.pumpAndSettle();

    expect(find.byType(LogExportsPage), findsOneWidget);
  });
}

/// 日志正文在 [SelectableText.rich] 的 TextSpan 里，普通 `find.textContaining`
/// 认不出来，得自己摊平了找。
Finder findLog(String needle) => find.byWidgetPredicate((Widget widget) {
  if (widget is! SelectableText) return false;
  final String text = widget.textSpan?.toPlainText() ?? widget.data ?? '';
  return text.contains(needle);
});
