import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/core/platform/storage_paths.dart';
import 'package:sniffing_browser/features/diagnostics/presentation/diagnostics_page.dart';
import 'package:sniffing_browser/features/settings/presentation/settings_page.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sniff_settings_');
    await StoragePaths.initWithRoot(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  testWidgets('设置页有运行日志入口，点了能进日志页', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SettingsPage())),
    );
    await tester.pump();

    // 设置页内容比测试视口长，入口在下面，先滚过去。
    await tester.scrollUntilVisible(
      find.text('运行日志'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final Finder entry = find.text('运行日志');
    expect(entry, findsOneWidget);

    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(DiagnosticsPage), findsOneWidget);
  });
}
