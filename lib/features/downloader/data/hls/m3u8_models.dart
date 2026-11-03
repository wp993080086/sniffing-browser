/// HLS playlist 的数据模型。
///
/// 只覆盖下载所需的字段，不追求 RFC 8216 完整实现。
library;

/// 一条播放列表。master playlist 只有 [variants]，media playlist 只有 [segments]。
class M3u8Playlist {
  const M3u8Playlist({
    required this.baseUri,
    this.variants = const <M3u8Variant>[],
    this.segments = const <M3u8Segment>[],
    this.mediaSequence = 0,
    this.isEndList = false,
    this.initSegmentUrl,
    this.isFmp4 = false,
    this.targetDuration,
  });

  /// playlist 自身的地址。所有相对路径都必须基于它解析，
  /// 不能用页面 URL —— 这是最常见的错误来源。
  final Uri baseUri;

  final List<M3u8Variant> variants;
  final List<M3u8Segment> segments;
  final int mediaSequence;
  final bool isEndList;

  /// `#EXT-X-MAP` 的地址，fMP4 的初始化段。
  final String? initSegmentUrl;

  /// 是否为 fMP4 分片（`.m4s`）。决定合并后的容器是 mp4 还是 ts。
  final bool isFmp4;

  final double? targetDuration;

  bool get isMaster => variants.isNotEmpty;

  /// 总时长（秒）。
  double get totalDuration =>
      segments.fold<double>(0, (double sum, M3u8Segment s) => sum + s.duration);

  /// 合并后的容器扩展名。
  String get containerExtension => isFmp4 ? 'mp4' : 'ts';
}

class M3u8Variant {
  const M3u8Variant({
    required this.uri,
    this.bandwidth,
    this.resolution,
    this.codecs,
    this.name,
  });

  final Uri uri;
  final int? bandwidth;
  final String? resolution;
  final String? codecs;
  final String? name;

  /// 展示用标签，如 "1080p · 4.2 Mbps"。
  String get label {
    final List<String> parts = <String>[];
    if (resolution != null && resolution!.isNotEmpty) {
      parts.add(resolution!);
    } else if (name != null && name!.isNotEmpty) {
      parts.add(name!);
    }
    if (bandwidth != null && bandwidth! > 0) {
      final double mbps = bandwidth! / 1000000;
      parts.add('${mbps.toStringAsFixed(1)} Mbps');
    }
    return parts.isEmpty ? '未知码率' : parts.join(' · ');
  }
}

class M3u8Segment {
  const M3u8Segment({
    required this.uri,
    required this.sequence,
    this.duration = 0,
    this.key,
    this.byteRange,
    this.discontinuity = false,
  });

  final Uri uri;

  /// 媒体序列号。AES-128 未显式给 IV 时，用它构造 IV。
  final int sequence;
  final double duration;
  final M3u8Key? key;
  final M3u8ByteRange? byteRange;

  /// 编码切换点。拼接时不需要特殊处理，保留用于排查问题。
  final bool discontinuity;
}

class M3u8Key {
  const M3u8Key({
    required this.method,
    this.uri,
    this.iv,
    this.keyFormat,
  });

  /// NONE / AES-128 / SAMPLE-AES。
  final String method;
  final Uri? uri;

  /// 显式 IV，16 字节。
  final List<int>? iv;
  final String? keyFormat;

  bool get isNone => method.toUpperCase() == 'NONE';

  bool get isAes128 => method.toUpperCase() == 'AES-128';

  /// SAMPLE-AES 需要完整解密器，这里明确不支持，避免误报成功。
  bool get isSampleAes => method.toUpperCase().startsWith('SAMPLE-AES');
}

class M3u8ByteRange {
  const M3u8ByteRange({required this.length, this.offset});

  final int length;
  final int? offset;
}
