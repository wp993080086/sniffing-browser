import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../data/download_queue.dart';
import '../domain/download_task.dart';
import 'download_tile.dart';

class DownloadPage extends ConsumerWidget {
  const DownloadPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DownloadQueue queue = ref.watch(downloadQueueProvider);
    // 伴随任务（DASH 自动补的音频轨）不单独展示，它只是合并的中间产物。
    final List<DownloadTask> tasks = queue.visibleTasks;

    return Scaffold(
      appBar: AppBar(
        title: const Text('下载', style: TextStyle(fontSize: 17)),
        actions: <Widget>[
          if (tasks.any((DownloadTask t) => t.status.isFinished))
            TextButton(
              onPressed: () => ref.read(downloadQueueProvider).clearFinished(),
              child: const Text('清空已完成', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
      body: tasks.isEmpty
          ? const _Empty()
          : ListView.separated(
              itemCount: tasks.length,
              separatorBuilder: (BuildContext context, int index) =>
                  const Divider(height: 1),
              itemBuilder: (BuildContext context, int index) =>
                  DownloadTile(task: tasks[index]),
            ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.download_outlined, size: 40, color: scheme.outline),
          const SizedBox(height: 12),
          Text(
            '还没有下载任务',
            style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
