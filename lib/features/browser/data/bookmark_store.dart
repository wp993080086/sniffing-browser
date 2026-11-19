import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/platform/storage_paths.dart';
import '../../../core/utils/json_file.dart';
import '../domain/bookmark_entry.dart';

/// 收藏的落盘。位置同 [HistoryStore]，独立文件，清历史不影响收藏。
class BookmarkStore {
  BookmarkStore({File? file}) : _fileOverride = file;

  /// 测试用：直接指定文件。
  final File? _fileOverride;

  static const int _version = 1;
  static const String _tag = 'Bookmark';

  File get file =>
      _fileOverride ?? File(p.join(StoragePaths.root.path, 'bookmarks.json'));

  Future<List<BookmarkEntry>> load() async {
    final Map<String, Object?>? decoded = await JsonFile.read(file, _tag);
    if (decoded == null) return <BookmarkEntry>[];

    final Object? raw = decoded['entries'];
    if (raw is! List<Object?>) return <BookmarkEntry>[];

    final List<BookmarkEntry> entries = <BookmarkEntry>[];
    for (final Object? item in raw) {
      final BookmarkEntry? entry = _decode(item);
      if (entry != null) entries.add(entry);
    }
    return entries;
  }

  Future<void> save(List<BookmarkEntry> entries) {
    return JsonFile.write(file, <String, Object?>{
      'version': _version,
      'entries': <Object?>[for (final BookmarkEntry e in entries) _encode(e)],
    }, _tag);
  }

  Map<String, Object?> _encode(BookmarkEntry entry) {
    return <String, Object?>{
      'url': entry.url,
      'title': entry.title,
      'createdAt': entry.createdAt.toIso8601String(),
    };
  }

  BookmarkEntry? _decode(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final String? url = raw['url'] as String?;
    if (url == null || url.isEmpty) return null;
    final DateTime createdAt =
        DateTime.tryParse(raw['createdAt'] as String? ?? '') ?? DateTime.now();
    return BookmarkEntry(
      url: url,
      title: raw['title'] as String? ?? '',
      createdAt: createdAt,
    );
  }
}
