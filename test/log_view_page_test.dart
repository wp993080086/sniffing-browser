import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sniffingbrowser/features/diagnostics/presentation/log_view_page.dart';

/// 预览页解决的是「导出了却看不到」：内容要在应用内铺得出来、能复制、能分享。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sniff_log_view_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// 读写文件和页面自己的读文件都是真实 IO，普通 `pump` 在 fake async 下推不动，
  /// 必须放在 [WidgetTester.runAsync] 里等。
  Future<void> pumpWithContent(
    WidgetTester tester,
    String content, {
    String title = '2026-11-24 16:30:05',
  }) async {
    final File file = File(p.join(root.path, 'log-20261124-163005.txt'));
    await tester.runAsync(() async {
      await file.writeAsString(content);
      await tester.pumpWidget(
        MaterialApp(
          home: LogViewPage(path: file.path, title: title),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();
  }

  testWidgets('铺出文件内容，空行也占高度', (WidgetTester tester) async {
    await pumpWithContent(tester, '第一行\n\n第三行');

    expect(find.text('第一行'), findsOneWidget);
    expect(find.text('第三行'), findsOneWidget);
    // 空行换成空格占位，否则日志里的分段会被吃成连续两行。
    expect(find.text(' '), findsOneWidget);
    expect(find.text('2026-11-24 16:30:05'), findsOneWidget);
  });

  testWidgets('复制按钮把全文写进剪贴板', (WidgetTester tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await pumpWithContent(tester, '甲\n乙');
    await tester.tap(find.byTooltip('复制全文'));
    await tester.pump();

    expect(copied, '甲\n乙');
  });

  testWidgets('行数超过上限时截断，并在顶部说明', (WidgetTester tester) async {
    final String content = List<String>.generate(
      20001,
      (int i) => '第 $i 行',
    ).join('\n');
    await pumpWithContent(tester, content);

    expect(find.textContaining('仅显示前 20000 行'), findsOneWidget);
    expect(find.text('内容较长，仅显示前 20000 行。复制与分享的仍是完整日志。'), findsOneWidget);
  });

  testWidgets('文件读不出来时给错误提示而不是空白', (WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: LogViewPage(path: p.join(root.path, '不存在.txt'))),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();

    expect(find.textContaining('读取失败'), findsOneWidget);
  });
}
