import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/logging/app_log.dart';
import '../../../core/platform/media_exporter.dart';
import '../../../core/platform/storage_paths.dart';
import '../../sniffer/domain/media_type.dart';
import '../domain/download_status.dart';
import '../domain/download_task.dart';

/// 下载任务的落盘。
///
/// 位置在**应用私有 files 目录**（[StoragePaths.root]），和 `transcode_jobs.json`
/// 同级。**不放缓存目录**：Android 的 `cache` 会在存储紧张时被系统静默清掉，
/// 用户也能在设置里一键「清除缓存」，记录哪天消失完全不可控，等于没持久化。
///
/// 只存「任务是什么、停在哪一步」：进度百分比不落盘（每秒变好几次，没有意义
/// 还磨损闪存），恢复后一律从 0 开始。
class DownloadStore {
  DownloadStore({File? file}) : _fileOverride = file;

  /// 测试用：直接指定文件，绕开 [StoragePaths] 的初始化要求。
  final File? _fileOverride;

  static const int _version = 1;

  /// 历史上限。下载是高频操作，留 200 条够回溯，也避免文件无限增长。
  static const int maxTasks = 200;

  File get file =>
      _fileOverride ??
      File(p.join(StoragePaths.root.path, 'download_tasks.json'));

  Future<List<DownloadTask>> load() async {
    final File target = file;
    if (!await target.exists()) return <DownloadTask>[];

    try {
      final Object? decoded = jsonDecode(await target.readAsString());
      if (decoded is! Map<String, Object?>) {
        logWarn('Download', '任务记录格式异常，按空列表处理');
        return <DownloadTask>[];
      }
      final Object? raw = decoded['tasks'];
      if (raw is! List<Object?>) return <DownloadTask>[];

      final List<DownloadTask> tasks = <DownloadTask>[];
      for (final Object? item in raw) {
        final DownloadTask? task = _decode(item);
        // 单条坏了不影响其它条：升级过程中字段变动是常态。
        if (task != null) tasks.add(task);
      }
      return tasks;
    } catch (e) {
      logWarn('Download', '读取任务记录失败，按空列表处理: $e');
      return <DownloadTask>[];
    }
  }

  Future<void> save(List<DownloadTask> tasks) async {
    // 新的在前，截断时丢掉的自然是更早的历史。
    final List<DownloadTask> kept = tasks.take(maxTasks).toList();
    final Map<String, Object?> payload = <String, Object?>{
      'version': _version,
      'tasks': <Object?>[for (final DownloadTask task in kept) _encode(task)],
    };

    final File target = file;
    final File temp = File('${target.path}.tmp');
    try {
      await target.parent.create(recursive: true);
      // 先写临时文件再 rename：写一半被系统杀掉时不会留下半个 JSON。
      await temp.writeAsString(jsonEncode(payload), flush: true);
      await temp.rename(target.path);
    } catch (e) {
      logWarn('Download', '写入任务记录失败: $e');
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // 清不掉临时文件不影响主流程。
      }
    }
  }

  Map<String, Object?> _encode(DownloadTask task) {
    return <String, Object?>{
      'id': task.id,
      'mediaId': task.mediaId,
      'url': task.url,
      'type': task.type.name,
      'fileName': task.fileName,
      'createdAt': task.createdAt.toIso8601String(),
      'pageUrl': task.pageUrl,
      'headers': task.headers,
      'isStream': task.isStream,
      'totalSegments': task.totalSegments,
      'status': task.status.name,
      'pairedTaskId': task.pairedTaskId,
      'isCompanion': task.isCompanion,
      'mergedAudio': task.mergedAudio,
      'receivedBytes': task.receivedBytes,
      'totalBytes': task.totalBytes,
      'segmentDone': task.segmentDone,
      'error': task.error,
      'savedPath': task.savedPath,
      'container': task.container,
      'needsRemux': task.needsRemux,
      'exportStatus': task.exportStatus.name,
    };
  }

  DownloadTask? _decode(Object? raw) {
    if (raw is! Map<String, Object?>) return null;

    final String? id = raw['id'] as String?;
    final String? mediaId = raw['mediaId'] as String?;
    final String? url = raw['url'] as String?;
    final String? fileName = raw['fileName'] as String?;
    if (id == null || mediaId == null || url == null || fileName == null) {
      return null;
    }

    final MediaType? type = _enumByName(
      MediaType.values,
      raw['type'] as String?,
    );
    if (type == null) return null;

    final DownloadTask task = DownloadTask(
      id: id,
      mediaId: mediaId,
      url: url,
      type: type,
      fileName: fileName,
      createdAt:
          DateTime.tryParse(raw['createdAt'] as String? ?? '') ??
          DateTime.now(),
      pageUrl: raw['pageUrl'] as String?,
      headers: _stringMap(raw['headers']),
      isStream: raw['isStream'] as bool? ?? false,
      totalSegments: raw['totalSegments'] as int?,
    );

    task
      ..pairedTaskId = raw['pairedTaskId'] as String?
      ..isCompanion = raw['isCompanion'] as bool? ?? false
      ..mergedAudio = raw['mergedAudio'] as bool?
      ..receivedBytes = raw['receivedBytes'] as int? ?? 0
      ..totalBytes = raw['totalBytes'] as int?
      ..segmentDone = raw['segmentDone'] as int? ?? 0
      ..error = raw['error'] as String?
      ..savedPath = raw['savedPath'] as String?
      ..container = raw['container'] as String?
      ..needsRemux = raw['needsRemux'] as bool? ?? false
      ..exportStatus =
          _enumByName(ExportStatus.values, raw['exportStatus'] as String?) ??
          ExportStatus.notExported;

    // 走 setStatus 而不是直接改字段：界面读的是 statusNotifier，
    // 只改 _status 的话列表会一直显示「等待中」。
    final DownloadStatus? status = _enumByName(
      DownloadStatus.values,
      raw['status'] as String?,
    );
    if (status != null) task.setStatus(status);
    if (task.status == DownloadStatus.completed) task.progress.value = 1;

    return task;
  }

  static Map<String, String> _stringMap(Object? raw) {
    if (raw is! Map<Object?, Object?>) return const <String, String>{};
    final Map<String, String> result = <String, String>{};
    raw.forEach((Object? key, Object? value) {
      if (key is String && value is String) result[key] = value;
    });
    return result;
  }

  static T? _enumByName<T extends Enum>(List<T> values, String? name) {
    if (name == null) return null;
    for (final T value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}
