import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/logging/app_log.dart';
import '../../sniffer/data/sniffer_service.dart';
import 'browser_provider.dart';
import 'browser_tab.dart';

// 界面层（顶栏 / 首页）要枚举搜索引擎，但不必各自去 import 状态实现文件。
export 'browser_provider.dart' show SearchEngine;

/// 多页签的持有者，同时也是顶栏读状态的入口。
///
/// 两件事容易混，先分清：
///
/// - **页签**（[BrowserTab]）是逻辑单位，开多少个都行，只存 URL / 标题 / 嗅探结果；
/// - **存活页签**（[liveTabs]）才是真正持有原生 WebView 的那几个。
///
/// 原生 WebView 一个实例大约 50~100MB，开十个就是灾难，所以只留 [maxLive] 个。
/// 超出的按最后活跃时间淘汰，页签本身不删，切回去时用记下的地址重新加载
/// （滚动位置和播放进度会丢，这是省内存的代价）。
class TabManager extends ChangeNotifier {
  TabManager({this.maxLive = 4, this.maxTabs = 20}) {
    _create(activate: true);
  }

  /// 同时存活的 WebView 数量上限。
  final int maxLive;

  /// 逻辑页签数量上限，防止误触把内存和列表撑爆。
  final int maxTabs;

  final List<BrowserTab> _tabs = <BrowserTab>[];

  /// 持有 WebView 的页签，顺序即 `IndexedStack` 的顺序，必须稳定。
  final List<String> _live = <String>[];

  String _activeId = '';
  int _seq = 0;
  SearchEngine _searchEngine = SearchEngine.baidu;

  /// 阻止页面自己跳转（跨站的、非用户手势的顶层导航）。
  ///
  /// 视频站和资源站的 popunder 靠脚本把当前页顶成广告落地页，点一次按钮能连跳
  /// 好几个站。拦掉之后还有第二个好处：来源页不会被污染，嗅探结果的 Referer
  /// 才是对的（见 [SnifferService.setCurrentPage]）。
  ///
  /// 默认开启。站内跳转和用户点链接一律放行，所以正常浏览几乎无感；
  /// 真遇到需要脚本跳转的站点，顶栏盾牌一键关掉。
  bool _blockAutoRedirect = true;

  /// 当前活跃页签的加载进度。
  ///
  /// 每个 [BrowserController] 各自有一个 progress，这里只转发「现在这个」——
  /// 顶栏和进度条不关心后台页签在加载什么。
  final ValueNotifier<double> progress = ValueNotifier<double>(0);

  BrowserTab? _progressSource;

  List<BrowserTab> get tabs => List<BrowserTab>.unmodifiable(_tabs);

  /// 存活页签，给 `IndexedStack` 用。顺序稳定，不能按活跃时间重排，
  /// 否则切换时子节点的 key 会对调，WebView 全部重建。
  List<BrowserTab> get liveTabs {
    final List<BrowserTab> result = <BrowserTab>[];
    for (final String id in _live) {
      final BrowserTab? tab = _byId(id);
      if (tab != null) result.add(tab);
    }
    return result;
  }

  /// 当前页签。所有页签都被关掉的瞬间会落到列表首个，不会返回 null。
  BrowserTab get activeTab => _byId(_activeId) ?? _tabs.first;

  String get activeId => activeTab.id;
  int get tabCount => _tabs.length;
  SearchEngine get searchEngine => _searchEngine;
  bool get blockAutoRedirect => _blockAutoRedirect;

  /// 当前页签的嗅探结果。资源面板、FAB 角标、下载配对都读它。
  SnifferService get activeSniffer => activeTab.sniffer;

  String get currentUrl => activeTab.page.currentUrl;
  String get title => activeTab.page.title;
  bool get isLoading => activeTab.page.isLoading;
  bool get canGoBack => activeTab.page.canGoBack;
  bool get canGoForward => activeTab.page.canGoForward;
  bool get isHomePage => activeTab.page.isHomePage;

  BrowserTab? _byId(String id) {
    for (final BrowserTab tab in _tabs) {
      if (tab.id == id) return tab;
    }
    return null;
  }

  /// 新建页签。返回 null 表示已达上限，调用方自行降级。
  BrowserTab? createTab({String? url, bool activate = true}) {
    if (_tabs.length >= maxTabs) {
      logWarn('Tabs', '页签数已达上限 $maxTabs，忽略新建');
      return null;
    }
    return _create(url: url, activate: activate);
  }

  BrowserTab _create({String? url, bool activate = true}) {
    final BrowserTab tab = BrowserTab(
      id: 'tab_${++_seq}',
      url: url ?? AppConstants.startupUrl,
    );
    _tabs.add(tab);
    if (activate || _activeId.isEmpty) {
      activateTab(tab.id);
    }
    return tab;
  }

  void activateTab(String id) {
    final BrowserTab? tab = _byId(id);
    if (tab == null) return;
    tab.lastActive = DateTime.now();
    // 已经在前台就只刷新活跃时间，不触发重建（否则点当前页签会白重建一次）。
    if (id == _activeId && _live.contains(id)) return;

    _activeId = id;
    _ensureLive(tab);
    _bindProgress(tab);
    notifyListeners();
  }

  void closeTab(String id) {
    final BrowserTab? tab = _byId(id);
    if (tab == null) return;

    final bool wasActive = id == activeTab.id;
    final int index = _tabs.indexOf(tab);
    _tabs.removeAt(index);
    _live.remove(id);

    if (_tabs.isEmpty) {
      _create(activate: true);
      return;
    }

    if (wasActive) {
      // 关掉当前页签后落到相邻的那个：优先右边，没有就退回左边。
      final BrowserTab next =
          _tabs[index >= _tabs.length ? _tabs.length - 1 : index];
      activateTab(next.id);
    } else {
      notifyListeners();
    }
  }

  Future<void> navigate(String raw) => activeTab.page.navigate(raw);

  Future<void> reload() => activeTab.page.reload();

  Future<void> stopLoading() => activeTab.page.stopLoading();

  Future<void> goBack() => activeTab.page.goBack();

  Future<void> goForward() => activeTab.page.goForward();

  /// 系统返回手势：网页能后退就后退，退不动返回 false 交给系统退出。
  Future<bool> handleBack() => activeTab.page.goBackIfPossible();

  /// 在新页签打开一个地址（`target=_blank` / `window.open` 转过来的）。
  Future<void> openInNewTab(String url) async {
    if (url.isEmpty) return;
    final BrowserTab? tab = createTab(url: url);
    if (tab == null) {
      // 页签开满了就降级在当前页打开，至少别让用户点了没反应。
      await activeTab.page.navigate(url);
      return;
    }
    logInfo('Tabs', '新页签打开: $url');
  }

  void setSearchEngine(SearchEngine engine) {
    if (_searchEngine == engine) return;
    _searchEngine = engine;
    // 引擎是全局设置，但 normalizeInput 在各自的状态对象里，要一起同步。
    for (final BrowserTab tab in _tabs) {
      tab.page.setSearchEngine(engine);
    }
    notifyListeners();
  }

  void setBlockAutoRedirect(bool value) {
    if (_blockAutoRedirect == value) return;
    _blockAutoRedirect = value;
    logInfo('Tabs', value ? '已开启拦截自动跳转' : '已关闭拦截自动跳转');
    notifyListeners();
  }

  void attach(String tabId, InAppWebViewController web) {
    _byId(tabId)?.page.attach(web);
  }

  /// WebView 被销毁时解绑。休眠页签会先走一遍 [_sleep]，这里再调是安全的。
  void detachWeb(String tabId) {
    _byId(tabId)?.page.detach();
  }

  void handleLoadStart(String tabId, WebUri? url) {
    final BrowserTab? tab = _byId(tabId);
    if (tab == null) return;
    tab.page.handleLoadStart(url);
    if (tabId == activeTab.id) notifyListeners();
  }

  Future<void> handleLoadStop(String tabId, WebUri? url) async {
    final BrowserTab? tab = _byId(tabId);
    if (tab == null) return;
    await tab.page.handleLoadStop(url);
    if (tabId == activeTab.id) notifyListeners();
  }

  void handleProgress(String tabId, int value) {
    // 只更新该页签自己的 progress；转发到顶栏由 _bindProgress 负责。
    _byId(tabId)?.page.handleProgress(value);
  }

  /// 保证该页签有 WebView，超出上限时淘汰最久没被看过的那个。
  void _ensureLive(BrowserTab tab) {
    if (!_live.contains(tab.id)) _live.add(tab.id);
    while (_live.length > maxLive) {
      final List<String> others = _live
          .where((String id) => id != tab.id)
          .toList();
      if (others.isEmpty) break;
      others.sort((String a, String b) {
        final DateTime ta = _byId(a)?.lastActive ?? DateTime(0);
        final DateTime tb = _byId(b)?.lastActive ?? DateTime(0);
        return ta.compareTo(tb);
      });
      _sleep(others.first);
    }
  }

  void _sleep(String id) {
    final BrowserTab? tab = _byId(id);
    _live.remove(id);
    if (tab == null) return;
    // 记下现场：原生 WebView 马上被销毁，重新激活时用这个地址重建。
    final String url = tab.page.currentUrl;
    tab.pendingUrl = url.isEmpty ? null : url;
    tab.page.detach();
    logInfo('Tabs', '回收页签 ${tab.id} 的 WebView（${tab.displayTitle}）');
  }

  void _bindProgress(BrowserTab tab) {
    _progressSource?.page.progress.removeListener(_forwardProgress);
    _progressSource = tab;
    tab.page.progress.addListener(_forwardProgress);
    progress.value = tab.page.progress.value;
  }

  void _forwardProgress() {
    progress.value = _progressSource?.page.progress.value ?? 0;
  }

  @override
  void dispose() {
    _progressSource?.page.progress.removeListener(_forwardProgress);
    _progressSource = null;
    for (final BrowserTab tab in _tabs) {
      tab.page.dispose();
      tab.sniffer.dispose();
    }
    _tabs.clear();
    _live.clear();
    progress.dispose();
    super.dispose();
  }
}
