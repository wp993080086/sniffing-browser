import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/logging/app_log.dart';

import '../domain/history_entry.dart';
import 'history_store.dart';

/// 浏览历史：记录、去重、落盘。
///
/// 记录时机在页面加载完成（`WebViewHost.onLoadStop`），不是地址栏提交时 ——
/// 提交只是意图，重定向、失败、被拦都会让它变成一条假记录。
///
/// 同一个地址反复访问只留一条，时间更新、位置提到最前，和系统浏览器一致。
/// 用户想看「我今天访问了几次这个站」不是这个列表的职责。
class HistoryService extends ChangeNotifier {
  HistoryService({HistoryStore? store, this.maxEntries = 500}) : _store = store;

  /// 为空表示纯内存模式（测试用），不读写磁盘。
  final HistoryStore? _store;

  /// 上限。超出时丢最旧的——历史是滚动窗口，不是档案。
  final int maxEntries;

  final List<HistoryEntry> _entries = <HistoryEntry>[];
  Timer? _pending;

  List<HistoryEntry> get entries => List<HistoryEntry>.unmodifiable(_entries);
  int get count => _entries.length;
  bool get isEmpty => _entries.isEmpty;

  List<HistoryEntry> get _sorted {
    final List<HistoryEntry> list = List<HistoryEntry>.of(_entries);
    list.sort(
      (HistoryEntry a, HistoryEntry b) => b.visitedAt.compareTo(a.visitedAt),
    );
    return list;
  }

  Future<void> restore() async {
    final HistoryStore? store = _store;
    if (store == null) return;
    final List<HistoryEntry> disk = await store.load();
    if (disk.isEmpty && _entries.isEmpty) return;

    // 磁盘在前、内存在后：启动瞬间就产生的新记录应当覆盖同地址的旧记录。
    final Map<String, HistoryEntry> merged = <String, HistoryEntry>{};
    for (final HistoryEntry entry in <HistoryEntry>[...disk, ..._entries]) {
      merged[entry.url] = entry;
    }
    final List<HistoryEntry> list = merged.values.toList()
      ..sort(
        (HistoryEntry a, HistoryEntry b) => b.visitedAt.compareTo(a.visitedAt),
      );

    _entries
      ..clear()
      ..addAll(list.take(maxEntries));
    notifyListeners();
  }

  /// 记一次访问。非 http/https（`about:blank`、`data:`、自定义协议）直接忽略。
  void record({required String url, String title = ''}) {
    if (!isWebUrl(url)) return;

    _entries.removeWhere((HistoryEntry e) => e.url == url);
    _entries.insert(
      0,
      HistoryEntry(url: url, title: title, visitedAt: DateTime.now()),
    );
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    notifyListeners();
    _schedulePersist();
  }

  void remove(String url) {
    final int before = _entries.length;
    _entries.removeWhere((HistoryEntry e) => e.url == url);
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

  /// 立刻把待写的改动刷到磁盘。测试和「退出前」用，平时靠防抖。
  Future<void> flush() async {
    _pending?.cancel();
    _pending = null;
    await _persist();
  }

  /// 只记录真正的网页。嗅探器看到的 `blob:`、`about:blank` 不该进历史。
  static bool isWebUrl(String url) {
    final String lower = url.trim().toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  void _schedulePersist() {
    if (_store == null) return;
    _pending?.cancel();
    // 一次浏览可能连着触发好几次（重定向、单页应用换 router），
    // 300ms 内合并成一次写盘足够。
    _pending = Timer(const Duration(milliseconds: 300), () {
      _pending = null;
      unawaited(_persist());
    });
  }

  Future<void> _persist() async {
    final HistoryStore? store = _store;
    if (store == null) return;
    try {
      await store.save(_sorted);
    } catch (e) {
      // 存储路径没初始化、磁盘写满等：丢记录也不能让异常冒到 zone 里。
      logWarn('History', '保存浏览记录失败: $e');
    }
  }

  @override
  void dispose() {
    _pending?.cancel();
    _pending = null;
    super.dispose();
  }
}
