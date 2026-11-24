import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../downloader/data/download_queue.dart';
import '../../downloader/domain/download_task.dart';
import '../../downloader/domain/track_option.dart';
import '../domain/media_item.dart';

/// 把一条嗅探结果加入下载队列，并把结果提示出来。
///
/// 抽成函数而不是各自复制：嗅探列表和预览页都要这一个动作，两处逻辑一旦分叉
/// 就会出现「列表下载能配对音轨、预览页下载不会」这种难查的差异。
void enqueueDownload(
  BuildContext context,
  WidgetRef ref,
  MediaItem item, {
  bool popOnDone = false,
  String? videoTrackId,
  String? audioTrackId,
  String? subtitleTrackId,
  String? subtitleTag,
}) {
  // 把整页资源一起传下去：DASH 站点的画面和声音是两条独立的 m4s，
  // 只下视频轨得到的是哑的。队列会自己配对、自己合并。
  final DownloadTask task = ref
      .read(downloadQueueProvider)
      .enqueue(
        item,
        pool: ref.read(snifferProvider).items,
        // 标题要到 handleLoadStop 之后才拿得到，嗅探那一刻还是上一页的；
        // 而换页会清空嗅探列表，所以当前页就是这条资源的来源页。
        pageTitle: ref.read(tabManagerProvider).title,
        videoTrackId: videoTrackId,
        audioTrackId: audioTrackId,
        subtitleTrackId: subtitleTrackId,
        subtitleTag: subtitleTag,
      );
  final String hint = task.pairedTaskId != null ? '（已配对音轨，完成后自动合并）' : '';
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  if (popOnDone) Navigator.of(context).maybePop();
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('已加入下载队列：${task.fileName}$hint'),
        duration: const Duration(seconds: 2),
      ),
    );
}

/// 带轨道选择的下载。
///
/// 普通文件直接入队；HLS / DASH 先探一次清单：只有一条轨（或探测失败）就直接
/// 下，有多条才弹选择。**探不出来也要能下** —— 选择清晰度是锦上添花，
/// 不该成为下载的前置条件。
Future<void> downloadWithChoice(
  BuildContext context,
  WidgetRef ref,
  MediaItem item,
) async {
  if (!item.type.isStream) {
    enqueueDownload(context, ref, item);
    return;
  }

  final DownloadQueue queue = ref.read(downloadQueueProvider);
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      const SnackBar(
        content: Text('正在读取可用清晰度…'),
        duration: Duration(seconds: 1),
      ),
    );

  final List<TrackOption> options = await queue.probeTracks(item);
  if (!context.mounted) return;

  final List<TrackOption> video = options
      .where((TrackOption o) => o.group == TrackGroup.video)
      .toList();
  final List<TrackOption> audio = options
      .where((TrackOption o) => o.group == TrackGroup.audio)
      .toList();
  final List<TrackOption> subtitles = options
      .where((TrackOption o) => o.group == TrackGroup.subtitle)
      .toList();

  if (video.length <= 1 && audio.length <= 1 && subtitles.isEmpty) {
    enqueueDownload(
      context,
      ref,
      item,
      videoTrackId: video.isEmpty ? null : video.first.id,
      audioTrackId: audio.isEmpty ? null : audio.first.id,
    );
    return;
  }

  final _TrackChoice? choice = await showModalBottomSheet<_TrackChoice>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext context) =>
        _TrackSheet(video: video, audio: audio, subtitles: subtitles),
  );
  if (choice == null || !context.mounted) return;

  enqueueDownload(
    context,
    ref,
    item,
    popOnDone: true,
    videoTrackId: choice.videoId,
    audioTrackId: choice.audioId,
    subtitleTrackId: choice.subtitle?.id,
    subtitleTag: choice.subtitle?.tag,
  );
}

/// 面板输出：三组各选一个，字幕可以选「不下载」。
class _TrackChoice {
  const _TrackChoice({this.videoId, this.audioId, this.subtitle});

  final String? videoId;
  final String? audioId;
  final TrackOption? subtitle;
}

/// 选清晰度 / 音轨 / 字幕的底部面板。
class _TrackSheet extends StatefulWidget {
  const _TrackSheet({
    required this.video,
    required this.audio,
    required this.subtitles,
  });

  final List<TrackOption> video;
  final List<TrackOption> audio;
  final List<TrackOption> subtitles;

  @override
  State<_TrackSheet> createState() => _TrackSheetState();
}

class _TrackSheetState extends State<_TrackSheet> {
  String? _videoId;
  String? _audioId;

  /// null 表示不下载字幕 —— 默认就是它：多数人只要视频，
  /// 悄悄多下一个文件比多问一句更烦人。
  TrackOption? _subtitle;

  @override
  void initState() {
    super.initState();
    // 默认落在第一项：探出来的顺序已经是「好的在前」，用户不改就是它。
    if (widget.video.isNotEmpty) _videoId = widget.video.first.id;
    if (widget.audio.isNotEmpty) _audioId = widget.audio.first.id;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              '选择要下载的轨道',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                if (widget.video.isNotEmpty) ...<Widget>[
                  _GroupLabel(TrackGroup.video.label),
                  for (final TrackOption option in widget.video)
                    _OptionTile(
                      label: option.label,
                      selected: _videoId == option.id,
                      onTap: () => setState(() => _videoId = option.id),
                    ),
                ],
                if (widget.audio.isNotEmpty) ...<Widget>[
                  _GroupLabel(TrackGroup.audio.label),
                  for (final TrackOption option in widget.audio)
                    _OptionTile(
                      label: option.label,
                      selected: _audioId == option.id,
                      onTap: () => setState(() => _audioId = option.id),
                    ),
                ],
                if (widget.subtitles.isNotEmpty) ...<Widget>[
                  _GroupLabel(TrackGroup.subtitle.label),
                  _OptionTile(
                    label: '不下载',
                    selected: _subtitle == null,
                    onTap: () => setState(() => _subtitle = null),
                  ),
                  for (final TrackOption option in widget.subtitles)
                    _OptionTile(
                      label: option.label,
                      selected: _subtitle?.id == option.id,
                      onTap: () => setState(() => _subtitle = option),
                    ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(
                  _TrackChoice(
                    videoId: _videoId,
                    audioId: _audioId,
                    subtitle: _subtitle,
                  ),
                ),
                child: const Text('开始下载'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          color: selected ? scheme.primary : scheme.onSurface,
        ),
      ),
      trailing: selected
          ? Icon(Icons.check, size: 18, color: scheme.primary)
          : null,
      onTap: onTap,
    );
  }
}
