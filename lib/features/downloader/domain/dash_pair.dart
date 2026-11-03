import 'package:path/path.dart' as p;

import '../../sniffer/domain/media_classifier.dart';
import '../../sniffer/domain/media_item.dart';
import '../../sniffer/domain/media_type.dart';

/// 一对可以合并的 DASH 音视频分片。
class DashPair {
  const DashPair({required this.video, required this.audio});

  final MediaItem video;
  final MediaItem audio;
}

/// DASH 音视频配对。
///
/// 为什么需要这个：B 站这类站点走 DASH，画面和声音是**两条独立请求**，
/// 各自一个 `.m4s`。只下视频轨得到的 mp4 是哑的，只下音频轨没有画面。
/// 用户在资源列表里看到两条，很难自己判断该点哪条、更不会想到要合并。
///
/// 配对依据只能是文件名：两条 URL 的主机、query 签名、路径全都不一样
/// （音视频可以落在不同的 CDN 节点上），唯一稳定的共同点是文件名前缀：
///
/// ```
/// 42977332133-1-30016.m4s   视频轨（不同清晰度是 -30080 / -30064 ...）
/// 42977332133-1-30280.m4s   音频轨
/// └──── key ────┘
/// ```
///
/// 所以把「末尾的纯数字段」剥掉再比较。数字段是清晰度 / 音质编码，
/// 同一视频的所有变体剥完是同一条 key，不同视频（不同 aid）则不同。
class DashPairer {
  const DashPairer._();

  /// 是否是 DASH 分片。只认 `.m4s` —— 普通 mp4 自己就带音轨，不需要配对。
  ///
  /// 注意这里看的是 URL 而不是 fileName：入队前 `guessFileName` 已经把
  /// `.m4s` 改写成了 `.mp4` / `.m4a`，用 fileName 判断会全部落空。
  static bool isDashSegment(MediaItem item) =>
      MediaClassifier.extensionOf(item.url) == 'm4s';

  static bool isDashSegmentUrl(String url) =>
      MediaClassifier.extensionOf(url) == 'm4s';

  /// 为一条视频轨找它对应的音频轨。找不到返回 null（照常单轨下载）。
  static MediaItem? findAudioFor(MediaItem video, List<MediaItem> pool) {
    if (video.type != MediaType.video) return null;
    if (!isDashSegment(video)) return null;

    final List<MediaItem> audios = pool
        .where((MediaItem item) =>
            item.id != video.id &&
            item.type == MediaType.audio &&
            isDashSegment(item))
        .toList();
    if (audios.isEmpty) return null;

    // 1. 前缀精确匹配。同一视频的多个清晰度会命中同一条音频轨，
    //    取码率最高的一条：URL 上的数字段越大通常是越好的音质。
    final String key = pairKey(video.url);
    if (key.isNotEmpty) {
      final List<MediaItem> matched = audios
          .where((MediaItem audio) => pairKey(audio.url) == key)
          .toList();
      if (matched.isNotEmpty) return _best(matched);
    }

    // 2. 兜底：整页只有一条视频轨、一条音频轨时直接配。
    //    有些站点两条文件名叫 `video.m4s` / `audio.m4s`，前缀毫无关系。
    //    加这两个长度为 1 的限制，是为了避免页面上有多个视频时配错。
    final List<MediaItem> videos = pool
        .where((MediaItem item) =>
            item.type == MediaType.video && isDashSegment(item))
        .toList();
    if (videos.length == 1 && videos.first.id == video.id && audios.length == 1) {
      return audios.first;
    }

    return null;
  }

  /// 合成配对键：去掉扩展名和末尾的纯数字段，小写。
  ///
  /// `42977332133-1-30016.m4s` -> `42977332133-1`
  /// `audio_30280.m4s`         -> `audio`
  /// `video.m4s`               -> `video`（配不上，靠 fallback）
  static String pairKey(String url) {
    final Uri? uri = Uri.tryParse(url);
    final String raw = (uri != null && uri.pathSegments.isNotEmpty)
        ? uri.pathSegments.last
        : '';
    if (raw.isEmpty) return '';

    String base = p.basenameWithoutExtension(Uri.decodeComponent(raw));
    // 末尾的 `-30016` / `_30280` / `.30016`：至少三位数字，避免误伤 `-1`、`-2`
    base = base.replaceFirst(RegExp(r'[-_.]\d{3,}$'), '');
    return base.toLowerCase();
  }

  /// 从同一 key 的多条音频里挑一条。
  ///
  /// 当前只有 B 站这一个真实样本，它的音质编码是单调的（30216 < 30232 < 30280），
  /// 所以取数字段最大的即可。拿不到数字时退化为第一条。
  static MediaItem _best(List<MediaItem> audios) {
    if (audios.length == 1) return audios.first;
    MediaItem best = audios.first;
    int bestScore = _score(best.url);
    for (final MediaItem candidate in audios.skip(1)) {
      final int score = _score(candidate.url);
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    return best;
  }

  static int _score(String url) {
    final Uri? uri = Uri.tryParse(url);
    final String raw = (uri != null && uri.pathSegments.isNotEmpty)
        ? uri.pathSegments.last
        : '';
    final String base = p.basenameWithoutExtension(raw);
    final RegExpMatch? match = RegExp(r'(\d{3,})$').firstMatch(base);
    return match == null ? 0 : (int.tryParse(match.group(1)!) ?? 0);
  }
}
