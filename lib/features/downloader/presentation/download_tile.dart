import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/platform/media_exporter.dart';
import '../../../core/platform/platform_info.dart';
import '../../../core/utils/format_util.dart';
import '../domain/download_status.dart';
import '../domain/download_task.dart';

/// 下载列表项。
///
/// 只订阅自己这个任务的三个 notifier，队列里其他任务推进进度不会让它重建。
class DownloadTile extends ConsumerWidget {
  const DownloadTile({super.key, required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        task.progress,
        task.speed,
        task.statusNotifier,
      ]),
      builder: (BuildContext context, Widget? child) {
        final DownloadStatus status = task.status;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      task.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  _Menu(task: task),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: status == DownloadStatus.running ||
                          status == DownloadStatus.completed
                      ? task.progress.value
                      : (status == DownloadStatus.failed ? 0 : null),
                  minHeight: 3,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _statusText(status),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: status == DownloadStatus.failed
                            ? scheme.error
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (status == DownloadStatus.running && task.speed.value > 0)
                    Text(
                      FormatUtil.speed(task.speed.value),
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  String _statusText(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.pending:
        return '等待中';
      case DownloadStatus.running:
        if (task.isStream) {
          final int total = task.totalSegments ?? 0;
          return total > 0
              ? '${task.segmentDone}/$total 分片'
              : '${task.segmentDone} 分片已下载';
        }
        final int percent = (task.progress.value * 100).round();
        final String size = FormatUtil.bytes(task.totalBytes);
        return '$percent% · $size';
      case DownloadStatus.paused:
        return '已暂停';
      case DownloadStatus.completed:
        return '已完成${task.container != null ? ' · ${task.container!.toUpperCase()}' : ''}'
            '${task.needsRemux ? ' · 可转为 MP4' : ''}';
      case DownloadStatus.failed:
        return task.error ?? '下载失败';
      case DownloadStatus.canceled:
        return '已取消';
    }
  }
}

class _Menu extends ConsumerWidget {
  const _Menu({required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool canExport = task.status == DownloadStatus.completed;

    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 18),
      padding: EdgeInsets.zero,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        if (task.status == DownloadStatus.running ||
            task.status == DownloadStatus.pending)
          const PopupMenuItem<String>(value: 'cancel', child: Text('取消')),
        if (task.status.canRetry)
          const PopupMenuItem<String>(value: 'retry', child: Text('重试')),
        if (canExport)
          PopupMenuItem<String>(
            value: 'export',
            child: Text(
              PlatformInfo.isDesktop
                  ? '另存到下载目录'
                  : (MediaExporter.targetFor(task.type) == ExportTarget.gallery
                      ? '保存到相册'
                      : '保存到音乐目录'),
            ),
          ),
        const PopupMenuItem<String>(value: 'remove', child: Text('移除记录')),
      ],
      onSelected: (String value) async {
        final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
        switch (value) {
          case 'cancel':
            ref.read(downloadQueueProvider).cancel(task.id);
          case 'retry':
            ref.read(downloadQueueProvider).retry(task.id);
          case 'export':
            final ExportResult result =
                await ref.read(downloadQueueProvider).export(task.id);
            messenger
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text(result.displayMessage)));
          case 'remove':
            ref.read(downloadQueueProvider).remove(task.id);
        }
      },
    );
  }
}
