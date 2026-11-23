import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/logging/app_log.dart';
import '../../../core/platform/storage_paths.dart';
import '../../downloader/domain/download_status.dart';
import '../../downloader/domain/download_task.dart';
import '../../transcoder/domain/transcode_job.dart';

/// 存储占用快照。
///
/// 已导出到系统媒体库的副本不在这里：MediaStore 不归应用管，
/// 本页既统计不到也不应该删。
class StorageUsage {
  const StorageUsage({
    required this.productBytes,
    required this.productCount,
    required this.partialBytes,
    required this.partialCount,
    required this.orphanBytes,
    required this.orphanCount,
    required this.tempBytes,
    required this.tempCount,
    required this.cleanableTempBytes,
    required this.cleanableTempCount,
  });

  /// 下载 / 转换记录引用的文件，以及仍可能续传的 `.part`。
  final int productBytes;
  final int productCount;

  /// [productBytes] 里属于 `.part` 的部分。
  final int partialBytes;
  final int partialCount;

  /// 下载目录里没有任何记录引用的文件（含失效的 `.part`）。
  final int orphanBytes;
  final int orphanCount;

  /// `tmp/` 全部占用。
  final int tempBytes;
  final int tempCount;

  /// [tempBytes] 里不属于任何未结束任务的、可安全清理的部分。
  final int cleanableTempBytes;
  final int cleanableTempCount;

  int get totalBytes => productBytes + orphanBytes + tempBytes;
}

class StorageCleanResult {
  const StorageCleanResult({required this.freed, required this.count});

  final int freed;
  final int count;
}

/// 应用私有目录的扫描与清理。
///
/// 只处理 `StoragePaths.downloads` / `StoragePaths.temp`，不碰 MediaStore，
/// 也不动 `download_tasks.json` 这类记录文件。
class StorageManager {
  const StorageManager({this.downloads, this.temp});

  final Directory? downloads;
  final Directory? temp;

  Directory get _downloads => downloads ?? StoragePaths.downloads;
  Directory get _temp => temp ?? StoragePaths.temp;

  Future<StorageUsage> scan({
    required List<DownloadTask> tasks,
    required List<TranscodeJob> jobs,
  }) async {
    final Set<String> keepFiles = _fileKeep(tasks, jobs);
    final Set<String> taskBases = _taskBases(tasks);
    final Set<String> keepTemp = _tempKeep(tasks, jobs);

    int productBytes = 0;
    int productCount = 0;
    int partialBytes = 0;
    int partialCount = 0;
    int orphanBytes = 0;
    int orphanCount = 0;

    if (await _downloads.exists()) {
      await for (final FileSystemEntity entity
          in _downloads.list(followLinks: false)) {
        if (entity is! File) continue;
        final int size = await _size(entity);
        final String path = p.normalize(entity.path);
        final bool isPartial = p.basename(entity.path).endsWith('.part');

        if (keepFiles.contains(path) ||
            (isPartial && _ownedPart(entity.path, taskBases))) {
          productBytes += size;
          productCount++;
          if (isPartial) {
            partialBytes += size;
            partialCount++;
          }
        } else {
          orphanBytes += size;
          orphanCount++;
        }
      }
    }

    int tempBytes = 0;
    int tempCount = 0;
    int cleanableTempBytes = 0;
    int cleanableTempCount = 0;

    if (await _temp.exists()) {
      await for (final FileSystemEntity entity
          in _temp.list(followLinks: false)) {
        final int size = await _size(entity);
        tempBytes += size;
        tempCount++;
        if (!keepTemp.contains(p.normalize(entity.path))) {
          cleanableTempBytes += size;
          cleanableTempCount++;
        }
      }
    }

    return StorageUsage(
      productBytes: productBytes,
      productCount: productCount,
      partialBytes: partialBytes,
      partialCount: partialCount,
      orphanBytes: orphanBytes,
      orphanCount: orphanCount,
      tempBytes: tempBytes,
      tempCount: tempCount,
      cleanableTempBytes: cleanableTempBytes,
      cleanableTempCount: cleanableTempCount,
    );
  }

  /// [temp] 只清不在续传里的临时项；[orphan] 只清无主文件。
  ///
  /// 两个开关不会互相影响：清理临时分片时绝不会动下载目录里的成品。
  Future<StorageCleanResult> clean({
    required List<DownloadTask> tasks,
    required List<TranscodeJob> jobs,
    bool temp = false,
    bool orphan = false,
  }) async {
    int freed = 0;
    int count = 0;

    if (temp && await _temp.exists()) {
      final Set<String> keepTemp = _tempKeep(tasks, jobs);
      final List<FileSystemEntity> entities =
          await _temp.list(followLinks: false).toList();
      for (final FileSystemEntity entity in entities) {
        if (keepTemp.contains(p.normalize(entity.path))) continue;
        freed += await _size(entity);
        count++;
        try {
          await entity.delete(recursive: true);
        } catch (e) {
          logWarn('Storage', '清理临时项失败: ${entity.path} ($e)');
        }
      }
    }

    if (orphan && await _downloads.exists()) {
      final Set<String> keepFiles = _fileKeep(tasks, jobs);
      final Set<String> taskBases = _taskBases(tasks);
      final List<FileSystemEntity> entities =
          await _downloads.list(followLinks: false).toList();
      for (final FileSystemEntity entity in entities) {
        if (entity is! File) continue;
        final String path = p.normalize(entity.path);
        final bool isPartial = p.basename(entity.path).endsWith('.part');
        if (keepFiles.contains(path) ||
            (isPartial && _ownedPart(entity.path, taskBases))) {
          continue;
        }
        freed += await _size(entity);
        count++;
        try {
          await entity.delete();
        } catch (e) {
          logWarn('Storage', '清理无主文件失败: ${entity.path} ($e)');
        }
      }
    }

    return StorageCleanResult(freed: freed, count: count);
  }

  Set<String> _fileKeep(List<DownloadTask> tasks, List<TranscodeJob> jobs) {
    final Set<String> keep = <String>{};
    for (final DownloadTask task in tasks) {
      final String? path = task.savedPath;
      if (path != null) keep.add(p.normalize(path));
    }
    for (final TranscodeJob job in jobs) {
      keep.add(p.normalize(job.outputPath));
      keep.add(p.normalize(job.artifactPath));
    }
    return keep;
  }

  Set<String> _taskBases(List<DownloadTask> tasks) {
    return tasks
        .where((DownloadTask t) => t.status != DownloadStatus.completed)
        .map((DownloadTask t) => p.basenameWithoutExtension(t.fileName))
        .toSet();
  }

  Set<String> _tempKeep(List<DownloadTask> tasks, List<TranscodeJob> jobs) {
    final Set<String> keep = <String>{};
    for (final DownloadTask task in tasks) {
      if (task.status == DownloadStatus.completed) continue;
      // 用注入的 temp 目录拼，不能走 StoragePaths.tempDirFor：
      // 后者永远指向全局目录，测试或未来换目录时会把 keep 和扫描
      // 放在两棵树上，清理时误删正在续传的分片。
      keep.add(p.normalize(p.join(_temp.path, task.id)));
      for (final String suffix in <String>[
        '.out',
        '.dash.out',
        '.dash.audio.out',
        '.merge.mp4',
        '.dash.merge.mp4',
      ]) {
        keep.add(
          p.normalize(p.join(_temp.path, '${task.id}$suffix')),
        );
      }
    }
    for (final TranscodeJob job in jobs) {
      if (job.status.isFinished) continue;
      if (p.isWithin(_temp.path, job.outputPath)) {
        keep.add(p.normalize(job.outputPath));
      }
    }
    return keep;
  }

  /// `clip (1).mp4.part` 归 `clip.mp4` 的任务所有，续传不能清。
  static bool _ownedPart(String path, Set<String> taskBases) {
    String name = p.basename(path);
    if (!name.endsWith('.part')) return false;
    name = p.basenameWithoutExtension(name);
    if (p.extension(name).isNotEmpty) name = p.basenameWithoutExtension(name);
    name = name.replaceFirst(RegExp(r' \(\d+\)$'), '');
    return taskBases.contains(name);
  }

  static Future<int> _size(FileSystemEntity entity) async {
    try {
      if (entity is File) return await entity.length();
      if (entity is! Directory) return 0;
      int total = 0;
      await for (final FileSystemEntity child
          in entity.list(recursive: true, followLinks: false)) {
        if (child is File) total += await child.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}
