import 'dart:io';

/// 全局常量。集中放这里，避免散落在各处。
class AppConstants {
  const AppConstants._();

  /// 应用展示名。当前只有中文，未做国际化。
  static const String appName = '嗅探浏览器';

  /// 展示用版本号，导出日志时写在头部。
  ///
  /// 必须和 `pubspec.yaml` 的 `version` 一致 —— 手动维护就一定会漂，
  /// 所以 `test/app_version_test.dart` 会去读 pubspec 对一遍，改漏了直接红。
  static const String version = '0.1.0+1';

  /// 启动时直接加载的网址。未设置则显示自写首页。
  ///
  /// 用环境变量指定，方便用命令行复现某个页面的问题：
  ///
  /// ```bash
  /// SNIFF_HOME_URL=https://example.com ./sniffing_browser.exe
  /// ```
  static String? get startupUrl {
    try {
      final String? override = Platform.environment['SNIFF_HOME_URL'];
      if (override != null && override.isNotEmpty) return override;
    } catch (_) {
      // 取不到环境变量就显示自写首页
    }
    return null;
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
