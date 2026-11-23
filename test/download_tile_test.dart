import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/features/downloader/domain/download_status.dart';
import 'package:sniffing_browser/features/downloader/domain/download_task.dart';
import 'package:sniffing_browser/features/downloader/presentation/download_tile.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_type.dart';

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
}
