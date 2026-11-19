import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../sniffer/presentation/sniff_fab.dart';
import '../providers/browser_tab.dart';
import '../providers/tab_manager.dart';
import 'browser_header.dart';
import 'home_page.dart';
import 'webview_host.dart';

class BrowserPage extends ConsumerWidget {
  const BrowserPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TabManager tabs = ref.watch(tabManagerProvider);
    final List<BrowserTab> live = tabs.liveTabs;
    final int index = live.indexWhere(
      (BrowserTab tab) => tab.id == tabs.activeId,
    );
    final BrowserTab active = tabs.activeTab;

    // 系统返回手势原来直接退应用：WebView 明明还有历史，页面却被整个关掉。
    // 这里先问网页能不能后退，退不动才把控制权交还系统。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) return;
        final bool handled = await ref.read(tabManagerProvider).handleBack();
        if (handled || !context.mounted) return;
        await SystemNavigator.pop();
      },
      child: Scaffold(
        // 顶栏自绘（两层），不用 AppBar：一层的 52px 放不下导航 + 输入 + 功能入口。
        body: Column(
          children: <Widget>[
            BrowserHeader(
              onNavigate: (String value) =>
                  ref.read(tabManagerProvider).navigate(value),
            ),
            // 所有存活页签同时挂在树上，切换只是换显示的那个：
            // WebView 不重建，滚动位置、播放进度、表单内容都留着。
            //
            // 嗅探按钮也放在这一层：它只能盖住网页区域，拖不到顶栏上去。
            Expanded(
              child: Stack(
                children: <Widget>[
                  IndexedStack(
                    index: index < 0 ? 0 : index,
                    children: <Widget>[
                      for (final BrowserTab tab in live)
                        WebViewHost(
                          key: ValueKey<String>(tab.id),
                          tab: tab,
                          // IndexedStack 只是不绘制：不告诉 WebView 自己已经
                          // 在后台，它照样渲染、照样播视频、照样跑轮播。
                          active: tab.id == tabs.activeId,
                        ),
                    ],
                  ),
                  if (active.page.isHomePage)
                    const Positioned.fill(child: HomePage()),
                  const SniffFab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
