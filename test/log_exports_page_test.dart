import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/core/platform/storage_paths.dart';
import 'package:sniffing_browser/features/diagnostics/data/log_exporter.dart';
import 'package:sniffing_browser/features/diagnostics/presentation/log_exports_page.dart';
import 'package:sniffing_browser/features/diagnostics/presentation/log_view_page.dart';

/// 导出记录页：让「上次导出的那份」还能翻回来，不用为了排同一次故障再导一遍。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sniff_log_exports_');
    await StoragePaths.initWithRoot(root);
  });

  tearDown(() async {
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {
      // Windows 上预览页可能还占着文件句柄，临时目录留给系统清理。
    }
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: LogExportsPage()));
      // 列文件、读大小都是真实 IO，fake async 下推不动。
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();
  }

  testWidgets('没导出过时给一句引导', (WidgetTester tester) async {
    await pumpPage(tester);

    expect(find.textContaining('还没有导出过日志'), findsOneWidget);
  });

  testWidgets('按时间倒序列出导出文件', (WidgetTester tester) async {
    await tester.runAsync(() async {
      await LogExporter.write('旧', now: DateTime(2026, 11, 24, 16, 30, 5));
      await LogExporter.write('新', now: DateTime(2026, 11, 24, 17, 0, 0));
    });
    await pumpPage(tester);

    expect(find.text('2026-11-24 17:00:00'), findsOneWidget);
    expect(find.text('2026-11-24 16:30:05'), findsOneWidget);

    // 新导出的排在上面，否则每次都要先找一遍。
    final double newer = tester.getTopLeft(find.text('2026-11-24 17:00:00')).dy;
    final double older = tester.getTopLeft(find.text('2026-11-24 16:30:05')).dy;
    expect(newer, lessThan(older));
  });

  testWidgets('点某份导出直接进应用内预览', (WidgetTester tester) async {
    await tester.runAsync(() async {
      await LogExporter.write(
        '导出内容 ABC',
        now: DateTime(2026, 11, 24, 16, 30, 5),
      );
    });
    await pumpPage(tester);

    await tester.tap(find.text('2026-11-24 16:30:05'));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 只验「点进去到了预览页」：内容渲染由 log_view_page_test 覆盖，
    // 这里再读一遍文件只会把真实 IO 的时序问题混进来。
    expect(find.byType(LogViewPage), findsOneWidget);
  });
}
