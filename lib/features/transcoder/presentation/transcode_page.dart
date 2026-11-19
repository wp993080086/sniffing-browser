import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../app/providers.dart';
import '../../../core/platform/media_exporter.dart';
import '../data/transcode_queue.dart';
import '../domain/transcode_job.dart';

/// 转换任务列表。
///
/// 之前进度只在下载项里挂一行小字，点过「转为 MP3」之后既没入口也没全局视图；
/// 移除下载记录后连那行小字都会消失。这里把转换任务独立成一个列表，
/// 和下载记录解耦，任务本身还会落盘（见 `TranscodeStore`）。
class TranscodePage extends ConsumerWidget {
  const TranscodePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TranscodeQueue queue = ref.watch(transcodeQueueProvider);
    final List<TranscodeJob> jobs = queue.jobs;
    final bool hasFinished = jobs.any(
      (TranscodeJob job) => job.status.isFinished,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('转换', style: TextStyle(fontSize: 17)),
        actions: <Widget>[
          if (hasFinished)
            TextButton(
              onPressed: () => ref.read(transcodeQueueProvider).clearFinished(),
              child: const Text('清空已完成', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
      body: jobs.isEmpty
          ? const _Empty()
          : ListView.separated(
              itemCount: jobs.length,
              separatorBuilder: (BuildContext context, int index) =>
                  const Divider(height: 1),
              itemBuilder: (BuildContext context, int index) =>
                  _JobTile(job: jobs[index]),
            ),
    );
  }
}

class _JobTile extends ConsumerWidget {
  const _JobTile({required this.job});

  final TranscodeJob job;

  /// 完成后的落点。Android 入库成功时是「已保存到「音乐/SniffingBrowser」」，
  /// 桌面没有入库这一步，退回显示产物文件名。
  String _doneText() {
    if (job.kind.needsSecondaryInput) return '已合并到原视频文件';
    final String? message = job.exportMessage;
    if (message != null && message.isNotEmpty) return message;
    return '产物：${p.basename(job.outputPath)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        job.statusNotifier,
        job.progress,
      ]),
      builder: (BuildContext context, Widget? child) {
        final TranscodeStatus status = job.status;
        final int percent = (job.progress.value * 100).round();

        final String detail;
        final Color detailColor;
        switch (status) {
          case TranscodeStatus.pending:
            detail = '${job.kind.label} · 等待中';
            detailColor = scheme.onSurfaceVariant;
          case TranscodeStatus.running:
            detail = '${job.kind.label} · $percent%';
            detailColor = scheme.primary;
          case TranscodeStatus.completed:
            detail = _doneText();
            detailColor = scheme.primary;
          case TranscodeStatus.failed:
            detail = '${job.kind.label} · ${job.error ?? '失败'}';
            detailColor = scheme.error;
          case TranscodeStatus.canceled:
            detail = '${job.kind.label} · 已取消';
            detailColor = scheme.onSurfaceVariant;
        }

        final double barValue = switch (status) {
          TranscodeStatus.running => job.progress.value,
          TranscodeStatus.completed => 1,
          _ => 0,
        };

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      job.displayName ?? p.basename(job.sourcePath),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  _Menu(job: job),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: barValue,
                  minHeight: 3,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: detailColor),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Menu extends ConsumerWidget {
  const _Menu({required this.job});

  final TranscodeJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool running =
        job.status == TranscodeStatus.running ||
        job.status == TranscodeStatus.pending;

    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 18),
      padding: EdgeInsets.zero,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        if (job.status == TranscodeStatus.completed)
          const PopupMenuItem<String>(value: 'open', child: Text('打开')),
        if (running)
          const PopupMenuItem<String>(value: 'cancel', child: Text('取消')),
        if (job.status.isFinished)
          const PopupMenuItem<String>(value: 'retry', child: Text('重试')),
        const PopupMenuItem<String>(value: 'remove', child: Text('移除记录')),
      ],
      onSelected: (String value) async {
        final TranscodeQueue queue = ref.read(transcodeQueueProvider);
        switch (value) {
          case 'open':
            // 先抓 messenger：await 之后 context 可能已经失效。
            final ScaffoldMessengerState messenger = ScaffoldMessenger.of(
              context,
            );
            final bool ok = await MediaExporter.openFile(
              job.mediaUri ?? job.artifactPath,
            );
            if (!ok) {
              messenger
                ..hideCurrentSnackBar()
                ..showSnackBar(const SnackBar(content: Text('没有找到能打开这个文件的应用')));
            }
          case 'cancel':
            queue.cancel(job.id);
          case 'retry':
            queue.retry(job.id);
          case 'remove':
            queue.remove(job.id);
        }
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.sync_alt, size: 40, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              '还没有转换任务',
              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Text(
              '在下载列表里点某条记录的 ⋮，选择「转为 MP3 / 转为 MP4」',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
