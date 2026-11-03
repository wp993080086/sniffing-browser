import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/logging/app_log.dart';
import '../../../core/utils/hash_util.dart';
import '../domain/media_classifier.dart';
import '../domain/media_item.dart';
import '../domain/media_type.dart';

/// 嗅探结果的持有者。
///
/// 两个回调的分工（这一点决定了整个嗅探层的结构）：
/// - `shouldInterceptRequest` 只用来**缓存请求头**，不用它做主嗅探。
///   它在请求路径上同步执行，做重活会直接拖慢页面加载。
/// - `onLoadResource` 用来**发现资源**，不阻塞渲染。
///
/// 缺了请求头，下载时几乎一定 403（尤其是 Referer 校验严格的图床和视频站）。
class SnifferService extends ChangeNotifier {
  final LinkedHashMap<String, MediaItem> _items = LinkedHashMap<String, MediaItem>();

  /// URL -> 请求头。LRU 限制容量，长时间浏览不会无限膨胀。
  final LinkedHashMap<String, Map<String, String>> _headerCache =
      LinkedHashMap<String, Map<String, String>>();

  /// 当前页面地址，用于补 Referer 和展示来源。
  String? _currentPageUrl;

  /// 通知合并。CDP 下一个首页能推来几百个事件，逐个 notifyListeners
  /// 会让资源列表按事件频率重建，直接把主 isolate 拖满。
  Timer? _notifyTimer;

  /// 列表顺序：内部按「旧 → 新」追加，对外按「新 → 旧」返回。
  /// 这样新增是 O(1)；之前的写法每次插入都要复制整个列表（O(n)）。
  List<MediaItem> get items =>
      List<MediaItem>.unmodifiable(_items.values.toList().reversed);

  String? get currentPageUrl => _currentPageUrl;

  int get count => _items.length;

  int countOf(MediaType type) =>
      _items.values.where((MediaItem item) => item.type == type).length;

  void setCurrentPage(String? url) {
    _currentPageUrl = url;
  }

  /// 记录请求头。只对“看起来像媒体”的 URL 缓存，避免把每个 JS/CSS 都存一遍。
  void cacheRequestHeaders(String url, Map<String, String> headers) {
    if (headers.isEmpty) return;
    if (MediaClassifier.isIgnorable(url)) return;
    if (MediaClassifier.classifyUrl(url) == MediaType.other) return;

    final String key = _normalize(url);

    // 已有的顺手更新，保持 LRU 顺序
    _headerCache.remove(key);
    _headerCache[key] = Map<String, String>.from(headers);

    while (_headerCache.length > AppConstants.maxHeaderCacheEntries) {
      _headerCache.remove(_headerCache.keys.first);
    }

    // 已经捕获过的资源，顺手把请求头补上。不 notify —— 列表展示不依赖请求头，
    // 为一个后台字段触发整列表重建不值得。
    final MediaItem? existing = _items[HashUtil.md5Short(key)];
    if (existing != null && existing.requestHeaders.isEmpty) {
      _items[existing.id] = existing.copyWith(requestHeaders: _headerCache[key]);
    }
  }

  Map<String, String> headersFor(String url) {
    return _headerCache[_normalize(url)] ?? const <String, String>{};
  }

  /// 发现一个资源。返回新加入的条目；被过滤或已存在则返回 null。
  MediaItem? capture({
    required String url,
    String? pageUrl,
    String? mimeType,
    Map<String, String>? headers,
  }) {
    if (MediaClassifier.isIgnorable(url)) return null;

    final MediaType type = MediaClassifier.classifyUrl(url, mimeType: mimeType);
    if (type == MediaType.other) return null;

    final String key = _normalize(url);
    final String id = HashUtil.md5Short(key);

    if (headers != null && headers.isNotEmpty) {
      cacheRequestHeaders(url, headers);
    }

    final MediaItem? existing = _items[id];
    if (existing != null) {
      // 已有条目：只补空缺字段，不重复入列表。
      final Map<String, String> mergedHeaders = existing.requestHeaders.isEmpty
          ? headersFor(url)
          : existing.requestHeaders;
      if (existing.requestHeaders.isEmpty && mergedHeaders.isNotEmpty) {
        _items[id] = existing.copyWith(requestHeaders: mergedHeaders);
      }
      return null;
    }

    final MediaItem item = MediaItem(
      id: id,
      url: url,
      type: type,
      firstSeenAt: DateTime.now(),
      pageUrl: pageUrl ?? _currentPageUrl,
      fileName: MediaClassifier.guessFileName(url, type),
      mimeType: mimeType,
      requestHeaders: headersFor(url),
    );

    // 追加到末尾（`items` 会反转成最新在前），O(1)。
    _items[id] = item;

    // 超出上限时丢掉最旧的，也就是队首。
    while (_items.length > AppConstants.maxSniffedItems) {
      _items.remove(_items.keys.first);
    }

    AppLog.instance.bump('sniffer.captured');
    _notifySoon();
    return item;
  }

  /// 合并通知：一次事件风暴只触发一次重建。
  void _notifySoon() {
    if (_notifyTimer != null) return;
    _notifyTimer = Timer(const Duration(milliseconds: 100), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    _notifyTimer = null;
    super.dispose();
  }

  void remove(String id) {
    if (_items.remove(id) != null) {
      _cancelPendingNotify();
      notifyListeners();
    }
  }

  /// 切换页面时清空。列表是按页面聚合的，不清会把上一个页面的资源带过来，
  /// 用户点下载时很容易下错东西。
  void clear() {
    if (_items.isEmpty) return;
    _items.clear();
    _cancelPendingNotify();
    notifyListeners();
  }

  void clearAll() {
    _items.clear();
    _headerCache.clear();
    _cancelPendingNotify();
    notifyListeners();
  }

  void _cancelPendingNotify() {
    _notifyTimer?.cancel();
    _notifyTimer = null;
  }

  /// 去掉 fragment；query 保留 —— 很多地址的签名参数在 query 里，去掉就 403 了。
  String _normalize(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return url;
    return uri.replace(fragment: '').toString();
  }
}
