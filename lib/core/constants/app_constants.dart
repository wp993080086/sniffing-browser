/// 全局常量。集中放这里，避免散落在各处。
class AppConstants {
  const AppConstants._();

  static const String appName = 'Sniffing Browser';

  /// 首次启动的首页。留空则显示引导页。
  static const String defaultHomeUrl = 'https://www.bing.com';

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
