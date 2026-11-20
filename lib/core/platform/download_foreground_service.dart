import 'package:flutter/services.dart';

import '../logging/app_log.dart';
import 'platform_info.dart';

/// 下载期间的 Android 前台服务。
///
/// 下载本身跑在 Dart 侧，这里只让系统把进程当「有前台任务」看待 —— 否则切后台
/// 会被冻结、socket 被回收，表现就是下载到一半报「连接被中途断开」。
/// 其余平台是空实现：桌面没有这回事。
class DownloadForegroundService {
  const DownloadForegroundService._();

  static const MethodChannel _channel = MethodChannel(
    'sniffing_browser/download_service',
  );

  /// 是否已经挂着。队列每轮调度都会调 [start]，重复下发会让系统反复重建通知。
  static bool _running = false;

  static Future<void> start() async {
    if (_running || PlatformInfo.current != AppPlatform.android) return;
    _running = true;
    try {
      await _channel.invokeMethod<void>('start');
    } catch (e) {
      // 起不来不影响下载，只是切后台可能被冻结 —— 记一条就够。
      _running = false;
      logWarn('Download', '前台服务启动失败: $e');
    }
  }

  static Future<void> stop() async {
    if (!_running) return;
    _running = false;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (e) {
      logDebug('Download', '前台服务停止失败: $e');
    }
  }
}
