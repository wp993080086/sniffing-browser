import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/core/platform/storage_paths.dart';
import 'package:sniffingbrowser/features/downloader/domain/download_status.dart';
import 'package:sniffingbrowser/features/downloader/domain/download_task.dart';
import 'package:sniffingbrowser/features/settings/data/storage_manager.dart';
import 'package:sniffingbrowser/features/sniffer/domain/media_type.dart';
import 'package:sniffingbrowser/features/transcoder/domain/transcode_job.dart';

DownloadTask _task(
  String id, {
  DownloadStatus status = DownloadStatus.failed,
  String fileName = 'clip.mp4',
  String? savedPath,
}) {
  final DownloadTask task = DownloadTask(
    id: id,
    mediaId: 'm-$id',
    url: 'https://example.com/$id',
    type: MediaType.video,
    fileName: fileName,
    createdAt: DateTime(2026, 11, 23),
  )..setStatus(status);
  task.savedPath = savedPath;
  return task;
}

void main() {
  late Directory root;
  late StorageManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sniffing-storage-test');
    await StoragePaths.initWithRoot(root);
    manager = const StorageManager();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('扫描区分产物、续传缓存、无主文件与可清理临时项', () async {
    final File product = File('${StoragePaths.downloads.path}/done.mp4');
    final File partial = File('${StoragePaths.downloads.path}/clip (1).mp4.part');
    final File orphan = File('${StoragePaths.downloads.path}/orphan.mp4');
    await product.writeAsBytes(List<int>.filled(100, 1));
    await partial.writeAsBytes(List<int>.filled(50, 1));
    await orphan.writeAsBytes(List<int>.filled(20, 1));

    final Directory live = StoragePaths.tempDirFor('t1');
    await live.create(recursive: true);
    await File('${live.path}/seg_0.part').writeAsBytes(List<int>.filled(10, 1));
    final File stale = File('${StoragePaths.temp.path}/stray.out');
    await stale.writeAsBytes(List<int>.filled(30, 1));

    final StorageUsage usage = await manager.scan(
      tasks: <DownloadTask>[
        _task('t1', fileName: 'clip.mp4'),
        _task('t2', status: DownloadStatus.completed, savedPath: product.path),
      ],
      jobs: const <TranscodeJob>[],
    );

    expect(usage.productBytes, 150);
    expect(usage.partialBytes, 50);
    expect(usage.orphanBytes, 20);
    expect(usage.tempBytes, 40);
    expect(usage.cleanableTempBytes, 30);
  });

  test('清理只删无主文件与非在用临时项', () async {
    final File product = File('${StoragePaths.downloads.path}/done.mp4');
    final File partial = File('${StoragePaths.downloads.path}/clip.mp4.part');
    final File orphan = File('${StoragePaths.downloads.path}/orphan.mp4');
    await product.writeAsBytes(<int>[1, 2]);
    await partial.writeAsBytes(<int>[3, 4, 5]);
    await orphan.writeAsBytes(<int>[6]);

    final Directory live = StoragePaths.tempDirFor('t1');
    await live.create(recursive: true);
    await File('${live.path}/seg_0.part').writeAsBytes(<int>[7]);
    final File stale = File('${StoragePaths.temp.path}/stray.out');
    await stale.writeAsBytes(<int>[8, 9]);

    final StorageCleanResult result = await manager.clean(
      tasks: <DownloadTask>[
        _task('t1', fileName: 'clip.mp4'),
        _task('t2', status: DownloadStatus.completed, savedPath: product.path),
      ],
      jobs: const <TranscodeJob>[],
      temp: true,
      orphan: true,
    );

    expect(result.freed, 3);
    expect(result.count, 2);
    expect(await product.exists(), isTrue);
    expect(await partial.exists(), isTrue);
    expect(await live.exists(), isTrue);
    expect(await orphan.exists(), isFalse);
    expect(await stale.exists(), isFalse);
  });
}
