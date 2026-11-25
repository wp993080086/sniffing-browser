import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/features/downloader/domain/download_status.dart';
import 'package:sniffingbrowser/features/downloader/domain/download_task.dart';
import 'package:sniffingbrowser/features/downloader/presentation/download_tile.dart';
import 'package:sniffingbrowser/features/sniffer/domain/media_type.dart';

DownloadTask _task({required bool completed}) {
  final DownloadTask task = DownloadTask(
    id: 't1',
    mediaId: 'm1',
    url: 'https://example.com/a.mp4',
    type: MediaType.video,
    fileName: 'a.mp4',
    createdAt: DateTime(2026, 11, 13),
  );
  if (completed) {
    task.complete('/tmp/sniff/a.mp4', containerExt: 'mp4');
  }
  return task;
}

/// 打开菜单，把菜单项文字捞出来。
Future<List<String>> _menuItems(WidgetTester tester, DownloadTask task) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: DownloadTile(task: task)),
      ),
    ),
  );
  await tester.tap(find.byIcon(Icons.more_vert));
  // 不用 pumpAndSettle：未完成任务的进度条是不确定动画，永不停止。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return tester
      .widgetList<Text>(
        find.descendant(
          of: find.byType(PopupMenuItem<String>),
          matching: find.byType(Text),
        ),
      )
      .map((Text t) => t.data ?? '')
      .toList();
}

void main() {
  testWidgets('已完成的任务有「打开」入口', (WidgetTester tester) async {
    final List<String> items = await _menuItems(tester, _task(completed: true));

    expect(items, contains('打开'));
  });

  testWidgets('还没下完的任务没有「打开」', (WidgetTester tester) async {
    final List<String> items = await _menuItems(
      tester,
      _task(completed: false),
    );

    expect(items, isNot(contains('打开')));
  });

  testWidgets('下载中的任务有「暂停」和「取消」，没有「继续」', (WidgetTester tester) async {
    final DownloadTask task = _task(completed: false)
      ..setStatus(DownloadStatus.running);
    final List<String> items = await _menuItems(tester, task);

    expect(items, contains('暂停'));
    expect(items, contains('取消'));
    expect(items, isNot(contains('继续')));
  });

  testWidgets('暂停中的任务有「继续」，没有「取消」', (WidgetTester tester) async {
    final DownloadTask task = _task(completed: false)
      ..setStatus(DownloadStatus.paused);
    final List<String> items = await _menuItems(tester, task);

    expect(items, contains('继续'));
    expect(items, isNot(contains('取消')));
  });

  testWidgets('HLS 任务同时显示分片进度和百分比', (WidgetTester tester) async {
    final DownloadTask task = DownloadTask(
      id: 'h1',
      mediaId: 'm-h1',
      url: 'https://example.com/video.m3u8',
      type: MediaType.hls,
      fileName: 'video.ts',
      createdAt: DateTime(2026, 11, 19),
      isStream: true,
    )..setStatus(DownloadStatus.running);
    task.updateSegments(206, 430);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: DownloadTile(task: task)),
        ),
      ),
    );
    // 未完成任务的进度条是不确定动画，不能 pumpAndSettle。
    await tester.pump();

    // 206 / 430 = 47.9%，四舍五入到 48。
    expect(find.text('206/430 分片 · 48%'), findsOneWidget);
  });

  testWidgets('流媒体任务显示已下载大小与估算总大小', (WidgetTester tester) async {
    final DownloadTask task = DownloadTask(
      id: 'h2',
      mediaId: 'm-h2',
      url: 'https://example.com/video.mpd',
      type: MediaType.dash,
      fileName: 'manifest.mpd',
      createdAt: DateTime(2026, 11, 23),
      isStream: true,
    )..setStatus(DownloadStatus.running);
    task.updateSegments(5, 10, bytes: 1024);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: DownloadTile(task: task)),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('已下载 1.0 KB / 约 2.0 KB'), findsOneWidget);
  });

  testWidgets('等待网络显示按秒倒计时，进度条停在断点处', (WidgetTester tester) async {
    final DownloadTask task = _task(completed: false)
      ..updateBytes(50, 100)
      ..waitForNetwork(const Duration(seconds: 10));

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: DownloadTile(task: task)),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('秒后自动重试'), findsOneWidget);
    final LinearProgressIndicator bar = tester.widget(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.5, 1e-9));

    // 卸载卡片，把每秒刷新的定时器停掉。
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('403 等待的文案是站点拒绝，不再说等待网络', (WidgetTester tester) async {
    final DownloadTask task = _task(completed: false)
      ..updateBytes(50, 100)
      ..waitForNetwork(const Duration(seconds: 10), reason: '站点拒绝访问');

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: DownloadTile(task: task)),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('站点拒绝访问'), findsOneWidget);
    expect(find.textContaining('等待网络'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('失败时进度停在断点，重试不会从 0 跳回来', (WidgetTester tester) async {
    final DownloadTask task = _task(completed: false)
      ..updateBytes(50, 100)
      ..fail('网络错误');

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: DownloadTile(task: task)),
        ),
      ),
    );
    await tester.pump();

    final LinearProgressIndicator bar = tester.widget(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.5, 1e-9));
  });
}
