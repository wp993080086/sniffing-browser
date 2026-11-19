import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/core/platform/storage_paths.dart';
import 'package:sniffing_browser/features/downloader/data/download_queue.dart';
import 'package:sniffing_browser/features/downloader/data/download_store.dart';
import 'package:sniffing_browser/features/downloader/domain/download_status.dart';
import 'package:sniffing_browser/features/downloader/domain/download_task.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_type.dart';

/// 删记录时要连带清掉分片临时目录。
///
/// 这是唯一一处「任务消失但目录还在」的路径：失败和取消都要保留目录给续传，
/// 只有用户明确删掉记录才应该回收。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sniffing-tmp-clean-test');
    await StoragePaths.initWithRoot(root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  DownloadTask task(
    String id, {
    DownloadStatus status = DownloadStatus.failed,
  }) {
    final DownloadTask t = DownloadTask(
      id: id,
      mediaId: 'm-$id',
      url: 'https://example.com/$id.m3u8',
      type: MediaType.hls,
      fileName: '$id.ts',
      createdAt: DateTime(2026, 11, 19),
      isStream: true,
    );
    t.setStatus(status);
    return t;
  }

  /// 给任务准备一份「下了一半」的临时目录。
  Future<Directory> halfDownloaded(String id) async {
    final Directory dir = StoragePaths.tempDirFor(id);
    await dir.create(recursive: true);
    await File('${dir.path}/seg_0.part').writeAsBytes(<int>[1, 2, 3]);
    await File('${dir.path}/seg_1.part').writeAsBytes(<int>[4, 5, 6]);
    return dir;
  }

  Future<void> waitGone(Directory dir) async {
    for (int i = 0; i < 60 && await dir.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  Future<DownloadQueue> queueWith(List<DownloadTask> tasks) async {
    final DownloadStore store = DownloadStore(
      file: File('${root.path}/download_tasks.json'),
    );
    await store.save(tasks);
    final DownloadQueue queue = DownloadQueue(store: store);
    addTearDown(queue.dispose);
    await queue.restore();
    return queue;
  }

  test('删除记录会清掉该任务的分片目录', () async {
    final DownloadQueue queue = await queueWith(<DownloadTask>[
      task('t1'),
      task('t2'),
    ]);
    final Directory work = await halfDownloaded('t1');
    final Directory other = await halfDownloaded('t2');

    queue.remove('t1');
    await waitGone(work);

    expect(await work.exists(), isFalse);
    // 别的任务还在续传，不能误删。
    expect(await other.exists(), isTrue);
  });

  test('清空已结束任务会一并清目录', () async {
    final DownloadQueue queue = await queueWith(<DownloadTask>[
      task('done', status: DownloadStatus.completed),
      task('failed'),
    ]);
    final Directory work = await halfDownloaded('done');

    queue.clearFinished();
    await waitGone(work);

    expect(await work.exists(), isFalse);
    expect(queue.tasks, isEmpty);
  });
}
