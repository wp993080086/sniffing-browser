import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/logging/app_log.dart';
import '../../../core/platform/platform_info.dart';
import '../domain/media_classifier.dart';
import '../domain/media_type.dart';
import 'sniffer_service.dart';

/// Windows 端的嗅探通道：订阅 CDP 的 Network 域事件。
///
/// 为什么不能像移动端那样用 `shouldInterceptRequest`：
/// `flutter_inappwebview_windows` 注册的是
/// `AddWebResourceRequestedFilter(L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL)`，
/// 每个请求都会先 `GetDeferral()` 挂起，等 Dart 回话才放行。一个首页两三百个
/// 请求全排在 Dart 主 isolate 上，页面就会卡死。
///
/// CDP 不一样：`Network.enable` 之后事件是纯推送，**不影响请求本身**。
/// 拿到的信息也不比拦截少——`responseReceived` 给 url 和 mimeType，
/// `requestWillBeSent` 给请求头（下载时补 Referer / Cookie 要用）。
///
/// 代价：拿不到响应体。但这个项目本来就走「拿到 URL 自己重新请求」的路线，
/// 所以没有损失。
class CdpSniffer {
  CdpSniffer(this._sniffer);

  final SnifferService _sniffer;

  bool _installed = false;

  /// 同一个 requestId 只处理一次。CDP 会为重定向、缓存命中重复推送。
  final Set<String> _seenRequestIds = <String>{};

  Future<void> install(InAppWebViewController controller) async {
    if (_installed) return;
    if (!PlatformInfo.isWindowsDesktop) {
      // 其他平台走原生回调，不需要这条通道。
      return;
    }
    _installed = true;

    try {
      // 插件在 WebView 初始化时已经调过 Network.enable，这里再调一次是幂等的，
      // 目的是防止插件后续版本改动导致事件不来。
      await controller.callDevToolsProtocolMethod(methodName: 'Network.enable');
      logInfo('CdpSniffer', 'Network domain 就绪');

      await controller.addDevToolsProtocolEventListener(
        eventName: 'Network.requestWillBeSent',
        callback: _onRequestWillBeSent,
      );
      await controller.addDevToolsProtocolEventListener(
        eventName: 'Network.responseReceived',
        callback: _onResponseReceived,
      );

      AppLog.instance.bump('cdp.installed');
      logInfo('CdpSniffer', 'CDP 嗅探通道已挂载（非阻塞）');
    } catch (e, s) {
      logError('CdpSniffer', '挂载失败: $e\n$s');
      _installed = false;
    }
  }

  /// 请求发出：这里能拿到真正的请求头，下载时必须用它。
  void _onRequestWillBeSent(dynamic data) {
    AppLog.instance.bump('cdp.requestWillBeSent');
    try {
      final Map<String, dynamic>? params = _asMap(data);
      if (params == null) return;

      final Map<String, dynamic>? request = _asMap(params['request']);
      if (request == null) return;

      final String? url = request['url'] as String?;
      if (url == null || url.isEmpty) return;

      // 先做一次廉价过滤，绝大多数 JS/CSS/字体在这里就被挡掉，
      // 不用去构造 header map，省掉大量无用分配。
      if (MediaClassifier.isIgnorable(url)) return;
      if (MediaClassifier.classifyUrl(url) == MediaType.other) return;

      final Map<String, String> headers = _stringifyHeaders(request['headers']);
      if (headers.isEmpty) return;

      _sniffer.cacheRequestHeaders(url, headers);
    } catch (e) {
      logWarn('CdpSniffer', 'requestWillBeSent 解析失败: $e');
    }
  }

  /// 响应到达：这是主嗅探点，url + mimeType 都有。
  void _onResponseReceived(dynamic data) {
    AppLog.instance.bump('cdp.responseReceived');
    try {
      final Map<String, dynamic>? params = _asMap(data);
      if (params == null) return;

      final String? requestId = params['requestId'] as String?;
      if (requestId != null && !_seenRequestIds.add(requestId)) {
        return;
      }
      // 防止长会话把 set 撑爆
      if (_seenRequestIds.length > 4000) _seenRequestIds.clear();

      final Map<String, dynamic>? response = _asMap(params['response']);
      if (response == null) return;

      final String? url = response['url'] as String?;
      if (url == null || url.isEmpty) return;

      final String? mimeType = response['mimeType'] as String?;

      // 资源类型是 CDP 白送的，比猜扩展名准。
      final String? resourceType = params['type'] as String?;
      if (resourceType == 'Stylesheet' ||
          resourceType == 'Script' ||
          resourceType == 'Font') {
        return;
      }

      _sniffer.capture(url: url, mimeType: mimeType);
    } catch (e) {
      logWarn('CdpSniffer', 'responseReceived 解析失败: $e');
    }
  }

  Future<void> dispose(InAppWebViewController? controller) async {
    if (!_installed || controller == null) return;
    _installed = false;
    try {
      await controller.removeDevToolsProtocolEventListener(
        eventName: 'Network.requestWillBeSent',
      );
      await controller.removeDevToolsProtocolEventListener(
        eventName: 'Network.responseReceived',
      );
    } catch (_) {
      // 页面已经销毁时这里会失败，忽略。
    }
    _seenRequestIds.clear();
  }

  // ---- 辅助 ----

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.cast<String, dynamic>();
    return null;
  }

  /// CDP 的 headers 是 `Map<String, Object>`，值偶有非字符串，统一转。
  static Map<String, String> _stringifyHeaders(dynamic raw) {
    if (raw is! Map) return const <String, String>{};
    final Map<String, String> result = <String, String>{};
    raw.forEach((dynamic k, dynamic v) {
      if (k is String && v != null) result[k] = v.toString();
    });
    return result;
  }
}
