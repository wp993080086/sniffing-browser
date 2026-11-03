import 'dart:io';

/// 平台判定。
///
/// 鸿蒙上 Dart 的 [Platform.operatingSystem] 返回 `ohos`，但 `Platform.isAndroid`
/// 为 false，所以必须单独列一个分支，否则所有平台判断都会把鸿蒙落到 else 里。
enum AppPlatform { android, ohos, windows, macos, linux, other }

class PlatformInfo {
  const PlatformInfo._();

  static AppPlatform? _cached;

  static AppPlatform get current {
    final AppPlatform? cached = _cached;
    if (cached != null) return cached;

    final AppPlatform resolved;
    if (!_isDartIoAvailable) {
      resolved = AppPlatform.other;
    } else {
      final String os = Platform.operatingSystem;
      switch (os) {
        case 'android':
          resolved = AppPlatform.android;
        case 'ohos':
          resolved = AppPlatform.ohos;
        case 'windows':
          resolved = AppPlatform.windows;
        case 'macos':
          resolved = AppPlatform.macos;
        case 'linux':
          resolved = AppPlatform.linux;
        default:
          resolved = AppPlatform.other;
      }
    }
    _cached = resolved;
    return resolved;
  }

  /// 桌面端没有“相册”这个概念，导出退化成写文件夹。
  static bool get isDesktop =>
      current == AppPlatform.windows ||
      current == AppPlatform.macos ||
      current == AppPlatform.linux;

  /// Windows 走 WebView2，嗅探必须用 CDP 而不是拦截回调。
  /// 见 `cdp_sniffer.dart` 顶部注释——那边解释了为什么。
  static bool get isWindowsDesktop => current == AppPlatform.windows;

  static bool get isMobile =>
      current == AppPlatform.android || current == AppPlatform.ohos;

  static String get displayName {
    switch (current) {
      case AppPlatform.android:
        return 'Android';
      case AppPlatform.ohos:
        return 'HarmonyOS NEXT';
      case AppPlatform.windows:
        return 'Windows';
      case AppPlatform.macos:
        return 'macOS';
      case AppPlatform.linux:
        return 'Linux';
      case AppPlatform.other:
        return 'Unknown';
    }
  }

  /// 网页里判断 dart:io 是否可用（为将来支持 Web 端留的口子）。
  static bool get _isDartIoAvailable {
    try {
      Platform.operatingSystem;
      return true;
    } catch (_) {
      return false;
    }
  }
}
