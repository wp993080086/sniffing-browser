/// 一条浏览历史。
///
/// 只存「去过哪个地址、那时页面叫什么、什么时候」——不存滚动位置、表单内容，
/// 那些东西既不值得落盘，也没法可靠还原。
class HistoryEntry {
  const HistoryEntry({
    required this.url,
    required this.title,
    required this.visitedAt,
  });

  final String url;

  /// 页面标题。可能为空（部分站点 `getTitle()` 拿不到），显示时退回域名。
  final String title;

  final DateTime visitedAt;

  String get host {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    return uri.host;
  }

  /// 列表标题。空标题不显示成空白行，退回能认出来的东西。
  String get displayTitle {
    final String trimmed = title.trim();
    if (trimmed.isNotEmpty) return trimmed;
    return host;
  }

  HistoryEntry copyWith({String? title, DateTime? visitedAt}) {
    return HistoryEntry(
      url: url,
      title: title ?? this.title,
      visitedAt: visitedAt ?? this.visitedAt,
    );
  }
}
