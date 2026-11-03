import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/constants/app_constants.dart';

/// 浏览器状态。
///
/// 进度用独立的 [ValueNotifier]：`onProgressChanged` 一秒能触发十几次，
/// 走 notifyListeners 的话整个页面（含地址栏）都会重建。这是这类应用最典型的卡顿来源。
class BrowserController extends ChangeNotifier {
  InAppWebViewController? _web;

  String _currentUrl = AppConstants.defaultHomeUrl;
  String _title = '';
  bool _isLoading = false;
  bool _canGoBack = false;
  bool _canGoForward = false;

  /// 0~1。单独通知，只作用于进度条。
  final ValueNotifier<double> progress = ValueNotifier<double>(0);

  String get currentUrl => _currentUrl;
  String get title => _title;
  bool get isLoading => _isLoading;
  bool get canGoBack => _canGoBack;
  bool get canGoForward => _canGoForward;
  bool get isReady => _web != null;

  void attach(InAppWebViewController controller) {
    _web = controller;
  }

  /// 地址栏输入 -> 实际 URL。
  /// 带空格的当搜索词，不带协议但有域名的补 https。
  String normalizeInput(String raw) {
    final String input = raw.trim();
    if (input.isEmpty) return AppConstants.defaultHomeUrl;
    if (input.startsWith('http://') || input.startsWith('https://')) {
      return input;
    }
    if (input.contains(' ')) {
      return 'https://www.bing.com/search?q=${Uri.encodeQueryComponent(input)}';
    }
    final RegExp domainLike = RegExp(
      r'^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}(:\d+)?(/.*)?$',
    );
    if (domainLike.hasMatch(input)) {
      return 'https://$input';
    }
    return 'https://www.bing.com/search?q=${Uri.encodeQueryComponent(input)}';
  }

  Future<void> navigate(String raw) async {
    final String url = normalizeInput(raw);
    final InAppWebViewController? web = _web;
    _currentUrl = url;
    notifyListeners();
    if (web == null) return;
    await web.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  Future<void> reload() async => _web?.reload();

  Future<void> goBack() async {
    final InAppWebViewController? web = _web;
    if (web == null) return;
    if (await web.canGoBack()) {
      await web.goBack();
    }
  }

  Future<void> goForward() async {
    final InAppWebViewController? web = _web;
    if (web == null) return;
    if (await web.canGoForward()) {
      await web.goForward();
    }
  }

  void handleLoadStart(WebUri? url) {
    if (url != null) _currentUrl = url.toString();
    _isLoading = true;
    progress.value = 0;
    notifyListeners();
  }

  Future<void> handleLoadStop(WebUri? url) async {
    final InAppWebViewController? web = _web;
    if (url != null) _currentUrl = url.toString();
    _isLoading = false;
    progress.value = 1;

    if (web != null) {
      try {
        _canGoBack = await web.canGoBack();
        _canGoForward = await web.canGoForward();
        final String? pageTitle = await web.getTitle();
        if (pageTitle != null && pageTitle.isNotEmpty) _title = pageTitle;
      } catch (_) {
        // 部分平台（尤其 Windows）在页面刚就绪时这些调用可能抛异常，
        // 不影响使用，吞掉即可。
      }
    }
    notifyListeners();
  }

  void handleProgress(int value) {
    progress.value = (value / 100).clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    progress.dispose();
    super.dispose();
  }
}
