import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/platform/storage_paths.dart';
import '../../../core/utils/json_file.dart';
import '../domain/history_entry.dart';

/// 浏览历史的落盘。
///
/// 位置在应用私有根目录（桌面是 `下载/SniffingBrowser`，Android 是
/// `Android/data/<包名>/files/SniffingBrowser`），用户不需要手动改它。
class HistoryStore {
  HistoryStore({File? file}) : _fileOverride = file;

  /// 测试用：直接指定文件，绕开 [StoragePaths] 的初始化要求。
  final File? _fileOverride;

  static const int _version = 1;
  static const String _tag = 'History';

  File get file =>
      _fileOverride ?? File(p.join(StoragePaths.root.path, 'history.json'));

  Future<List<HistoryEntry>> load() async {
    final Map<String, Object?>? decoded = await JsonFile.read(file, _tag);
    if (decoded == null) return <HistoryEntry>[];

    final Object? raw = decoded['entries'];
    if (raw is! List<Object?>) return <HistoryEntry>[];

    final List<HistoryEntry> entries = <HistoryEntry>[];
    for (final Object? item in raw) {
      final HistoryEntry? entry = _decode(item);
      // 单条坏了不影响其它条：字段变动在升级过程中是常态。
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  Future<void> save(List<HistoryEntry> entries) {
    return JsonFile.write(
      file,
      <String, Object?>{
        'version': _version,
        'entries': <Object?>[for (final HistoryEntry e in entries) _encode(e)],
      },
      _tag,
    );
  }

  Map<String, Object?> _encode(HistoryEntry entry) {
    return <String, Object?>{
      'url': entry.url,
      'title': entry.title,
      'visitedAt': entry.visitedAt.toIso8601String(),
    };
  }

  HistoryEntry? _decode(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final String? url = raw['url'] as String?;
    if (url == null || url.isEmpty) return null;
    final DateTime visitedAt =
        DateTime.tryParse(raw['visitedAt'] as String? ?? '') ?? DateTime.now();
    return HistoryEntry(
      url: url,
      title: raw['title'] as String? ?? '',
      visitedAt: visitedAt,
    );
  }
}
