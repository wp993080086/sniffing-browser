import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/features/browser/presentation/browser_header.dart';

Future<void> _pumpHeader(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              BrowserHeader(onNavigate: (String value) {}),
              const Spacer(),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('顶栏分两层：上面导航与地址栏，下面功能入口', (WidgetTester tester) async {
    await _pumpHeader(tester, const Size(390, 844));

    // 第一层
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byTooltip('后退'), findsOneWidget);
    expect(find.byTooltip('前进'), findsOneWidget);
    expect(find.byTooltip('刷新'), findsOneWidget);

    // 第二层
    expect(find.text('百度'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    expect(find.byTooltip('设置'), findsOneWidget);
    // 日志只留「设置 → 排查」一个入口，顶栏不再有虫形图标。
    expect(find.byTooltip('诊断日志'), findsNothing);
    expect(find.byIcon(Icons.bug_report_outlined), findsNothing);
    // 页签入口只数网页页签，起始页不算 —— 停在起始页时就是 0。
    expect(find.byTooltip('页签（0 个）'), findsOneWidget);

    // 嗅探入口在右下角悬浮按钮上，不在顶栏（见 sniff_fab_test.dart）。
    expect(find.text('嗅探'), findsNothing);

    final Offset field = tester.getCenter(find.byType(TextField));
    final Offset engine = tester.getCenter(find.text('百度'));
    final Offset download = tester.getCenter(find.text('下载'));

    // 功能入口整体在地址栏下方，且引擎与下载同一行。
    expect(engine.dy, greaterThan(field.dy));
    expect(download.dy, greaterThan(field.dy));
    expect((engine.dy - download.dy).abs(), lessThan(1));

    // 引擎在最左，功能按钮靠右。
    expect(engine.dx, lessThan(download.dx));

    // 两层加起来不该比原来的 52px 单层高太多。
    final double headerHeight = tester
        .getSize(find.byType(BrowserHeader))
        .height;
    expect(headerHeight, lessThan(110));
  });

  testWidgets('窄屏 320 宽不溢出', (WidgetTester tester) async {
    await _pumpHeader(tester, const Size(320, 640));

    expect(tester.takeException(), isNull);
    expect(find.text('下载'), findsOneWidget);
  });
}
