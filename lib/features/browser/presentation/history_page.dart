import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../data/history_service.dart';
import '../domain/history_entry.dart';
import 'empty_hint.dart';

/// 历史记录页。
///
/// 按天分组，最新的在最前。点一条就在当前页签打开并关掉本页——历史页是
/// 中途经过的地方，不该留在返回栈里。
class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final HistoryService history = ref.watch(historyProvider);
    final List<HistoryEntry> entries = List<HistoryEntry>.of(history.entries)
      ..sort(
        (HistoryEntry a, HistoryEntry b) => b.visitedAt.compareTo(a.visitedAt),
      );

    return Scaffold(
      appBar: AppBar(
        title: const Text('历史记录', style: TextStyle(fontSize: 17)),
        actions: <Widget>[
          if (entries.isNotEmpty)
            TextButton(
              onPressed: () => _confirmClear(context, ref),
              child: const Text('清空', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
      body: entries.isEmpty
          ? const EmptyHint(
              icon: Icons.history,
              title: '还没有浏览记录',
              hint: '打开过的网页会出现在这里',
            )
          : ListView.builder(
              itemCount: _rowCount(entries),
              itemBuilder: (BuildContext context, int index) {
                final _Row row = _rowAt(entries, index);
                final String? label = row.label;
                if (label != null) return _DayHeader(label: label);
                return _HistoryTile(entry: row.entry!);
              },
            ),
    );
  }

  /// 行数 = 条目数 + 日期小标题数。用函数算而不是先摊平成 List，
  /// 500 条时能省一次全量对象分配。
  static int _rowCount(List<HistoryEntry> entries) {
    int rows = entries.length;
    String? last;
    for (final HistoryEntry entry in entries) {
      final String label = _dayLabel(entry.visitedAt);
      if (label != last) {
        rows++;
        last = label;
      }
    }
    return rows;
  }

  static _Row _rowAt(List<HistoryEntry> entries, int index) {
    int cursor = 0;
    String? last;
    for (final HistoryEntry entry in entries) {
      final String label = _dayLabel(entry.visitedAt);
      if (label != last) {
        if (cursor == index) return _Row.header(label);
        cursor++;
        last = label;
      }
      if (cursor == index) return _Row.item(entry);
      cursor++;
    }
    // 越界不该发生（行数由 _rowCount 保证），兜底返回最后一条。
    return _Row.item(entries.last);
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('清空浏览记录？'),
        content: const Text('收藏夹不受影响。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) ref.read(historyProvider).clear();
  }
}

/// 「今天 / 昨天 / 11月13日」。
String _dayLabel(DateTime time) {
  final DateTime now = DateTime.now();
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime day = DateTime(time.year, time.month, time.day);
  final int diff = today.difference(day).inDays;
  if (diff == 0) return '今天';
  if (diff == 1) return '昨天';
  if (now.year == time.year) return '${time.month}月${time.day}日';
  return '${time.year}年${time.month}月${time.day}日';
}

String _clock(DateTime time) {
  final String hh = time.hour.toString().padLeft(2, '0');
  final String mm = time.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}

/// ListView 的一行：要么是日期小标题，要么是一条记录。
class _Row {
  const _Row.header(this.label) : entry = null;
  const _Row.item(this.entry) : label = null;

  final String? label;
  final HistoryEntry? entry;
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _HistoryTile extends ConsumerWidget {
  const _HistoryTile({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      leading: Icon(Icons.public, size: 18, color: scheme.onSurfaceVariant),
      title: Text(
        entry.displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Text(
        '${entry.host} · ${_clock(entry.visitedAt)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      ),
      trailing: IconButton(
        tooltip: '删除这条记录',
        iconSize: 16,
        icon: const Icon(Icons.close),
        onPressed: () => ref.read(historyProvider).remove(entry.url),
      ),
      onTap: () {
        Navigator.of(context).pop();
        ref.read(tabManagerProvider).navigate(entry.url);
      },
    );
  }
}
