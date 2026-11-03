import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/utils/format_util.dart';
import '../../downloader/domain/download_task.dart';
import '../domain/media_item.dart';
import '../domain/media_type.dart';

/// 单条捕获结果。
class ResourceTile extends ConsumerWidget {
  const ResourceTile({super.key, required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final MediaType type = item.type;

    return ListTile(
      dense: true,
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(_iconFor(type), size: 18, color: scheme.onPrimaryContainer),
      ),
      title: Text(
        item.fileName ?? item.url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        <String>[
          type.label,
          if (item.contentLength != null) FormatUtil.bytes(item.contentLength),
          if (item.label != null) item.label!,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.download_rounded, size: 20),
        tooltip: '下载',
        onPressed: () {
          // 把整页资源一起传下去：DASH 站点的画面和声音是两条独立的 m4s，
          // 只下视频轨得到的是哑的。队列会自己配对、自己合并。
          final DownloadTask task = ref.read(downloadQueueProvider).enqueue(
                item,
                pool: ref.read(snifferProvider).items,
              );
          final String hint = task.pairedTaskId != null ? '（已配对音轨，完成后自动合并）' : '';
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text('已加入下载队列：${task.fileName}$hint'),
                duration: const Duration(seconds: 2),
              ),
            );
        },
      ),
    );
  }

  IconData _iconFor(MediaType type) {
    switch (type) {
      case MediaType.image:
        return Icons.image_outlined;
      case MediaType.audio:
        return Icons.music_note_outlined;
      case MediaType.video:
        return Icons.movie_outlined;
      case MediaType.hls:
        return Icons.playlist_play_rounded;
      case MediaType.dash:
        return Icons.dashboard_customize_outlined;
      case MediaType.other:
        return Icons.insert_drive_file_outlined;
    }
  }
}
