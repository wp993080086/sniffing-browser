import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../providers/browser_tab.dart';
import '../providers/tab_manager.dart';

/// 打开页签切换器。
///
/// 用底部 Modal 而不是自定义浮层：返回手势关掉它由 Navigator 自己处理，
/// 不用和浏览器的 PopScope 抢优先级。
Future<void> showTabSwitcher(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (BuildContext context) => const FractionallySizedBox(
      heightFactor: 0.86,
      child: _TabSwitcherSheet(),
    ),
  );
}

class _TabSwitcherSheet extends ConsumerWidget {
  const _TabSwitcherSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TabManager tabs = ref.watch(tabManagerProvider);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 10, 6),
          child: Row(
            children: <Widget>[
              const Text(
                '页签',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Text(
                '${tabs.tabCount}',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _createTab(context, ref),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新建', style: TextStyle(fontSize: 13)),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.primary,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _TabMasonry(tabs: tabs.tabs, activeId: tabs.activeId),
          ),
        ),
      ],
    );
  }

  void _createTab(BuildContext context, WidgetRef ref) {
    final BrowserTab? tab = ref.read(tabManagerProvider).createTab();
    if (tab == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('页签已达上限（${ref.read(tabManagerProvider).maxTabs} 个）'),
            duration: const Duration(seconds: 2),
          ),
        );
      return;
    }
    Navigator.of(context).pop();
  }
}

/// 两栏卡片瀑布流。
///
/// 不是等宽网格：标题一行、两行的卡片高度不同，逐个放进「当前较矮的那一列」，
/// 两列底部才不会出现一条大缝。页签数量上限 20，纯 Column 堆叠够用，
/// 也不需要为这一屏引入瀑布流依赖。
class _TabMasonry extends StatelessWidget {
  const _TabMasonry({required this.tabs, required this.activeId});

  final List<BrowserTab> tabs;
  final String activeId;

  static const double _gap = 10;

  @override
  Widget build(BuildContext context) {
    if (tabs.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double columnWidth = (constraints.maxWidth - _gap) / 2;
        final List<BrowserTab> left = <BrowserTab>[];
        final List<BrowserTab> right = <BrowserTab>[];
        double leftHeight = 0;
        double rightHeight = 0;

        for (final BrowserTab tab in tabs) {
          final double height = cardHeight(tab, columnWidth);
          if (leftHeight <= rightHeight) {
            left.add(tab);
            leftHeight += height + _gap;
          } else {
            right.add(tab);
            rightHeight += height + _gap;
          }
        }

        return SingleChildScrollView(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: _column(left, columnWidth)),
              const SizedBox(width: _gap),
              Expanded(child: _column(right, columnWidth)),
            ],
          ),
        );
      },
    );
  }

  Widget _column(List<BrowserTab> items, double width) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final BrowserTab tab in items) ...<Widget>[
          _TabCard(
            tab: tab,
            height: cardHeight(tab, width),
            active: tab.id == activeId,
          ),
          const SizedBox(height: _gap),
        ],
      ],
    );
  }

  static const TextStyle _titleStyle = TextStyle(
    fontSize: 13,
    height: 1.35,
    fontWeight: FontWeight.w500,
  );

  /// 按标题实际折行数算卡片高度，两列分配才能对齐。
  static double cardHeight(BrowserTab tab, double width) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: tab.displayTitle, style: _titleStyle),
      maxLines: 2,
      textDirection: TextDirection.ltr,
      ellipsis: '…',
    )..layout(maxWidth: (width - 40).clamp(40, double.infinity));
    final int lines = painter.computeLineMetrics().length.clamp(1, 2);
    painter.dispose();
    return 56 + lines * 18;
  }
}

/// 没有 title 时退回一句占位，不要拿域名再显示一遍 —— 上面那行已经写了。
String _title(BrowserTab tab) {
  final String title = tab.page.title.trim();
  if (title.isNotEmpty) return title;
  return tab.displayHost.isEmpty ? '新页签' : '未命名页面';
}

class _TabCard extends ConsumerWidget {
  const _TabCard({
    required this.tab,
    required this.height,
    required this.active,
  });

  final BrowserTab tab;
  final double height;
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: () {
        ref.read(tabManagerProvider).activateTab(tab.id);
        Navigator.of(context).pop();
      },
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: active
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
          border: active
              ? Border.all(color: scheme.primary, width: 1.5)
              : Border.all(color: Colors.transparent, width: 1.5),
        ),
        child: Stack(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 9, 30, 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    tab.displayHost.isEmpty ? '起始页' : tab.displayHost,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.4,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Flexible(
                    child: Text(
                      _title(tab),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.35,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              top: -4,
              right: -4,
              child: IconButton(
                tooltip: '关闭页签',
                iconSize: 15,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                icon: Icon(Icons.close, color: scheme.onSurfaceVariant),
                onPressed: () => ref.read(tabManagerProvider).closeTab(tab.id),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
