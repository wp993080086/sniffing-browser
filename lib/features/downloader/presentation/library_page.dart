import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/platform/media_exporter.dart';
import '../../../core/platform/platform_info.dart';
import '../../../core/utils/format_util.dart';
import '../../sniffer/domain/media_type.dart';
import '../data/download_queue.dart';
import '../domain/download_task.dart';
import '../domain/download_status.dart';

/// 已下载媒体库。
///
/// 和「下载」页的分工：下载页看的是**任务**（含进行中、失败），这里看的是
/// **产物**（已经落盘的文件）。用户想找「我下过的那个视频」时来这里，不必
/// 在一堆失败记录里翻。
///
/// 列表直接来自 DownloadQueue 里 completed 的任务，不另建索引 —— 记录本来
/// 就跟着队列落盘，多存一份只会两边不同步。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  final TextEditingController _search = TextEditingController();

  /// 多选模式下选中的任务 id。空集表示不在多选模式。
  final Set<String> _selected = <String>{};

  bool get _selecting => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _exitSelect() => setState(_selected.clear);

  @override
  Widget build(BuildContext context) {
    final DownloadQueueTasks tasks = DownloadQueueTasks(
      ref.watch(downloadQueueProvider).visibleTasks,
    );
    final String query = _search.text.trim().toLowerCase();
    final List<DownloadTask> matched = tasks.completed
        .where(
          (DownloadTask t) =>
              t.savedPath != null &&
              (query.isEmpty || t.fileName.toLowerCase().contains(query)),
        )
        .toList();
    // 任务可能被别处删掉（下载页移除记录），选中集合要跟着收口，
    // 否则「删除 3 项」实际只删得掉 2 个。
    _selected.removeWhere(
      (String id) => !matched.any((DownloadTask t) => t.id == id),
    );

    return Scaffold(
      appBar: AppBar(
        leading: _selecting
            ? IconButton(
                icon: const Icon(Icons.close, size: 20),
                tooltip: '取消多选',
                onPressed: _exitSelect,
              )
            : null,
        title: Text(
          _selecting ? '已选 ${_selected.length} 项' : '下载库',
          style: const TextStyle(fontSize: 17),
        ),
        actions: _selecting
            ? <Widget>[
                IconButton(
                  icon: const Icon(Icons.select_all, size: 20),
                  tooltip: '全选',
                  onPressed: () => setState(() {
                    if (_selected.length == matched.length) {
                      _selected.clear();
                    } else {
                      _selected
                        ..clear()
                        ..addAll(matched.map((DownloadTask t) => t.id));
                    }
                  }),
                ),
                IconButton(
                  icon: const Icon(Icons.movie_creation_outlined, size: 20),
                  tooltip: '转码',
                  onPressed: () => _transcode(matched),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: '删除',
                  onPressed: () => _delete(matched),
                ),
              ]
            : <Widget>[
                if (matched.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Center(
                      child: Text(
                        '${matched.length} 项',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
              ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: '搜索文件名',
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
          Expanded(
            child: matched.isEmpty
                ? _Empty(hasQuery: query.isNotEmpty)
                : ListView(
                    children: <Widget>[
                      for (final LibraryGroup group in LibraryGroup.values)
                        if (matched.any(
                          (DownloadTask t) => groupFor(t.type) == group,
                        ))
                          _Group(
                            group: group,
                            tasks: matched
                                .where(
                                  (DownloadTask t) => groupFor(t.type) == group,
                                )
                                .toList(),
                            selected: _selected,
                            selecting: _selecting,
                            onToggle: _toggle,
                            onDelete: (DownloadTask task) =>
                                _delete(<DownloadTask>[task]),
                          ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// 批量转码。按类型自动挑能做的转换，跳过无需转换的项。
  void _transcode(List<DownloadTask> matched) {
    final List<String> ids = _selected.toList();
    final DownloadQueue queue = ref.read(downloadQueueProvider);
    final int queued = queue.transcodeFiles(ids);
    final int skipped = ids.length - queued;
    _exitSelect();
    _toast(
      queued == 0
          ? '选中的文件都不需要转换'
          : '已加入转换队列 $queued 项'
                '${skipped > 0 ? "，$skipped 项无需转换" : ""}',
    );
  }

  /// 删除选中的记录与文件。会先确认 —— 文件删掉后只能重下。
  Future<void> _delete(List<DownloadTask> matched) async {
    final List<String> ids = _selected.isEmpty
        ? matched.map((DownloadTask t) => t.id).toList()
        : _selected.toList();
    if (ids.isEmpty) return;

    final bool confirmed = await _confirmDelete(ids.length);
    if (!confirmed) return;

    final int deleted = await ref.read(downloadQueueProvider).deleteFiles(ids);
    if (!mounted) return;
    _exitSelect();
    _toast('已删除 ${ids.length} 项${deleted > 0 ? "（文件 $deleted 个）" : ""}');
  }

  Future<bool> _confirmDelete(int count) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('删除 $count 项？', style: const TextStyle(fontSize: 16)),
        content: const Text(
          '会一并删除应用目录里的文件，已导出到相册 / 下载目录的副本不受影响。',
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }
}

/// 把队列任务整理成下载库关心的集合。单独一层是为了让分组逻辑可单测，
/// 不必起 Widget 测试就能验证「只有 completed 且有文件才进来」。
class DownloadQueueTasks {
  DownloadQueueTasks(this.all);

  final List<DownloadTask> all;

  List<DownloadTask> get completed => all
      .where(
        (DownloadTask t) =>
            t.status == DownloadStatus.completed && t.savedPath != null,
      )
      .toList();
}

/// 下载库的分组。HLS / DASH 合并后都是视频文件，归到视频组。
enum LibraryGroup {
  video,
  audio,
  image,
  other;

  String get label => switch (this) {
    LibraryGroup.video => '视频',
    LibraryGroup.audio => '音频',
    LibraryGroup.image => '图片',
    LibraryGroup.other => '其他',
  };

  IconData get icon => switch (this) {
    LibraryGroup.video => Icons.movie_outlined,
    LibraryGroup.audio => Icons.audiotrack_outlined,
    LibraryGroup.image => Icons.image_outlined,
    LibraryGroup.other => Icons.insert_drive_file_outlined,
  };
}

LibraryGroup groupFor(MediaType type) => switch (type) {
  MediaType.audio => LibraryGroup.audio,
  MediaType.image => LibraryGroup.image,
  MediaType.video || MediaType.hls || MediaType.dash => LibraryGroup.video,
  MediaType.other => LibraryGroup.other,
};

class _Group extends StatelessWidget {
  const _Group({
    required this.group,
    required this.tasks,
    required this.selected,
    required this.selecting,
    required this.onToggle,
    required this.onDelete,
  });

  final LibraryGroup group;
  final List<DownloadTask> tasks;
  final Set<String> selected;
  final bool selecting;
  final void Function(String id) onToggle;
  final void Function(DownloadTask task) onDelete;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Row(
            children: <Widget>[
              Icon(group.icon, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                group.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${tasks.length}',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ],
          ),
        ),
        for (final DownloadTask task in tasks)
          _LibraryTile(
            task: task,
            group: group,
            selected: selected.contains(task.id),
            selecting: selecting,
            onToggle: onToggle,
            onDelete: onDelete,
          ),
      ],
    );
  }
}

class _LibraryTile extends ConsumerWidget {
  const _LibraryTile({
    required this.task,
    required this.group,
    required this.selected,
    required this.selecting,
    required this.onToggle,
    required this.onDelete,
  });

  final DownloadTask task;
  final LibraryGroup group;
  final bool selected;
  final bool selecting;
  final void Function(String id) onToggle;
  final void Function(DownloadTask task) onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String size = FormatUtil.bytes(task.totalBytes);

    return ListTile(
      selected: selected,
      selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.35),
      leading: selecting
          ? Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? scheme.primary : scheme.outline,
            )
          : CircleAvatar(
              backgroundColor: scheme.secondaryContainer,
              child: Icon(
                group.icon,
                size: 18,
                color: scheme.onSecondaryContainer,
              ),
            ),
      title: Text(
        task.fileName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: Text(
        [
          if (size.isNotEmpty) size,
          task.container?.toUpperCase() ?? '',
        ].where((String s) => s.isNotEmpty).join(' · '),
        style: TextStyle(fontSize: 11, color: scheme.outline),
      ),
      onTap: selecting
          ? () => onToggle(task.id)
          : () async {
              final String? path = task.savedPath;
              if (path == null) return;
              if (!await MediaExporter.openFile(path)) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('没有找到能打开这个文件的应用')));
              }
            },
      // 长按进多选：比先找「多选」按钮顺手，和系统文件管理器一致。
      onLongPress: () => onToggle(task.id),
      trailing: selecting
          ? null
          : PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 18),
              padding: EdgeInsets.zero,
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(value: 'open', child: Text('打开')),
                if (PlatformInfo.current == AppPlatform.android)
                  const PopupMenuItem<String>(
                    value: 'share',
                    child: Text('分享'),
                  ),
                const PopupMenuItem<String>(value: 'export', child: Text('导出')),
                const PopupMenuItem<String>(
                  value: 'remove',
                  child: Text('移除记录'),
                ),
                const PopupMenuItem<String>(
                  value: 'delete',
                  child: Text('删除文件'),
                ),
              ],
              onSelected: (String value) async {
                final ScaffoldMessengerState messenger = ScaffoldMessenger.of(
                  context,
                );
                final String? path = task.savedPath;
                final DownloadQueue queue = ref.read(downloadQueueProvider);
                switch (value) {
                  case 'open':
                    if (path != null && !await MediaExporter.openFile(path)) {
                      messenger.showSnackBar(
                        const SnackBar(content: Text('没有找到能打开这个文件的应用')),
                      );
                    }
                  case 'share':
                    if (path != null && !await MediaExporter.shareFile(path)) {
                      messenger.showSnackBar(
                        const SnackBar(content: Text('没有找到能分享这个文件的应用')),
                      );
                    }
                  case 'export':
                    final ExportResult result = await queue.export(task.id);
                    messenger.showSnackBar(
                      SnackBar(content: Text(result.displayMessage)),
                    );
                  case 'remove':
                    queue.remove(task.id);
                  case 'delete':
                    // 删文件不可逆，走多选里那条带确认的路径，不在这里另写一套。
                    onToggle(task.id);
                    onDelete(task);
                }
              },
            ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.hasQuery});

  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            hasQuery ? Icons.search_off : Icons.folder_open_outlined,
            size: 40,
            color: scheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            hasQuery ? '没有匹配的文件' : '下载库还是空的',
            style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
          ),
          if (!hasQuery)
            Text(
              '下载完成的文件会出现在这里',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
        ],
      ),
    );
  }
}
