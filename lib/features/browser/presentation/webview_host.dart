import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/logging/app_log.dart';
import '../../../core/platform/platform_info.dart';
import '../../sniffer/data/cdp_sniffer.dart';
import '../../sniffer/data/sniffer_service.dart';
import '../providers/browser_provider.dart';

/// WebView 容器 + 嗅探回调接线。
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
  const WebViewHost({super.key});

  @override
  ConsumerState<WebViewHost> createState() => _WebViewHostState();
}

class _WebViewHostState extends ConsumerState<WebViewHost> {
  late final InAppWebViewSettings _settings;
  late final CdpSniffer _cdp;
  late final bool _useCdp;

  InAppWebViewController? _controller;

  @override
  void initState() {
    super.initState();
    _useCdp = PlatformInfo.isWindowsDesktop;
    _cdp = CdpSniffer(ref.read(snifferProvider));

    _settings = InAppWebViewSettings(
      javaScriptEnabled: true,
      // 视频站的播放器基本都要求自动播放能力，否则点了也没反应
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      // Windows 上必须关掉：这个开关会把每个请求挂起等 Dart 回话，直接卡死页面。
      // 移动端保留，因为 Android / ArkWeb 的实现是异步的，不阻塞加载。
      useShouldInterceptRequest: !_useCdp,
      useOnLoadResource: !_useCdp,
      // 鸿蒙适配版的 transparentBackground 有已知缺陷，保持 false
      transparentBackground: false,
      supportZoom: true,
      builtInZoomControls: true,
      displayZoomControls: false,
      javaScriptCanOpenWindowsAutomatically: true,
      supportMultipleWindows: false,
      thirdPartyCookiesEnabled: true,
    );

    logInfo(
      'WebView',
      '初始化，平台=${PlatformInfo.displayName}，嗅探通道=${_useCdp ? "CDP" : "原生回调"}',
    );
  }

  @override
  void dispose() {
    _cdp.dispose(_controller);
    super.dispose();
  }

  void _capture(String url) {
    if (url.isEmpty) return;
    ref.read(snifferProvider).capture(url: url);
  }

  @override
  Widget build(BuildContext context) {
    final SnifferService sniffer = ref.read(snifferProvider);
    final BrowserController browser = ref.read(browserProvider);

    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(AppConstants.defaultHomeUrl)),
      initialSettings: _settings,
      onWebViewCreated: (InAppWebViewController controller) {
        _controller = controller;
        AppLog.instance.bump('webview.created');
        logInfo('WebView', 'WebView 创建完成');
        try {
          browser.attach(controller);
        } catch (e, s) {
          logError('WebView', 'browser.attach 失败: $e\n$s');
        }
        if (_useCdp) {
          // 不 await：挂载失败不应该挡住页面加载，内部已经记了日志。
          _cdp.install(controller);
        }
      },
      onLoadStart: (InAppWebViewController controller, WebUri? url) {
        AppLog.instance.bump('webview.loadStart');
        // 换页面就清空捕获列表：跨页面的资源混在一起，用户很容易下错东西。
        sniffer.clear();
        sniffer.setCurrentPage(url?.toString());
        browser.handleLoadStart(url);
        logInfo('WebView', '开始加载: ${url ?? "(空)"}');
      },
      onLoadStop: (InAppWebViewController controller, WebUri? url) async {
        AppLog.instance.bump('webview.loadStop');
        sniffer.setCurrentPage(url?.toString());
        final int captured = sniffer.count;
        logInfo('WebView', '加载完成: ${url ?? "(空)"}，本页捕获 $captured 个资源');
        if (captured == 0) {
          // 页面能打开但抓不到东西 = 嗅探通道没通。把这条单独记成 warn，
          // 免得淹没在普通日志里。
          logWarn(
            'WebView',
            '加载完成但捕获数为 0，嗅探通道可能未生效'
            '（通道=${_useCdp ? "CDP" : "原生回调"}）',
          );
        }
        await browser.handleLoadStop(url);
      },
      onProgressChanged: (InAppWebViewController controller, int progress) {
        browser.handleProgress(progress);
        // 进度打到 10 的倍数记一次，卡住时能看出停在哪一步
        if (progress % 25 == 0) {
          AppLog.instance.bump('webview.progress.$progress');
        }
      },
      // 鸿蒙适配版的 onReceivedError 有已知空指针缺陷（对应 PR 尚未合入），
      // 那边不接这个回调，避免为了日志反而引入崩溃。
      onReceivedError: PlatformInfo.current == AppPlatform.ohos
          ? null
          : (
              InAppWebViewController controller,
              WebResourceRequest request,
              WebResourceError error,
            ) {
              AppLog.instance.bump('webview.receivedError');
              logWarn(
                'WebView',
                '资源加载失败: ${request.url} — ${error.description}',
              );
            },
      onReceivedHttpError: (
        InAppWebViewController controller,
        WebResourceRequest request,
        WebResourceResponse errorResponse,
      ) {
        AppLog.instance.bump('webview.httpError');
        logWarn(
          'WebView',
          'HTTP ${errorResponse.statusCode}: ${request.url}',
        );
      },
      onConsoleMessage: (
        InAppWebViewController controller,
        ConsoleMessage message,
      ) {
        // 只记 error 级别，否则控制台会被页面的 info 日志刷屏
        if (message.messageLevel == ConsoleMessageLevel.ERROR) {
          logWarn('Console', message.message);
        }
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
                sniffer.cacheRequestHeaders(url, headers);
              }
              _capture(url);
              // 返回 null 表示不修改请求，交还给 WebView 自己处理。
              // 返回一个响应会接管请求，页面就会白屏。
              return null;
            },
    );
  }
}
