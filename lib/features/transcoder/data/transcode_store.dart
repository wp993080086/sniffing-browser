import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/logging/app_log.dart';
import '../../../core/platform/storage_paths.dart';
import '../domain/transcode_job.dart';

/// 转换任务的落盘。
///
/// 只存「任务是什么、停在哪一步」，**不存进度百分比**：进度每秒变好几次，
/// 落盘既没有意义，也会白白磨损闪存。重启后未完成的任务按中断处理，
/// 具体规则在 `TranscodeQueue.restore()` 里。
///
/// 存储位置在应用私有根目录（桌面是下载目录下的 SniffingBrowser），
/// 用户不需要、也不应该手动改这个文件。
class TranscodeStore {
  TranscodeStore({File? file}) : _fileOverride = file;

  /// 测试用：直接指定文件，绕开 [StoragePaths] 的初始化要求。
  final File? _fileOverride;

  static const int _version = 1;

  /// 最多留这么多条历史。转码是低频操作，100 条足够回溯，
  /// 也避免文件无限增长。
  static const int maxJobs = 100;

  File get file =>
      _fileOverride ??
      File(p.join(StoragePaths.root.path, 'transcode_jobs.json'));

  Future<List<TranscodeJob>> load() async {
    final File target = file;
    if (!await target.exists()) return <TranscodeJob>[];

    try {
      final Object? decoded = jsonDecode(await target.readAsString());
      if (decoded is! Map<String, Object?>) {
        logWarn('Transcode', '任务记录格式异常，按空列表处理');
        return <TranscodeJob>[];
      }
      final Object? raw = decoded['jobs'];
      if (raw is! List<Object?>) return <TranscodeJob>[];

      final List<TranscodeJob> jobs = <TranscodeJob>[];
      for (final Object? item in raw) {
        final TranscodeJob? job = _decode(item);
        // 单条坏了不影响其它条：升级过程中字段变动是常态。
        if (job != null) jobs.add(job);
      }
      return jobs;
    } catch (e) {
      logWarn('Transcode', '读取任务记录失败，按空列表处理: $e');
      return <TranscodeJob>[];
    }
  }

  Future<void> save(List<TranscodeJob> jobs) async {
    // 新的在前，截断时丢掉的自然是更早的历史。
    final List<TranscodeJob> kept = jobs.take(maxJobs).toList();
    final Map<String, Object?> payload = <String, Object?>{
      'version': _version,
      'jobs': <Object?>[for (final TranscodeJob job in kept) _encode(job)],
    };

    final File target = file;
    final File temp = File('${target.path}.tmp');
    try {
      await target.parent.create(recursive: true);
      // 先写临时文件再 rename：写一半被系统杀掉时不会留下半个 JSON。
      await temp.writeAsString(jsonEncode(payload), flush: true);
      await temp.rename(target.path);
    } catch (e) {
      logWarn('Transcode', '写入任务记录失败: $e');
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // 清不掉临时文件不影响主流程。
      }
    }
  }

  Map<String, Object?> _encode(TranscodeJob job) {
    return <String, Object?>{
      'id': job.id,
      'sourcePath': job.sourcePath,
      'outputPath': job.outputPath,
      'kind': job.kind.name,
      'createdAt': job.createdAt.toIso8601String(),
      'secondarySourcePath': job.secondarySourcePath,
      'sourceTaskId': job.sourceTaskId,
      'displayName': job.displayName,
      'replaceSource': job.replaceSource,
      'status': job.status.name,
      'error': job.error,
      'exportMessage': job.exportMessage,
      'exported': job.exported,
      'mediaUri': job.mediaUri,
    };
  }

  TranscodeJob? _decode(Object? raw) {
    if (raw is! Map<String, Object?>) return null;

    final String? id = raw['id'] as String?;
    final String? sourcePath = raw['sourcePath'] as String?;
    final String? outputPath = raw['outputPath'] as String?;
    final String? kindName = raw['kind'] as String?;
    if (id == null || sourcePath == null || outputPath == null) return null;

    final TranscodeKind? kind = _enumByName(TranscodeKind.values, kindName);
    if (kind == null) return null;

    final DateTime createdAt =
        DateTime.tryParse(raw['createdAt'] as String? ?? '') ?? DateTime.now();

    final TranscodeJob job = TranscodeJob(
      id: id,
      sourcePath: sourcePath,
      outputPath: outputPath,
      kind: kind,
      createdAt: createdAt,
      secondarySourcePath: raw['secondarySourcePath'] as String?,
      sourceTaskId: raw['sourceTaskId'] as String?,
      displayName: raw['displayName'] as String?,
      replaceSource: raw['replaceSource'] as bool? ?? false,
    );
    job.error = raw['error'] as String?;
    job.exportMessage = raw['exportMessage'] as String?;
    job.exported = raw['exported'] as bool? ?? false;
    job.mediaUri = raw['mediaUri'] as String?;

    final TranscodeStatus? status = _enumByName(
      TranscodeStatus.values,
      raw['status'] as String?,
    );
    if (status != null) job.setStatus(status);
    return job;
  }

  static T? _enumByName<T extends Enum>(List<T> values, String? name) {
    if (name == null) return null;
    for (final T value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}
