import 'package:flutter/services.dart';

import '../logging/app_log.dart';
import 'platform_info.dart';

/// 下载期间的 Android 前台服务。
///
/// 下载本身跑在 Dart 侧，这里让系统把进程当「有前台任务」看待 —— 否则切后台
/// 会被冻结、socket 被回收，表现就是下载到一半报「连接被中途断开」。
///
/// 同时是通知栏的双向通道：[update] 把进度推给原生，原生通知按钮点一下会通过
/// 同一个 channel 反向调 [setActionHandler] 注册的回调。其余平台是空实现。
class DownloadForegroundService {
  const DownloadForegroundService._();

  static const MethodChannel _channel = MethodChannel(
    'sniffing_browser/download_service',
  );

  /// 是否已经挂着。队列每轮调度都会调 [start]，重复下发会让系统反复重建通知。
  static bool _running = false;
  static bool _handlerRegistered = false;

  static void Function()? _onPauseAll;
  static void Function()? _onResumeAll;
  static void Function()? _onCancelAll;

  /// 注册通知栏按钮的回调。由下载队列在构造时注入，platform 层不反向依赖队列。
  ///
  /// 只在 Android 上挂 handler：桌面/鸿蒙没有这个 channel，注册了也只会收到
  /// MissingPluginException。
  static void setActionHandler({
    required void Function() onPauseAll,
    required void Function() onResumeAll,
    required void Function() onCancelAll,
  }) {
    _onPauseAll = onPauseAll;
    _onResumeAll = onResumeAll;
    _onCancelAll = onCancelAll;
    if (_handlerRegistered || PlatformInfo.current != AppPlatform.android) {
      return;
    }
    _handlerRegistered = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      switch (call.method) {
        case 'pauseAll':
          _onPauseAll?.call();
        case 'resumeAll':
          _onResumeAll?.call();
        case 'cancelAll':
          _onCancelAll?.call();
      }
    });
  }

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

  /// 推送聚合进度到通知栏。
  ///
  /// 队列的字节进度刻意不走 notifyListeners（每 100ms 重建整个列表会掉帧），
  /// 所以通知栏只能走这条独立通道。调用方自己节流（队列里 1 秒一次）。
  /// [total] 为 0 表示未知总量，原生会画不确定进度条。
  static Future<void> update({
    required int done,
    required int total,
    required double speed,
    required int count,
  }) async {
    if (!_running || PlatformInfo.current != AppPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('update', <String, Object?>{
        'done': done,
        'total': total,
        'speed': speed,
        'count': count,
      });
    } catch (e) {
      logDebug('Download', '通知进度更新失败: $e');
    }
  }
}
