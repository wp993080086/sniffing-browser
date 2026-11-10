import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/platform/media_exporter.dart';
import '../../../core/platform/platform_info.dart';
import '../../../core/utils/format_util.dart';
import '../../transcoder/data/transcode_queue.dart';
import '../../transcoder/domain/transcode_job.dart';
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
              _TranscodeStatus(task: task),
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
        final List<String> parts = <String>['已完成'];
        if (task.container != null) parts.add(task.container!.toUpperCase());
        // null 表示没有音轨概念（普通文件），只有确实尝试过配对才给结论。
        if (task.mergedAudio == true) parts.add('含音轨');
        if (task.mergedAudio == false) parts.add('无音轨');
        if (task.needsRemux) parts.add('可转为 MP4');
        return parts.join(' · ');
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

  /// 这个任务能转成什么。已完成、有本地文件、格式匹配才给入口。
  List<TranscodeKind> _availableKinds(WidgetRef ref) {
    final String? path = task.savedPath;
    if (path == null || task.status != DownloadStatus.completed) {
      return const <TranscodeKind>[];
    }
    if (task.isCompanion) return const <TranscodeKind>[];

    final TranscodeQueue queue = ref.read(transcodeQueueProvider);

    // 合并还没走完时不给任何手动入口：合并成功会覆盖源文件，
    // 这时候去读那个 mp4 可能拿到只写了一半的内容。
    final bool merging = queue.jobs.any((TranscodeJob j) =>
        j.sourceTaskId == task.id &&
        j.kind.needsSecondaryInput &&
        !j.status.isFinished);
    if (merging) return const <TranscodeKind>[];

    // 已经有转换任务（含未完成）就不再提供，避免重复入队。
    // 合并音视频不算 —— 它是队列自动排的收尾动作，不该挡住用户手动转码。
    final bool hasJob = queue.jobs.any((TranscodeJob j) =>
        j.sourceTaskId == task.id && !j.kind.needsSecondaryInput);
    if (hasJob) return const <TranscodeKind>[];

    return <TranscodeKind>[
      for (final TranscodeKind kind in TranscodeKind.values)
        // mergedAudio 直接当「这个文件带音轨吗」的答案：
        // true 是合并产物，false 是纯视频轨，null 是没探测过（普通下载）。
        if (kind.appliesTo(task.type, path, hasAudio: task.mergedAudio)) kind,
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool canExport = task.status == DownloadStatus.completed;
    final List<TranscodeKind> kinds = _availableKinds(ref);

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
        for (final TranscodeKind kind in kinds)
          PopupMenuItem<String>(
            value: 'transcode:${kind.name}',
            child: Text(kind.label),
          ),
        const PopupMenuItem<String>(value: 'remove', child: Text('移除记录')),
      ],
      onSelected: (String value) async {
        final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
        if (value.startsWith('transcode:')) {
          final String name = value.substring('transcode:'.length);
          final TranscodeKind kind = TranscodeKind.values.firstWhere(
            (TranscodeKind k) => k.name == name,
          );
          final String? path = task.savedPath;
          if (path == null) return;

          final TranscodeQueue queue = ref.read(transcodeQueueProvider);
          if (!await queue.availability()) {
            messenger
              ..hideCurrentSnackBar()
              ..showSnackBar(const SnackBar(content: Text('没有找到 ffmpeg，无法转换')));
            return;
          }

          final TranscodeJob job = queue.enqueue(
            sourcePath: path,
            kind: kind,
            sourceTaskId: task.id,
            displayName: task.fileName,
          );
          messenger
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text('已加入转换队列：${job.displayName}')));
          return;
        }

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

/// 转换状态行。只在有对应转换任务时出现。
class _TranscodeStatus extends ConsumerWidget {
  const _TranscodeStatus({required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TranscodeQueue queue = ref.watch(transcodeQueueProvider);
    TranscodeJob? job;
    for (final TranscodeJob candidate in queue.jobs) {
      if (candidate.sourceTaskId == task.id) {
        job = candidate;
        break;
      }
    }
    if (job == null) return const SizedBox.shrink();

    final TranscodeJob current = job;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        current.statusNotifier,
        current.progress,
      ]),
      builder: (BuildContext context, Widget? _) {
        final String text;
        final Color color;
        switch (current.status) {
          case TranscodeStatus.pending:
            text = '${current.kind.label}：等待中';
            color = scheme.onSurfaceVariant;
          case TranscodeStatus.running:
            final int percent = (current.progress.value * 100).round();
            text = '${current.kind.label}：$percent%';
            color = scheme.primary;
          case TranscodeStatus.completed:
            text = current.kind.needsSecondaryInput
                ? '已合并音轨'
                : '已转换为 ${current.kind.extension.toUpperCase()}';
            color = scheme.primary;
          case TranscodeStatus.failed:
            text = '转换失败：${current.error ?? "未知原因"}';
            color = scheme.error;
          case TranscodeStatus.canceled:
            text = '转换已取消';
            color = scheme.onSurfaceVariant;
        }

        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: color),
                ),
              ),
              if (current.status == TranscodeStatus.running)
                IconButton(
                  icon: const Icon(Icons.close, size: 14),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: '取消转换',
                  onPressed: () =>
                      ref.read(transcodeQueueProvider).cancel(current.id),
                ),
            ],
          ),
        );
      },
    );
  }
}
