/// 一条收藏。
///
/// 和 [HistoryEntry] 的区别是「谁决定留」：历史是浏览的副产品，收藏是用户
/// 主动点的。所以两者各存一份，清历史不会影响收藏。
///
/// 本期不做文件夹和自定义排序，收藏列表按加入时间倒序。
class BookmarkEntry {
  const BookmarkEntry({
    required this.url,
    required this.title,
    required this.createdAt,
  });

  final String url;

  /// 加入时的页面标题。允许为空，显示时退回域名。
  final String title;

  final DateTime createdAt;

  String get host {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    return uri.host;
  }

  String get displayTitle {
    final String trimmed = title.trim();
    if (trimmed.isNotEmpty) return trimmed;
    return host;
  }
}
