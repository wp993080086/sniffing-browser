import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/features/sniffer/presentation/fab_position.dart';
import 'package:sniffing_browser/features/sniffer/presentation/sniff_fab.dart';

const Size _screen = Size(390, 700);

Future<ProviderContainer> _pumpFab(WidgetTester tester) async {
  tester.view.physicalSize = _screen;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final ProviderContainer container = ProviderContainer();
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: Stack(children: <Widget>[SniffFab()]),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

Rect _fabRect(WidgetTester tester) =>
    tester.getRect(find.byKey(SniffFab.buttonKey));

void main() {
  testWidgets('默认停靠右侧 16、距底 60', (WidgetTester tester) async {
    await _pumpFab(tester);

    final Rect rect = _fabRect(tester);
    expect(rect.size, const Size.square(56));
    expect(rect.right, closeTo(_screen.width - 16, 0.01));
    expect(rect.bottom, closeTo(_screen.height - 60, 0.01));
  });

  testWidgets('拖动后位置改变，且这一次运行内记住', (WidgetTester tester) async {
    final ProviderContainer container = await _pumpFab(tester);
    final Rect before = _fabRect(tester);

    await tester.drag(find.byKey(SniffFab.buttonKey), const Offset(-200, -300));
    await tester.pump();

    final Rect moved = _fabRect(tester);
    expect(moved.left, lessThan(before.left - 100));
    expect(moved.top, lessThan(before.top - 100));
    expect(container.read(sniffFabPositionProvider).offset, isNotNull);

    // 重建（切页回来、主题变化等）不该把它弹回右下角。
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Stack(children: <Widget>[SniffFab()]),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(_fabRect(tester), moved);
  });

  testWidgets('拖出边界会被夹住，四边至少留 16', (WidgetTester tester) async {
    await _pumpFab(tester);

    await tester.drag(find.byKey(SniffFab.buttonKey), const Offset(2000, 2000));
    await tester.pump();

    final Rect rect = _fabRect(tester);
    expect(rect.right, closeTo(_screen.width - 16, 0.01));
    expect(rect.bottom, closeTo(_screen.height - 16, 0.01));

    await tester.drag(find.byKey(SniffFab.buttonKey), const Offset(-2000, -2000));
    await tester.pump();

    final Rect corner = _fabRect(tester);
    expect(corner.left, closeTo(16, 0.01));
    expect(corner.top, closeTo(16, 0.01));
  });

  testWidgets('reset 之后回默认右下角（模拟重启语义）', (WidgetTester tester) async {
    final ProviderContainer container = await _pumpFab(tester);

    await tester.drag(find.byKey(SniffFab.buttonKey), const Offset(-150, -150));
    await tester.pump();
    expect(_fabRect(tester).left, lessThan(_screen.width - 100));

    container.read(sniffFabPositionProvider).reset();
    await tester.pump();

    final Rect rect = _fabRect(tester);
    expect(rect.right, closeTo(_screen.width - 16, 0.01));
    expect(rect.bottom, closeTo(_screen.height - 60, 0.01));
  });

  testWidgets('点一下打开资源面板', (WidgetTester tester) async {
    await _pumpFab(tester);

    await tester.tap(find.byKey(SniffFab.buttonKey));
    await tester.pumpAndSettle();

    expect(find.text('捕获到的资源'), findsOneWidget);
  });
}
