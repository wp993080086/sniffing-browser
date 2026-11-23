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

    return Scaffold(
      appBar: AppBar(
        title: const Text('下载库', style: TextStyle(fontSize: 17)),
        actions: <Widget>[
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
                          ),
                    ],
                  ),
          ),
        ],
      ),
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
  const _Group({required this.group, required this.tasks});

  final LibraryGroup group;
  final List<DownloadTask> tasks;

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
          _LibraryTile(task: task, group: group),
      ],
    );
  }
}

class _LibraryTile extends ConsumerWidget {
  const _LibraryTile({required this.task, required this.group});

  final DownloadTask task;
  final LibraryGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String size = FormatUtil.bytes(task.totalBytes);

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.secondaryContainer,
        child: Icon(group.icon, size: 18, color: scheme.onSecondaryContainer),
      ),
      title: Text(
        task.fileName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: Text(
        [if (size.isNotEmpty) size, task.container?.toUpperCase() ?? '']
            .where((String s) => s.isNotEmpty)
            .join(' · '),
        style: TextStyle(fontSize: 11, color: scheme.outline),
      ),
      onTap: () async {
        final String? path = task.savedPath;
        if (path == null) return;
        if (!await MediaExporter.openFile(path)) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('没有找到能打开这个文件的应用')),
          );
        }
      },
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 18),
        padding: EdgeInsets.zero,
        itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
          const PopupMenuItem<String>(value: 'open', child: Text('打开')),
          if (PlatformInfo.current == AppPlatform.android)
            const PopupMenuItem<String>(value: 'share', child: Text('分享')),
          const PopupMenuItem<String>(value: 'export', child: Text('导出')),
          const PopupMenuItem<String>(value: 'remove', child: Text('移除记录')),
        ],
        onSelected: (String value) async {
          final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
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
