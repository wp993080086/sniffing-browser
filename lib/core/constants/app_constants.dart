import 'dart:io';

/// 全局常量。集中放这里，避免散落在各处。
class AppConstants {
  const AppConstants._();

  static const String appName = 'Sniffing Browser';

  /// 首次启动的首页。留空则显示引导页。
  static const String _fallbackHomeUrl = 'https://www.bing.com';

  /// 首页地址。支持用环境变量覆盖，方便用命令行复现某个页面的问题：
  ///
  /// ```bash
  /// SNIFF_HOME_URL=https://example.com ./sniffing_browser.exe
  /// ```
  static String get defaultHomeUrl {
    try {
      final String? override = Platform.environment['SNIFF_HOME_URL'];
      if (override != null && override.isNotEmpty) return override;
    } catch (_) {
      // 取不到环境变量就用默认值
    }
    return _fallbackHomeUrl;
  }

  /// 同时进行的下载任务数上限。
  static const int maxConcurrentDownloads = 3;

  /// 单个 HLS 任务内部的分片并发数。
  static const int maxConcurrentSegments = 6;

  /// 捕获列表上限，防止长时间浏览把内存吃满。
  static const int maxSniffedItems = 800;

  /// 请求头缓存上限（用于下载时补 Referer / Cookie）。
  static const int maxHeaderCacheEntries = 600;

  /// 同一 URL 在该时间窗内不重复入列表。
  static const Duration sniffDedupWindow = Duration(minutes: 20);

  /// 单个分片下载失败后的重试次数。
  static const int segmentRetryCount = 3;

  /// 连接超时。
  static const Duration connectTimeout = Duration(seconds: 20);

  /// 单次接收超时，大文件靠这个而不是整体超时。
  static const Duration receiveTimeout = Duration(seconds: 60);
}
