import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/constants/app_constants.dart';
import '../../sniffer/data/sniffer_service.dart';
import '../providers/browser_provider.dart';

/// WebView 容器 + 嗅探回调接线。
///
/// 两个回调的分工（不要合并成一个）：
/// - `shouldInterceptRequest`：同步返回，不能在里面做重活。只用它拿 URL 和请求头，
///   顺带做一次轻量分类（Windows 上 onLoadResource 不一定触发，这里是唯一兜底）。
/// - `onLoadResource`：主嗅探通道，不阻塞资源加载。
///
/// 两条通道都会 capture，靠 id 去重，重复不会入两次列表。
class WebViewHost extends ConsumerStatefulWidget {
  const WebViewHost({super.key});

  @override
  ConsumerState<WebViewHost> createState() => _WebViewHostState();
}

class _WebViewHostState extends ConsumerState<WebViewHost> {
  late final InAppWebViewSettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = InAppWebViewSettings(
      javaScriptEnabled: true,
      // 视频站的播放器基本都要求自动播放能力，否则点了也没反应
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      // 嗅探开关：这两个不开，回调根本不会来
      useShouldInterceptRequest: true,
      useOnLoadResource: true,
      // 鸿蒙适配版的 transparentBackground 有已知缺陷，保持 false
      transparentBackground: false,
      supportZoom: true,
      builtInZoomControls: true,
      displayZoomControls: false,
      javaScriptCanOpenWindowsAutomatically: true,
      supportMultipleWindows: false,
      thirdPartyCookiesEnabled: true,
    );
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
        browser.attach(controller);
      },
      onLoadStart: (InAppWebViewController controller, WebUri? url) {
        // 换页面就清空捕获列表：跨页面的资源混在一起，用户很容易下错东西。
        sniffer.clear();
        sniffer.setCurrentPage(url?.toString());
        browser.handleLoadStart(url);
      },
      onLoadStop: (InAppWebViewController controller, WebUri? url) async {
        sniffer.setCurrentPage(url?.toString());
        await browser.handleLoadStop(url);
      },
      onProgressChanged: (InAppWebViewController controller, int progress) {
        browser.handleProgress(progress);
      },
      onLoadResource: (
        InAppWebViewController controller,
        LoadedResource resource,
      ) {
        final String? url = resource.url?.toString();
        if (url != null) _capture(url);
      },
      shouldInterceptRequest: (
        InAppWebViewController controller,
        WebResourceRequest request,
      ) async {
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
