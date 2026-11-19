import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../data/bookmark_service.dart';
import '../domain/bookmark_entry.dart';
import 'empty_hint.dart';

/// 收藏夹。
///
/// 和历史上的差别不只是「谁存的」：收藏是用户自己挑的，所以默认长期保留，
/// 只有主动取消才会消失；也不按天分组，按加入时间倒序一条到底。
class BookmarkPage extends ConsumerWidget {
  const BookmarkPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final BookmarkService bookmarks = ref.watch(bookmarkProvider);
    final List<BookmarkEntry> entries = List<BookmarkEntry>.of(
      bookmarks.entries,
    )..sort((BookmarkEntry a, BookmarkEntry b) =>
        b.createdAt.compareTo(a.createdAt));

    return Scaffold(
      appBar: AppBar(
        title: const Text('收藏夹', style: TextStyle(fontSize: 17)),
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
              icon: Icons.star_border,
              title: '还没有收藏',
              hint: '点地址栏右侧的星标收藏当前页',
            )
          : ListView.separated(
              itemCount: entries.length,
              separatorBuilder: (BuildContext context, int index) =>
                  const Divider(height: 1, indent: 16, endIndent: 16),
              itemBuilder: (BuildContext context, int index) =>
                  _BookmarkTile(entry: entries[index]),
            ),
    );
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('清空收藏夹？'),
        content: const Text('浏览记录不受影响。'),
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
    if (ok == true) ref.read(bookmarkProvider).clear();
  }
}

class _BookmarkTile extends ConsumerWidget {
  const _BookmarkTile({required this.entry});

  final BookmarkEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      leading: Icon(Icons.bookmark, size: 18, color: scheme.primary),
      title: Text(
        entry.displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Text(
        entry.host,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      ),
      trailing: IconButton(
        tooltip: '取消收藏',
        iconSize: 16,
        icon: const Icon(Icons.close),
        onPressed: () => ref.read(bookmarkProvider).remove(entry.url),
      ),
      onTap: () {
        Navigator.of(context).pop();
        ref.read(tabManagerProvider).navigate(entry.url);
      },
    );
  }
}
