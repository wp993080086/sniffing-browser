import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/logging/app_log.dart';

import '../domain/bookmark_entry.dart';
import 'bookmark_store.dart';

/// 收藏夹：加入 / 取消 / 落盘。
///
/// 按 URL 唯一定位，不做自定义标题和排序——本期只要「能存下来、能回去」。
/// 顺序按加入时间倒序，最新的在最前。
class BookmarkService extends ChangeNotifier {
  BookmarkService({BookmarkStore? store, this.maxEntries = 300})
    : _store = store;

  /// 为空表示纯内存模式（测试用）。
  final BookmarkStore? _store;

  final int maxEntries;

  final List<BookmarkEntry> _entries = <BookmarkEntry>[];
  Timer? _pending;

  List<BookmarkEntry> get entries => List<BookmarkEntry>.unmodifiable(_entries);
  int get count => _entries.length;
  bool get isEmpty => _entries.isEmpty;

  bool contains(String url) {
    if (url.isEmpty) return false;
    for (final BookmarkEntry entry in _entries) {
      if (entry.url == url) return true;
    }
    return false;
  }

  Future<void> restore() async {
    final BookmarkStore? store = _store;
    if (store == null) return;
    final List<BookmarkEntry> disk = await store.load();
    if (disk.isEmpty && _entries.isEmpty) return;

    final Map<String, BookmarkEntry> merged = <String, BookmarkEntry>{};
    for (final BookmarkEntry entry in <BookmarkEntry>[...disk, ..._entries]) {
      merged[entry.url] = entry;
    }
    final List<BookmarkEntry> list = merged.values.toList()
      ..sort(
        (BookmarkEntry a, BookmarkEntry b) =>
            b.createdAt.compareTo(a.createdAt),
      );

    _entries
      ..clear()
      ..addAll(list.take(maxEntries));
    notifyListeners();
  }

  /// 收藏 / 取消收藏。返回**操作后**是否处于已收藏状态。
  bool toggle({required String url, String title = ''}) {
    if (!isWebUrl(url)) return false;
    if (contains(url)) {
      remove(url);
      return false;
    }
    _entries.insert(
      0,
      BookmarkEntry(url: url, title: title, createdAt: DateTime.now()),
    );
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    notifyListeners();
    _schedulePersist();
    return true;
  }

  void remove(String url) {
    final int before = _entries.length;
    _entries.removeWhere((BookmarkEntry e) => e.url == url);
    if (_entries.length == before) return;
    notifyListeners();
    _schedulePersist();
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
    _schedulePersist();
  }

  Future<void> flush() async {
    _pending?.cancel();
    _pending = null;
    await _flushNow();
  }

  static bool isWebUrl(String url) {
    final String lower = url.trim().toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  void _schedulePersist() {
    if (_store == null) return;
    _pending?.cancel();
    _pending = Timer(const Duration(milliseconds: 300), () {
      _pending = null;
      unawaited(_flushNow());
    });
  }

  Future<void> _flushNow() async {
    final BookmarkStore? store = _store;
    if (store == null) return;
    try {
      await store.save(_entries);
    } catch (e) {
      logWarn('Bookmark', '保存收藏失败: $e');
    }
  }

  @override
  void dispose() {
    _pending?.cancel();
    _pending = null;
    super.dispose();
  }
}
