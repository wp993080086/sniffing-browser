import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../diagnostics/presentation/diagnostics_page.dart';
import '../../downloader/presentation/download_page.dart';
import '../providers/tab_manager.dart';
import 'address_bar.dart';
import 'tab_switcher.dart';

/// 顶栏，两层。
///
/// 第一层是导航与输入（后退 / 前进 / 地址栏 / 刷新），第二层是「能干什么」
/// （搜索引擎、资源嗅探、下载、诊断）。分开的理由很实际：以前全塞在 52px 的
/// AppBar 里，地址栏只剩一半宽度，功能按钮还得跟标题抢位置。
class BrowserHeader extends ConsumerWidget {
  const BrowserHeader({super.key, required this.onNavigate});

  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TabManager browser = ref.watch(tabManagerProvider);
    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    // 顶栏不再是 AppBar，状态栏图标的明暗要自己声明，否则深色主题下看不见。
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
          .copyWith(statusBarColor: Colors.transparent),
      child: Material(
        color: scheme.surface,
        child: SafeArea(
          bottom: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AddressBar(onSubmit: onNavigate),
              const _ToolbarRow(),
              ValueListenableBuilder<double>(
                valueListenable: browser.progress,
                builder: (BuildContext context, double value, Widget? child) {
                  // 留着 2px 占位，加载开始/结束不会让网页整体跳一下。
                  if (value >= 1 || value <= 0) {
                    return const SizedBox(height: 2);
                  }
                  return LinearProgressIndicator(value: value, minHeight: 2);
                },
              ),
              Container(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolbarRow extends StatelessWidget {
  const _ToolbarRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(8, 0, 6, 4),
      child: Row(
        children: <Widget>[
          _EngineButton(),
          Spacer(),
          _RedirectGuardButton(),
          _TabsButton(),
          _DownloadButton(),
          _DiagnosticsButton(),
        ],
      ),
    );
  }
}

/// 搜索引擎切换。放在第二层最左：它影响的是「输入会被当成什么」，属于功能而非导航。
class _EngineButton extends ConsumerWidget {
  const _EngineButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SearchEngine engine = ref.watch(tabManagerProvider).searchEngine;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return PopupMenuButton<SearchEngine>(
      tooltip: '切换搜索引擎',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      onSelected: (SearchEngine value) =>
          ref.read(tabManagerProvider).setSearchEngine(value),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<SearchEngine>>[
        for (final SearchEngine item in SearchEngine.values)
          PopupMenuItem<SearchEngine>(
            value: item,
            child: Text(item.label, style: const TextStyle(fontSize: 13)),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.fromLTRB(9, 5, 5, 5),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.manage_search, size: 15, color: scheme.onSurfaceVariant),
            const SizedBox(width: 5),
            Text(
              engine.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: scheme.onSurfaceVariant,
              ),
            ),
            Icon(
              Icons.arrow_drop_down,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// 拦截自动跳转的开关。
///
/// 开着的时候，脚本发起的跨站顶层跳转会被取消（用户点链接、站内跳转照常）。
/// 这是视频站 popunder 唯一的根治手段：不拦的话点一次播放能连跳几个广告站，
/// 而且当前页被顶掉之后，嗅探到的 m3u8 会带错误的 Referer，下载必然 403。
class _RedirectGuardButton extends ConsumerWidget {
  const _RedirectGuardButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TabManager tabs = ref.watch(tabManagerProvider);
    final bool on = tabs.blockAutoRedirect;
    return _BarButton(
      icon: on ? Icons.shield : Icons.shield_outlined,
      tooltip: on ? '已拦截页面自动跳转（点击关闭）' : '未拦截自动跳转（点击开启）',
      highlighted: on,
      onTap: () => tabs.setBlockAutoRedirect(!on),
    );
  }
}

/// 页签入口。显示的是页签总数，点击打开两栏瀑布流选择器。
class _TabsButton extends ConsumerWidget {
  const _TabsButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int count = ref.watch(tabManagerProvider).tabCount;
    return _BarButton(
      icon: Icons.filter_none,
      label: '$count',
      tooltip: '页签（$count 个）',
      onTap: () => showTabSwitcher(context),
    );
  }
}

class _DownloadButton extends ConsumerWidget {
  const _DownloadButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int active = ref.watch(downloadQueueProvider).activeCount;
    return _BarButton(
      icon: Icons.download_outlined,
      label: '下载',
      count: active,
      highlighted: active > 0,
      tooltip: active > 0 ? '下载队列（$active 个进行中）' : '下载队列',
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => const DownloadPage(),
        ),
      ),
    );
  }
}

class _DiagnosticsButton extends StatelessWidget {
  const _DiagnosticsButton();

  @override
  Widget build(BuildContext context) {
    return _BarButton(
      icon: Icons.bug_report_outlined,
      tooltip: '诊断日志',
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => const DiagnosticsPage(),
        ),
      ),
    );
  }
}

/// 第二层统一的按钮样式：图标 + 可选文字 + 可选计数胶囊。
///
/// 用自绘而不是 IconButton：IconButton 的最小点按区 48px，一排四个会把
/// 第二层撑得比第一层还高，看起来比原来更乱。
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.label,
    this.count,
    this.highlighted = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final String? label;
  final int? count;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color foreground = highlighted
        ? scheme.primary
        : scheme.onSurfaceVariant;
    final int? badge = count;
    final String? text = label;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 17, color: foreground),
              if (text != null) ...<Widget>[
                const SizedBox(width: 5),
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: foreground,
                  ),
                ),
              ],
              if (badge != null && badge > 0) ...<Widget>[
                const SizedBox(width: 5),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  constraints: const BoxConstraints(minWidth: 16),
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    badge > 99 ? '99+' : '$badge',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onPrimary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
