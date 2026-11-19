import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/constants/app_constants.dart';

/// 地址栏与自写首页共用的搜索引擎。
enum SearchEngine {
  baidu('百度', 'https://www.baidu.com/s?wd='),
  bing('Bing', 'https://www.bing.com/search?q=');

  const SearchEngine(this.label, this.searchUrlPrefix);

  final String label;
  final String searchUrlPrefix;
}

/// 浏览器状态。
///
/// 进度用独立的 [ValueNotifier]：`onProgressChanged` 一秒能触发十几次，
/// 走 notifyListeners 的话整个页面（含地址栏）都会重建。这是这类应用最典型的卡顿来源。
class BrowserController extends ChangeNotifier {
  InAppWebViewController? _web;

  String _currentUrl = '';
  String _title = '';
  bool _isHomePage = AppConstants.startupUrl == null;
  SearchEngine _searchEngine = SearchEngine.baidu;
  bool _isLoading = false;
  bool _canGoBack = false;
  bool _canGoForward = false;

  /// 0~1。单独通知，只作用于进度条。
  final ValueNotifier<double> progress = ValueNotifier<double>(0);

  String get currentUrl => _currentUrl;
  bool get isHomePage => _isHomePage;
  SearchEngine get searchEngine => _searchEngine;
  String get title => _title;
  bool get isLoading => _isLoading;
  bool get canGoBack => _canGoBack;
  bool get canGoForward => _canGoForward;
  bool get isReady => _web != null;

  void attach(InAppWebViewController controller) {
    _web = controller;
  }

  /// 解绑原生控制器。
  ///
  /// 页签休眠（WebView 被回收）时调用：原生实例随后就会被销毁，留着引用
  /// 只会在下次误调用时抛异常。之后重新激活会走 [attach] 绑新的。
  void detach() {
    _web = null;
    _canGoBack = false;
    _canGoForward = false;
  }

  /// 从外部地址直接进入（新页签打开链接、休眠页签恢复），不经地址栏。
  void markExternal(String url) {
    if (url.isEmpty) return;
    _currentUrl = url;
    _isHomePage = false;
    notifyListeners();
  }

  void setSearchEngine(SearchEngine engine) {
    if (_searchEngine == engine) return;
    _searchEngine = engine;
    notifyListeners();
  }

  /// 地址栏输入 -> 实际 URL。返回空串表示回自写首页。
  /// 带空格的当搜索词，不带协议但有域名的补 https。
  String normalizeInput(String raw) {
    final String input = raw.trim();
    if (input.isEmpty) return '';
    if (input.startsWith('http://') || input.startsWith('https://')) {
      return input;
    }
    if (input.contains(' ')) return _searchUrl(input);
    final RegExp domainLike = RegExp(
      r'^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}(:\d+)?(/.*)?$',
    );
    if (domainLike.hasMatch(input)) {
      return 'https://$input';
    }
    return _searchUrl(input);
  }

  String _searchUrl(String input) =>
      '${_searchEngine.searchUrlPrefix}${Uri.encodeQueryComponent(input)}';

  Future<void> navigate(String raw) async {
    final String url = normalizeInput(raw);
    _currentUrl = url;
    _isHomePage = url.isEmpty;
    notifyListeners();
    if (url.isEmpty) return;
    final InAppWebViewController? web = _web;
    if (web == null) return;
    await web.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  Future<void> reload() async => _web?.reload();

  /// 加载中按「停止」。按钮图标在加载时切成叉号，行为要和图标一致。
  Future<void> stopLoading() async => _web?.stopLoading();

  Future<void> goBack() async {
    final InAppWebViewController? web = _web;
    if (web == null) return;
    if (await web.canGoBack()) {
      await web.goBack();
    }
  }

  /// 能后退就后退，返回是否真的退了。
  ///
  /// 系统返回手势要用这个判定：退不动才把控制权交还给系统去退出应用。
  /// `_canGoBack` 是加载完成时的快照，可能已经过期，这里直接问原生。
  Future<bool> goBackIfPossible() async {
    final InAppWebViewController? web = _web;
    if (web == null) return false;
    try {
      if (!await web.canGoBack()) return false;
      await web.goBack();
      return true;
    } catch (_) {
      return false;
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
