import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../data/sniffer_service.dart';
import '../domain/media_item.dart';
import '../domain/media_type.dart';
import 'resource_tile.dart';

/// 打开资源面板（半屏）。
Future<void> showResourcePanel(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (BuildContext context) => const FractionallySizedBox(
      heightFactor: 0.82,
      child: ResourcePanel(),
    ),
  );
}

class ResourcePanel extends ConsumerStatefulWidget {
  const ResourcePanel({super.key});

  @override
  ConsumerState<ResourcePanel> createState() => _ResourcePanelState();
}

class _ResourcePanelState extends ConsumerState<ResourcePanel> {
  /// null 表示“全部”。
  MediaType? _filter;

  @override
  Widget build(BuildContext context) {
    final SnifferService sniffer = ref.watch(snifferProvider);
    final List<MediaItem> all = sniffer.items;
    final List<MediaItem> visible = _filter == null
        ? all
        : all.where((MediaItem item) => item.type == _filter).toList();

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: <Widget>[
              const Text(
                '捕获到的资源',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Text(
                '${all.length}',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              if (all.isNotEmpty)
                TextButton(
                  onPressed: () => ref.read(snifferProvider).clear(),
                  child: const Text('清空', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ),
        SizedBox(
          height: 34,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: <Widget>[
              _FilterChip(
                label: '全部',
                count: all.length,
                selected: _filter == null,
                onTap: () => setState(() => _filter = null),
              ),
              for (final MediaType type in <MediaType>[
                MediaType.image,
                MediaType.video,
                MediaType.audio,
                MediaType.hls,
              ])
                _FilterChip(
                  label: type.label,
                  count: sniffer.countOf(type),
                  selected: _filter == type,
                  onTap: () => setState(() => _filter = type),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: visible.isEmpty
              ? const _EmptyState()
              : ListView.separated(
                  itemCount: visible.length,
                  separatorBuilder: (BuildContext context, int index) =>
                      const Divider(height: 1, indent: 60),
                  itemBuilder: (BuildContext context, int index) =>
                      ResourceTile(item: visible[index]),
                ),
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (count == 0 && !selected) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text('$label $count', style: const TextStyle(fontSize: 12)),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.radar, size: 40, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              '还没有捕获到资源',
              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Text(
              '打开一个含图片、音频或视频的页面，\n播放一下视频再回到这里看看。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}
