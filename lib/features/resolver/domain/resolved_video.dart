import '../../../core/platform/storage_paths.dart';
import '../../../core/utils/format_util.dart';

/// 一次解析拿到的视频。
///
/// 和 [MediaItem] 的区别：那个是「嗅探到的一条网络资源」，这个是从站点接口里
/// 捞出来的成品 —— 有标题、有作者、有封面，能直接给人看。
class ResolvedVideo {
  const ResolvedVideo({
    required this.url,
    required this.title,
    this.author = '',
    this.cover = '',
    this.sizeBytes = 0,
    this.durationMs = 0,
    this.videoId = '',
  });

  /// 完整 mp4 直链（抖音的 `play_addr.url_list[0]`）。
  final String url;

  final String title;
  final String author;
  final String cover;

  /// 字节数。接口里叫 `data_size`，拿不到就是 0。
  final int sizeBytes;

  final int durationMs;
  final String videoId;

  /// JS 传回来的 JSON 裁剪过一遍，但字段仍可能缺失或类型不一致
  /// （`0` / `"0"` / `null` 都出现过），这里一律按「取不到就用默认值」处理。
  factory ResolvedVideo.fromJson(Map<String, Object?> json) {
    String text(String key) {
      final Object? value = json[key];
      return value == null ? '' : '$value'.trim();
    }

    int number(String key) {
      final Object? value = json[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    }

    return ResolvedVideo(
      url: text('url'),
      title: text('title'),
      author: text('author'),
      cover: text('cover'),
      sizeBytes: number('size'),
      durationMs: number('duration'),
      videoId: text('id'),
    );
  }

  /// 直链必须是 http(s)。抖音偶尔会给一个空串或相对路径，那种不能入队。
  bool get isUsable => url.startsWith('http://') || url.startsWith('https://');

  /// 卡片上显示的标题。无文案的视频退回作者名。
  String get displayName {
    if (title.isNotEmpty) return title;
    if (author.isNotEmpty) return author;
    return '抖音视频';
  }

  /// 落盘文件名。作者 + 标题 —— 单看标题很容易和别的视频重名，
  /// 带上作者至少能在下载目录里一眼认出来自谁。
  String get fileName {
    final String base = author.isEmpty || title.isEmpty
        ? displayName
        : '$author - $title';
    return StoragePaths.sanitizeFileName('$base.mp4');
  }

  String get sizeLabel => sizeBytes > 0 ? FormatUtil.bytes(sizeBytes) : '';

  String get durationLabel => durationMs > 0
      ? FormatUtil.duration(Duration(milliseconds: durationMs))
      : '';

  /// 卡片副标题：作者 · 时长 · 大小，空项自动省略。
  String get subtitle {
    final List<String> parts = <String>[
      if (author.isNotEmpty) author,
      if (durationLabel.isNotEmpty) durationLabel,
      if (sizeLabel.isNotEmpty) sizeLabel,
    ];
    return parts.join(' · ');
  }
}
