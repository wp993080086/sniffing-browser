import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/features/downloader/domain/download_status.dart';
import 'package:sniffing_browser/features/downloader/domain/download_task.dart';
import 'package:sniffing_browser/features/downloader/presentation/library_page.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_type.dart';

DownloadTask _task(
  String name,
  MediaType type, {
  DownloadStatus status = DownloadStatus.completed,
  bool withFile = true,
}) {
  final DownloadTask task = DownloadTask(
    id: name,
    mediaId: 'm_$name',
    url: 'https://example.com/$name',
    type: type,
    fileName: name,
    createdAt: DateTime(2026, 11, 23),
  );
  if (withFile) task.complete('/tmp/$name', containerExt: 'mp4');
  if (status != DownloadStatus.completed) task.setStatus(status);
  return task;
}

void main() {
  test('只有已完成且有文件的任务进下载库', () {
    final DownloadQueueTasks tasks = DownloadQueueTasks(<DownloadTask>[
      _task('a.mp4', MediaType.video),
      _task('b.mp4', MediaType.video, status: DownloadStatus.running),
      _task('c.mp4', MediaType.video, withFile: false)
        ..setStatus(DownloadStatus.completed),
    ]);

    expect(tasks.completed.map((DownloadTask t) => t.fileName), <String>[
      'a.mp4',
    ]);
  });

  test('HLS / DASH 合并产物归到视频组', () {
    expect(groupFor(MediaType.video), LibraryGroup.video);
    expect(groupFor(MediaType.hls), LibraryGroup.video);
    expect(groupFor(MediaType.dash), LibraryGroup.video);
    expect(groupFor(MediaType.audio), LibraryGroup.audio);
    expect(groupFor(MediaType.image), LibraryGroup.image);
    expect(groupFor(MediaType.other), LibraryGroup.other);
  });

  testWidgets('空库时显示引导文案', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: LibraryPage()),
      ),
    );
    await tester.pump();

    expect(find.text('下载库'), findsOneWidget);
    expect(find.text('下载库还是空的'), findsOneWidget);
    expect(find.text('下载完成的文件会出现在这里'), findsOneWidget);
  });
}
