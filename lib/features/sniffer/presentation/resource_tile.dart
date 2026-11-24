import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/utils/format_util.dart';
import '../data/thumbnail_cache.dart';
import '../domain/media_item.dart';
import '../domain/media_type.dart';
import 'download_action.dart';
import 'media_preview_page.dart';

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
      leading: _ResourceThumb(item: item),
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
      // 点整行看预览，右侧按钮才是下载：列表里名字都长一个样，
      // 先看一眼比下完再删便宜。
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => MediaPreviewPage(item: item),
        ),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.download_rounded, size: 20),
        tooltip: '下载',
        onPressed: () => enqueueDownload(context, ref, item),
      ),
    );
  }
}

/// 列表左侧的缩略图。
///
/// 取不到图（403、超时、格式不支持、鸿蒙未接原生抽帧）时一律退回类型图标，
/// 不显示 loading，也不显示破图 —— 列表里几十条同时转圈比没有图更难看。
class _ResourceThumb extends ConsumerStatefulWidget {
  const _ResourceThumb({required this.item});

  final MediaItem item;

  @override
  ConsumerState<_ResourceThumb> createState() => _ResourceThumbState();
}

class _ResourceThumbState extends ConsumerState<_ResourceThumb> {
  static const double _size = 36;

  /// null 表示这个类型本来就没有缩略图（音频 / HLS / DASH / 其它）。
  Future<Uint8List?>? _future;

  @override
  void initState() {
    super.initState();
    _future = _start();
  }

  @override
  void didUpdateWidget(covariant _ResourceThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 列表复用 State 时 item 会换人，不重新取图就会串图。
    if (oldWidget.item.id != widget.item.id) {
      _future = _start();
    }
  }

  Future<Uint8List?>? _start() {
    final ThumbnailCache cache = ref.read(thumbnailCacheProvider);
    if (!cache.supports(widget.item.type)) return null;
    return cache.get(widget.item);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Future<Uint8List?>? future = _future;
    if (future == null) return _iconBox(scheme);

    return SizedBox(
      width: _size,
      height: _size,
      child: FutureBuilder<Uint8List?>(
        future: future,
        // 已经取过的直接出图，避免滚回来闪一下图标。
        initialData: ref.read(thumbnailCacheProvider).peek(widget.item.id),
        builder: (BuildContext context, AsyncSnapshot<Uint8List?> snapshot) {
          final Uint8List? bytes = snapshot.data;
          if (bytes == null) return _iconBox(scheme);
          return ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              bytes,
              width: _size,
              height: _size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder:
                  (BuildContext context, Object error, StackTrace? stack) =>
                      _iconBox(scheme),
            ),
          );
        },
      ),
    );
  }

  Widget _iconBox(ColorScheme scheme) {
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(
        _iconFor(widget.item.type),
        size: 18,
        color: scheme.onPrimaryContainer,
      ),
    );
  }
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
