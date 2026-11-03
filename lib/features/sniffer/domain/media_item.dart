import 'media_type.dart';

/// 一条捕获到的媒体资源。
///
/// 不可变对象 —— 列表用 Riverpod 管理，改成可变的话 diff 很难做，
/// 而且 UI 层会出现“数据变了但没重建”的诡异问题。
class MediaItem {
  const MediaItem({
    required this.id,
    required this.url,
    required this.type,
    required this.firstSeenAt,
    this.pageUrl,
    this.fileName,
    this.contentLength,
    this.mimeType,
    this.requestHeaders = const <String, String>{},
    this.label,
  });

  /// URL 的摘要，用作稳定标识。
  final String id;
  final String url;
  final MediaType type;
  final DateTime firstSeenAt;

  /// 发现该资源的页面地址，用作 Referer。
  final String? pageUrl;
  final String? fileName;
  final int? contentLength;
  final String? mimeType;

  /// 捕获到时同步缓存的请求头（Referer / Cookie / User-Agent）。
  /// 缺了这几个，下载时大概率 403。
  final Map<String, String> requestHeaders;

  /// 附加信息，比如 HLS 的分辨率/码率描述。
  final String? label;

  String get displayName => fileName ?? url;

  MediaItem copyWith({
    String? fileName,
    int? contentLength,
    String? mimeType,
    Map<String, String>? requestHeaders,
    String? label,
  }) {
    return MediaItem(
      id: id,
      url: url,
      type: type,
      firstSeenAt: firstSeenAt,
      pageUrl: pageUrl,
      fileName: fileName ?? this.fileName,
      contentLength: contentLength ?? this.contentLength,
      mimeType: mimeType ?? this.mimeType,
      requestHeaders: requestHeaders ?? this.requestHeaders,
      label: label ?? this.label,
    );
  }
}
