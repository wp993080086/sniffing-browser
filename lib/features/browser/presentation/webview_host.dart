import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/logging/app_log.dart';
import '../../../core/platform/platform_info.dart';
import '../../sniffer/data/cdp_sniffer.dart';
import '../data/history_service.dart';
import '../data/nav_guard.dart';
import '../../sniffer/data/sniffer_service.dart';
import '../providers/browser_tab.dart';
import '../providers/tab_manager.dart';

/// 排查用的开关：用环境变量关掉某条通道或回调，定位崩溃来源。
///
/// 这个是临时诊断手段，正常启动不受影响（不设环境变量就是全开）。
/// 定位完可以删掉，或者留着当回归工具。
bool _debugOff(String name) {
  try {
    final String? value = Platform.environment[name];
    return value == '1' || value == 'true';
  } catch (_) {
    return false;
  }
}

/// 一个页签的 WebView 容器 + 嗅探回调接线。
///
/// 每个存活页签各有一个实例，靠 `IndexedStack` 同时挂在树上 —— 切换页签
/// 只是换显示的那一个，不重建，所以滚动位置和播放进度都还在。
///
/// 三端的嗅探通道**不一样**，这里按平台分支，不能写成一套：
///
/// | 平台 | 通道 | 是否阻塞页面 |
/// | --- | --- | --- |
/// | Android | `shouldInterceptRequest` 采请求头 + `onLoadResource` 发现资源 | 否 |
/// | HarmonyOS | 同上（ArkWeb 的 `onInterceptRequest`） | 否 |
/// | Windows | **只用 CDP**（`Network.responseReceived` / `requestWillBeSent`） | 否 |
///
/// Windows 为什么不能用 `shouldInterceptRequest`：插件注册的是
/// `AddWebResourceRequestedFilter("*", ALL)`，每个请求都要 `GetDeferral()`
/// 挂起等 Dart 回话。首页几百个请求串行排在主 isolate 上，页面直接卡死。
/// 而且 Windows 原生侧根本没有 `onLoadResource`（只有
/// `onLoadResourceWithCustomScheme`），那条所谓“兜底通道”是不存在的。
///
/// 详细论证见 `cdp_sniffer.dart` 顶部注释。
class WebViewHost extends ConsumerStatefulWidget {
  const WebViewHost({super.key, required this.tab, this.active = true});

  final BrowserTab tab;

  /// 这个页签是否在前台。
  ///
  /// 非前台时把 WebView 挂起（Android `WebView.onPause`、Windows `TrySuspend`）
  /// 并暂停页面里的音视频。`IndexedStack` 只是不绘制：后台页签的 JS 定时器、
  /// 视频解码、广告轮播照样在跑，四个存活页签就是四份开销叠加。
  final bool active;

  @override
  ConsumerState<WebViewHost> createState() => _WebViewHostState();
}

class _WebViewHostState extends ConsumerState<WebViewHost> {
  late final InAppWebViewSettings _settings;
  late final CdpSniffer _cdp;
  late final bool _useCdp;
  late final TabManager _tabs;

  InAppWebViewController? _controller;

  /// 页面 console 错误的去重记录。
  ///
  /// 掘金这类站点会在一帧内打印几十条一模一样的错误（`parseImageXUrl ...`），
  /// 全量记下来会把真正有用的诊断日志冲没。按内容去重 + 总量封顶。
  final Set<int> _loggedConsole = <int>{};
  static const int _maxConsoleLogs = 40;

  /// 当前这次顶层导航是否可信（用户点链接 / 地址栏输入 / 站内跳转）。
  ///
  /// 只在 [shouldOverrideUrlLoading] 里判定，`onLoadStart` / `onLoadStop`
  /// 拿它决定要不要把地址记成资源来源页。
  bool _navTrusted = true;

  /// 已隔离过的站。同一广告站 30 秒内只开一个后台页签。
  final Map<String, DateTime> _isolatedHosts = <String, DateTime>{};

  final NavGuard _guard = NavGuard();

  BrowserTab get _tab => widget.tab;
  SnifferService get _sniffer => widget.tab.sniffer;

  @override
  void initState() {
    super.initState();
    _tabs = ref.read(tabManagerProvider);
    _useCdp = PlatformInfo.isWindowsDesktop && !_debugOff('SNIFF_DISABLE_CDP');
    _cdp = CdpSniffer(_sniffer);

    _settings = InAppWebViewSettings(
      javaScriptEnabled: true,
      // 视频站的播放器基本都要求自动播放能力，否则点了也没反应
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      // Windows 上必须关掉：这个开关会把每个请求挂起等 Dart 回话，直接卡死页面。
      // 移动端保留，因为 Android / ArkWeb 的实现是异步的，不阻塞加载。
      useShouldInterceptRequest: !_useCdp,
      useOnLoadResource: !_useCdp,
      // 移动端拦掉 bilibili:// / intent:// 这类唤起 App 的跳转，否则整页会跳到
      // ERR_UNKNOWN_URL_SCHEME 错误页。Windows 不启用：插件开启后会改走另一条
      // 路径触发 onLoadStart，而 CDP 嗅探依赖那条路径的时序，不动已验过的桌面链路。
      useShouldOverrideUrlLoading: !_useCdp,
      // 鸿蒙适配版的 transparentBackground 有已知缺陷，保持 false
      transparentBackground: false,
      supportZoom: true,
      builtInZoomControls: true,
      displayZoomControls: false,
      javaScriptCanOpenWindowsAutomatically: true,
      // 多页签由我们自己接管（注入脚本拦 target=_blank / window.open），
      // 不需要原生的多窗口机制 —— 那套需要把 windowId 绑定到新的 WebView，
      // 而新 WebView 是异步建出来的，时序很难对齐。
      supportMultipleWindows: false,
      thirdPartyCookiesEnabled: true,
    );

    logInfo(
      'WebView',
      '初始化 ${_tab.id}，平台=${PlatformInfo.displayName}，'
          '嗅探通道=${_useCdp ? "CDP" : "原生回调"}',
    );
  }

  @override
  void dispose() {
    _cdp.dispose(_controller);
    // 原生控制器随后就被销毁，状态对象上不能再留着引用。
    _tabs.detachWeb(_tab.id);
    super.dispose();
  }

  /// 顶层导航的放行判断。
  ///
  /// 判定规则都在 [NavGuard] 里，这里只负责三件杂事：
  ///
  /// - 非网页协议（`intent://`、`bilibili://`、`weixin://`）一律取消，
  ///   否则会落到 ERR_UNKNOWN_URL_SCHEME 错误页；
  /// - 服务器重定向沿用本次导航的可信度 —— 302 到哪儿是站点自己的决定；
  /// - 把页面刚上报的点击喂给判定，让「脚本中转的点击」不被当成弹窗。
  ///
  /// 拦截的第二个作用是保住来源页。当前页一旦被顶成广告落地页，之后嗅探到的
  /// m3u8 会带着广告站的 Referer 去下载，服务端校验必然 403。
  Future<NavigationActionPolicy> _handleNavigation(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final String url = action.request.url?.toString() ?? '';
    final String scheme = Uri.tryParse(url)?.scheme.toLowerCase() ?? '';
    if (scheme != 'http' && scheme != 'https') {
      logWarn('WebView', '拦截非网页协议跳转: $url');
      return NavigationActionPolicy.CANCEL;
    }

    // 服务器重定向沿用本次导航的可信度：302 到哪儿是站点自己的决定。
    if (action.isRedirect == true) return NavigationActionPolicy.ALLOW;

    // 后台页签的 WebView 是挂起状态，求值可能一直不返回。导航判定必须
    // 在几百毫秒内给出结论，否则插件那边会等不到回话，这次导航就卡住了。
    final (String, int)? tap = await _readPageTap(
      controller,
    ).timeout(const Duration(milliseconds: 300), onTimeout: () => null);
    if (tap != null) _guard.noteTap(href: tap.$1, atMs: tap.$2);

    final NavVerdict verdict = _guard.decide(
      url: url,
      currentUrl: _tab.page.currentUrl,
      hasUserGesture: action.hasGesture == true,
      enabled: _tabs.blockAutoRedirect,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );

    _navTrusted = verdict == NavVerdict.allow;
    if (verdict == NavVerdict.isolate) {
      _isolate(url);
      return NavigationActionPolicy.CANCEL;
    }
    return NavigationActionPolicy.ALLOW;
  }

  /// 读页面最近一次点击：`href`（可能是空串）与发生时间。
  ///
  /// `window.__sbLastTap` 由 [_pagePatch] 写入，格式 `href \t 毫秒时间戳`。
  /// 取不到（脚本还没注入、进程刚起来）就返回 null，交给判定按保守方式处理。
  Future<(String, int)?> _readPageTap(InAppWebViewController controller) async {
    try {
      final Object? raw = await controller.evaluateJavascript(
        source: 'window.__sbLastTap || ""',
      );
      String text = '$raw';
      if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
        text = text.substring(1, text.length - 1);
      }
      final int sep = text.lastIndexOf('\t');
      if (sep < 0) return null;
      final int? at = int.tryParse(text.substring(sep + 1));
      if (at == null) return null;
      return (text.substring(0, sep), at);
    } catch (e) {
      logDebug('WebView', '读取页面点击失败: $e');
      return null;
    }
  }

  /// 把可疑跳转隔离到后台页签，当前页一行不动。
  ///
  /// 隔离页里自己还会继续跳（广告落地页就是这么干的），那边不再派生，
  /// 否则点一次能裂变出十几个页签；同一个广告站 30 秒内也只留一个。
  void _isolate(String url) {
    if (_tab.spawnedInBackground) {
      logInfo('WebView', '隔离页内忽略后续跳转: $url');
      return;
    }

    final String host = Uri.tryParse(url)?.host ?? url;
    final DateTime now = DateTime.now();
    final DateTime? last = _isolatedHosts[host];
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _isolatedHosts[host] = now;

    final BrowserTab? tab = _tabs.openInBackground(url);
    logWarn('WebView', '已把跳转隔离到后台页签: $url');
    if (tab == null) return;
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          // Flutter 3.44 的 `SnackBar.persist` 默认值就是 `action != null`：
          // 带按钮的提示**永远不会自己消失**，只能点一下。这里显式关掉。
          persist: false,
          duration: const Duration(seconds: 4),
          content: Row(
            children: <Widget>[
              Expanded(child: Text('已在后台页签打开：$host')),
              // 内置关闭键固定 24px，且不支持放大，自己放一个更大的。
              IconButton(
                icon: const Icon(Icons.close),
                iconSize: 28,
                // M3 的 SnackBar 是深色底，IconButton 默认取 onSurface 会看不见。
                color: Theme.of(context).colorScheme.onInverseSurface,
                tooltip: '关闭提示',
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                onPressed: () => messenger.hideCurrentSnackBar(),
              ),
            ],
          ),
          action: SnackBarAction(
            label: '查看',
            onPressed: () => _tabs.activateTab(tab.id),
          ),
        ),
      );
  }

  void _capture(String url) {
    if (url.isEmpty) return;
    _sniffer.capture(url: url);
  }

  /// 自动播放兜底脚本。
  ///
  /// Chromium 的自动播放策略规定：**带声音**的音视频必须由用户手势触发。
  /// 内嵌 WebView 里没有这个手势上下文，站点写了 `autoplay` 也可能只是停住，
  /// 而同一个页面在系统浏览器里能播（顶层页面有用户激活 / 媒体参与度打分）。
  ///
  /// 但「把页面上所有 autoplay 视频都拉起来」在视频列表页是灾难：一屏十张卡片
  /// 就是十路同时解码，CPU 和内存立刻见底。所以这里加了三道限制：
  ///
  /// - 页面里**已经有视频在播**就不插手（用户自己点了，或者站点已经启动了）；
  /// - 只处理**视口内**、且宽高都不小于 40px 的（排除 1×1 的统计 / 探针 video）；
  /// - **一次只启动一个**。
  ///
  /// 剩下的交给 `_mediaGovernor`：谁开始播，就把其它全暂停。
  static const String _autoplayNudge = r'''
(function () {
  try {
    var vh = window.innerHeight || 0;
    var all = document.querySelectorAll('video');
    for (var j = 0; j < all.length; j++) {
      if (!all[j].paused) return 0;
    }

    var videos = document.querySelectorAll('video[autoplay]');
    for (var i = 0; i < videos.length; i++) {
      var v = videos[i];
      if (!v.paused) continue;
      var r = v.getBoundingClientRect();
      if (r.width < 40 || r.height < 40) continue;
      if (r.bottom <= 0 || r.top >= vh) continue;
      if (!v.muted) v.muted = true;
      var p = v.play();
      if (p && p.catch) p.catch(function () {});
      return 1;
    }
    return 0;
  } catch (e) { return -1; }
})();
''';

  /// 页面内媒体治理：播放互斥 + 后台暂停。
  ///
  /// 两件事：
  ///
  /// 1. **播放互斥**。站点自己的列表页常常让每个卡片都自动预览，声音叠在一起
  ///    之外，每个 `<video>` 都是一个独立解码器。这里监听 `play`（capture 阶段，
  ///    比站点自己的监听更早），谁开始播就把其它全部暂停。
  /// 2. **整页暂停**。暴露 `__sbMediaGovernor.pauseAll()`，切页签时由 Dart 调用。
  ///
  /// 注入失败只影响省电，不影响页面本身，所以整段包在 try 里。
  static const String _mediaGovernor = r'''
(function () {
  if (window.__sbMediaGovernor) return 'skip';

  function mediaNodes() {
    return document.querySelectorAll('video, audio');
  }

  document.addEventListener('play', function (e) {
    var target = e.target;
    if (!target) return;
    var tag = target.tagName;
    if (tag !== 'VIDEO' && tag !== 'AUDIO') return;
    var all = mediaNodes();
    for (var i = 0; i < all.length; i++) {
      var m = all[i];
      if (m === target || m.paused) continue;
      try { m.pause(); } catch (err) {}
    }
  }, true);

  window.__sbMediaGovernor = {
    pauseAll: function () {
      var all = mediaNodes();
      var paused = 0;
      for (var i = 0; i < all.length; i++) {
        if (all[i].paused) continue;
        try { all[i].pause(); paused++; } catch (err) {}
      }
      return paused;
    }
  };

  return 'ok';
})();
''';

  /// 页面侧补丁，一个页面只注入一次。
  ///
  /// 三件事：
  ///
  /// 1. 把「新窗口打开」改写为「新页签打开」。`supportMultipleWindows: false`
  ///    时，站点的 `target=_blank` 和 `window.open` 会被 WebView 直接在当前页
  ///    打开 —— 用户点一个链接，当前页就被顶掉了。这里在 DOM 层接管：
  ///    `a[target=_blank]` 的点击（capture 阶段，比站点自己的代理更早）、
  ///    `window.open(url)`、桌面习惯的 Ctrl / Cmd + 点击。不改
  ///    `window.location` 的跳转 —— 那是页面内导航，本来就该留在当前页签。
  /// 2. **记录真实点击**（`window.__sbLastTap` = `href \t 时间戳`）。原生
  ///    `shouldOverrideUrlLoading` 拿不到可靠手势，导航判定要回来问页面。
  /// 3. 点击时通知 Dart 收起地址栏键盘 —— 网页是 platform view，那里的
  ///    点击 Flutter 收不到，只能让页面自己喊一声。
  static const String _pagePatch = r'''
(function () {
  if (window.__sbTabPatch) return 'skip';
  window.__sbTabPatch = true;

  function openInTab(url) {
    try {
      window.flutter_inappwebview.callHandler('sb_open_tab', String(url));
    } catch (e) {}
  }

  var rawOpen = window.open;
  window.open = function (url) {
    if (typeof url === 'string') {
      var u = url.trim().toLowerCase();
      if (u.indexOf('http://') === 0 || u.indexOf('https://') === 0) {
        openInTab(url);
        return null;
      }
    }
    return rawOpen ? rawOpen.apply(window, arguments) : null;
  };

  document.addEventListener('click', function (e) {
    var href = '';
    var anchor = e.target;
    while (anchor && anchor.tagName !== 'A') anchor = anchor.parentElement;
    if (anchor) {
      var lower = (anchor.href || '').toLowerCase();
      if (lower.indexOf('http://') === 0 || lower.indexOf('https://') === 0) {
        href = anchor.href;
      }
    }
    window.__sbLastTap = href + '\t' + Date.now();
    try {
      window.flutter_inappwebview.callHandler('sb_user_tap');
    } catch (err) {}
  }, true);

  document.addEventListener('click', function (e) {
    var node = e.target;
    while (node && node.tagName !== 'A') node = node.parentElement;
    if (!node) return;
    var href = node.href || '';
    var u = href.toLowerCase();
    if (u.indexOf('http://') !== 0 && u.indexOf('https://') !== 0) return;
    var blank = (node.getAttribute('target') || '').toLowerCase() === '_blank';
    if (!blank && !e.ctrlKey && !e.metaKey) return;
    e.preventDefault();
    openInTab(href);
  }, true);

  return 'ok';
})();
''';

  /// 记一条浏览历史。
  ///
  /// 只有真正加载完成的网页才记：`onLoadStart` 里记会把失败页、被拦的重定向
  /// 也写进去。标题要在 `handleLoadStop` 之后取，那时 `getTitle()` 才回来。
  void _recordHistory(WebUri? url) {
    final String pageUrl = url?.toString() ?? '';
    if (!HistoryService.isWebUrl(pageUrl)) return;
    ref.read(historyProvider).record(url: pageUrl, title: _tab.page.title);
  }

  /// 触发一次自动播放兜底。失败只记日志，不影响页面。
  ///
  /// 非前台页签不调用：后台页面自己播起来是最没有理由的耗电。
  Future<void> _nudgeAutoplay(InAppWebViewController controller) async {
    if (!widget.active) return;
    try {
      final Object? result = await controller.evaluateJavascript(
        source: _autoplayNudge,
      );
      final int kicked = result is int ? result : int.tryParse('$result') ?? 0;
      if (kicked > 0) {
        logInfo('WebView', '自动播放兜底：已启动 $kicked 个 video[autoplay]');
      }
    } catch (e) {
      logWarn('WebView', '自动播放兜底脚本执行失败: $e');
    }
  }

  /// 注入媒体治理脚本（播放互斥 + 暂停入口）。页面换掉后 window 是新的，要重注。
  Future<void> _installMediaGovernor(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(source: _mediaGovernor);
    } catch (e) {
      logWarn('WebView', '媒体治理脚本执行失败: $e');
    }
  }

  /// 暂停页面里正在播放的所有音视频。切走页签时调用。
  Future<void> _pauseMedia(InAppWebViewController controller) async {
    try {
      final Object? paused = await controller.evaluateJavascript(
        source:
            'window.__sbMediaGovernor ? '
            'window.__sbMediaGovernor.pauseAll() : 0',
      );
      final int count = paused is int ? paused : int.tryParse('$paused') ?? 0;
      if (count > 0) {
        logInfo('WebView', '切走页签，已暂停 $count 个媒体（${_tab.id}）');
      }
    } catch (e) {
      logDebug('WebView', '暂停媒体失败（${_tab.id}）: $e');
    }
  }

  /// 前台 / 后台切换时挂起或恢复 WebView。
  ///
  /// `pause()` 在 Android 上对应 `WebView.onPause()`，Windows 上对应
  /// `ICoreWebView2.TrySuspend`——前者停掉绘制与动画，后者还会把渲染进程挂起，
  /// 后台页签不再吃 CPU。两者都**不**停 JS 定时器，所以媒体要单独用脚本暂停。
  ///
  /// 切回前台**不自动续播**：等同于系统浏览器切后台的行为，用户自己点播放。
  void _applyActive(bool active) {
    final InAppWebViewController? controller = _controller;
    if (controller == null) return;
    if (active) {
      unawaited(controller.resume());
      return;
    }
    unawaited(_pauseMedia(controller));
    unawaited(controller.pause());
    logInfo('WebView', '页签转入后台，挂起 WebView（${_tab.id}）');
  }

  @override
  void didUpdateWidget(covariant WebViewHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      _applyActive(widget.active);
    }
  }

  /// 每次加载完成后补一次页面补丁（页面换掉后 window 是新的）。
  Future<void> _installPagePatch(InAppWebViewController controller) async {
    try {
      final Object? result = await controller.evaluateJavascript(
        source: _pagePatch,
      );
      if ('$result' == 'ok') {
        logInfo('WebView', '已接管新窗口打开与页面点击上报（${_tab.id}）');
      }
    } catch (e) {
      logWarn('WebView', '页面补丁执行失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? initialUrl = _tab.pendingUrl;
    // 诊断开关：错误类回调在 Windows 上是否接线
    final bool errorCallbacks = !_debugOff('SNIFF_DISABLE_ERROR_CB');
    // 鸿蒙适配版的 onReceivedError 有已知空指针缺陷（对应 PR 尚未合入），
    // 那边不接这个回调，避免为了日志反而引入崩溃。
    final bool useErrorCallback =
        errorCallbacks && PlatformInfo.current != AppPlatform.ohos;

    return InAppWebView(
      initialUrlRequest: initialUrl == null
          ? null
          : URLRequest(url: WebUri(initialUrl)),
      initialSettings: _settings,
      onWebViewCreated: (InAppWebViewController controller) {
        _controller = controller;
        // initialUrlRequest 只在创建时生效，用掉就清掉，
        // 免得休眠页签恢复时又加载一次同样的地址。
        _tab.pendingUrl = null;
        AppLog.instance.bump('webview.created');
        logInfo('WebView', 'WebView 创建完成（${_tab.id}）');
        _tabs.attach(_tab.id, controller);
        try {
          controller.addJavaScriptHandler(
            handlerName: 'sb_open_tab',
            callback: (List<dynamic> args) {
              final String url = args.isEmpty ? '' : '${args.first}';
              if (url.isNotEmpty) {
                unawaited(_tabs.openInNewTab(url));
              }
              return null;
            },
          );
        } catch (e) {
          logWarn('WebView', '注册新页签通道失败: $e');
        }
        try {
          controller.addJavaScriptHandler(
            handlerName: 'sb_user_tap',
            // 网页是 platform view，那里的点击 Flutter 拿不到，
            // 地址栏的焦点（以及键盘）只能靠页面喊一声才收得起来。
            callback: (List<dynamic> args) {
              FocusManager.instance.primaryFocus?.unfocus();
              return null;
            },
          );
        } catch (e) {
          logWarn('WebView', '注册点击通道失败: $e');
        }
        if (_useCdp) {
          // 不 await：挂载失败不应该挡住页面加载，内部已经记了日志。
          _cdp.install(controller);
        }
        // 新页签默认在前台，这条只在「恢复的页签不是当前页」时才走到。
        if (!widget.active) _applyActive(false);
      },
      // 只放行 http/https，其余协议（bilibili:// / intent:// / weixin:// 等）
      // 是站点用来唤起原生 App 的，WebView 解析不了。取消后当前页面保持不变。
      // 必须显式返回 ALLOW：插件把 Dart 侧的 null 解码成 CANCEL，返回 null 会拦掉所有导航。
      shouldOverrideUrlLoading: _useCdp ? null : _handleNavigation,
      onLoadStart: (InAppWebViewController controller, WebUri? url) {
        AppLog.instance.bump('webview.loadStart');
        // 换页面就清空本页签的捕获列表：跨页面的资源混在一起，用户很容易下错东西。
        // 只清自己这一份，别的页签不受影响。
        _sniffer.clear();
        _sniffer.setCurrentPage(url?.toString(), trusted: _navTrusted);
        _tabs.handleLoadStart(_tab.id, url);
        logInfo('WebView', '开始加载（${_tab.id}）: ${url ?? "(空)"}');
      },
      onLoadStop: (InAppWebViewController controller, WebUri? url) async {
        AppLog.instance.bump('webview.loadStop');
        _sniffer.setCurrentPage(url?.toString(), trusted: _navTrusted);
        final int captured = _sniffer.count;
        logInfo(
          'WebView',
          '加载完成（${_tab.id}）: ${url ?? "(空)"}，本页捕获 $captured 个资源',
        );
        if (captured == 0) {
          // 页面能打开但抓不到东西 = 嗅探通道没通。把这条单独记成 warn，
          // 免得淹没在普通日志里。
          logWarn(
            'WebView',
            '加载完成但捕获数为 0，嗅探通道可能未生效'
                '（通道=${_useCdp ? "CDP" : "原生回调"}）',
          );
        }
        await _tabs.handleLoadStop(_tab.id, url);
        _recordHistory(url);
        unawaited(_installPagePatch(controller));
        unawaited(_installMediaGovernor(controller));
        if (widget.active) {
          // 首屏视频的 src 常常是 hydration 之后才挂上去的，等一会儿再兜一次。
          unawaited(_nudgeAutoplay(controller));
          Timer(const Duration(milliseconds: 1500), () {
            if (!mounted) return;
            unawaited(_nudgeAutoplay(controller));
          });
        } else {
          // 后台页签加载完成时，页面的 autoplay 可能已经自己起来了。
          unawaited(_pauseMedia(controller));
        }
      },
      onProgressChanged: (InAppWebViewController controller, int progress) {
        _tabs.handleProgress(_tab.id, progress);
        // 每 25% 记一个计数，卡住时能看出停在哪一段
        if (progress % 25 == 0) {
          AppLog.instance.bump('webview.progress.$progress');
        }
      },
      onReceivedError: useErrorCallback
          ? (
              InAppWebViewController controller,
              WebResourceRequest request,
              WebResourceError error,
            ) {
              AppLog.instance.bump('webview.receivedError');
              logWarn(
                'WebView',
                '资源加载失败: ${request.url} — ${error.description}',
              );
            }
          : null,
      onReceivedHttpError: errorCallbacks
          ? (
              InAppWebViewController controller,
              WebResourceRequest request,
              WebResourceResponse errorResponse,
            ) {
              AppLog.instance.bump('webview.httpError');
              logWarn(
                'WebView',
                'HTTP ${errorResponse.statusCode}: ${request.url}',
              );
            }
          : null,
      onConsoleMessage: errorCallbacks
          ? (InAppWebViewController controller, ConsoleMessage message) {
              // 只记 error 级别，且按内容去重 + 封顶。
              if (message.messageLevel != ConsoleMessageLevel.ERROR) return;
              if (_loggedConsole.length >= _maxConsoleLogs) return;
              if (_loggedConsole.add(message.message.hashCode)) {
                logWarn('Console', message.message);
              }
            }
          : null,
      // 权限请求必须接管，不能留给插件默认实现。
      //
      // flutter_inappwebview_windows 0.6.0 的 PermissionRequestCallback 解码
      // 函数（webview_channel_delegate.cpp:57）漏了 null 检查：
      //
      //   return std::make_shared<PermissionResponse>(std::get<EncodableMap>(*value));
      //
      // Dart 侧不提供这个回调时，插件收到的是 null，`*value` 就是空指针，
      // `variant::index()` 读偏移 0x40 直接访问违规，整个进程闪退。
      // 任何申请通知 / 定位 / 摄像头权限的网站都会踩到（bing 不申请所以没事，
      // 掘金会申请）。
      //
      // 所以这里永远返回一个有效对象。做嗅探下载器用不到这些权限，一律拒绝。
      onPermissionRequest:
          (InAppWebViewController controller, PermissionRequest request) async {
            AppLog.instance.bump('webview.permissionRequest');
            logInfo(
              'WebView',
              '拒绝权限请求: ${request.resources} 来源=${request.origin}',
            );
            return PermissionResponse(
              resources: request.resources,
              action: PermissionResponseAction.DENY,
            );
          },
      // Windows 上这两个回调不接线：原生侧不触发，接了也是死代码。
      onLoadResource: _useCdp
          ? null
          : (InAppWebViewController controller, LoadedResource resource) {
              final String? url = resource.url?.toString();
              if (url != null) {
                AppLog.instance.bump('sniffer.onLoadResource');
                _capture(url);
              }
            },
      shouldInterceptRequest: _useCdp
          ? null
          : (
              InAppWebViewController controller,
              WebResourceRequest request,
            ) async {
              AppLog.instance.bump('sniffer.shouldIntercept');
              final String url = request.url.toString();
              final Map<String, String>? headers = request.headers;
              if (headers != null && headers.isNotEmpty) {
                _sniffer.cacheRequestHeaders(url, headers);
              }
              _capture(url);
              // 返回 null 表示不修改请求，交还给 WebView 自己处理。
              // 返回一个响应会接管请求，页面就会白屏。
              return null;
            },
    );
  }
}
