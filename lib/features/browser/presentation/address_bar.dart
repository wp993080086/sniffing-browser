import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../providers/tab_manager.dart';

/// 顶栏第一层：后退 / 前进 / 地址栏 / 刷新（加载中变停止）。
///
/// 搜索引擎和功能入口在第二层（`browser_header.dart`），
/// 这里只留导航与输入，地址栏才能拿到足够宽度。
class AddressBar extends ConsumerStatefulWidget {
  const AddressBar({super.key, required this.onSubmit});

  final ValueChanged<String> onSubmit;

  @override
  ConsumerState<AddressBar> createState() => _AddressBarState();
}

class _AddressBarState extends ConsumerState<AddressBar> {
  late final TextEditingController _textController;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(
      text: ref.read(tabManagerProvider).currentUrl,
    );
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit(String value) {
    _focusNode.unfocus();
    widget.onSubmit(value);
  }

  @override
  Widget build(BuildContext context) {
    final TabManager browser = ref.watch(tabManagerProvider);
    final bool bookmarked = ref
        .watch(bookmarkProvider)
        .contains(browser.currentUrl);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    // 页面跳转后同步地址栏，但用户正在输入时不打断。
    ref.listen<TabManager>(tabManagerProvider, (
      TabManager? previous,
      TabManager next,
    ) {
      if (!_focusNode.hasFocus && _textController.text != next.currentUrl) {
        _textController.text = next.currentUrl;
      }
    });

    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 4, 2),
      child: Row(
        children: <Widget>[
          _NavButton(
            icon: Icons.arrow_back_ios_new,
            tooltip: '后退',
            onPressed: browser.canGoBack ? () => browser.goBack() : null,
          ),
          _NavButton(
            icon: Icons.arrow_forward_ios,
            tooltip: '前进',
            onPressed: browser.canGoForward ? () => browser.goForward() : null,
          ),
          Expanded(
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(18),
              ),
              child: TextField(
                controller: _textController,
                focusNode: _focusNode,
                textInputAction: TextInputAction.go,
                keyboardType: TextInputType.url,
                autocorrect: false,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  hintText: '输入网址或搜索词',
                  hintStyle: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                  prefixIcon: Icon(
                    _secure(browser.currentUrl)
                        ? Icons.lock_outline
                        : Icons.language,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                ),
                onSubmitted: _submit,
              ),
            ),
          ),
          // 收藏入口放这里而不是第二层：第二层已经挤了引擎、页签、下载、诊断，
          // 再加一个 320 宽就要溢出；地址栏是 Expanded，吞得下这一个图标。
          _NavButton(
            icon: bookmarked ? Icons.star : Icons.star_border,
            tooltip: bookmarked ? '取消收藏' : '收藏当前页',
            color: bookmarked ? scheme.primary : null,
            onPressed: browser.currentUrl.isEmpty ? null : () => _toggleStar(),
          ),
          _NavButton(
            icon: browser.isLoading ? Icons.close : Icons.refresh,
            tooltip: browser.isLoading ? '停止' : '刷新',
            onPressed: browser.isLoading
                ? () => browser.stopLoading()
                : () => browser.reload(),
          ),
        ],
      ),
    );
  }

  /// 收藏 / 取消收藏当前页。标题取页面标题，为空时列表会退回域名。
  void _toggleStar() {
    final TabManager browser = ref.read(tabManagerProvider);
    final bool added = ref
        .read(bookmarkProvider)
        .toggle(url: browser.currentUrl, title: browser.title);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(added ? '已加入收藏' : '已取消收藏'),
          duration: const Duration(seconds: 1),
        ),
      );
  }

  /// 只在 https 上给锁图标。自写首页（空串）用地球。
  bool _secure(String url) => url.startsWith('https://');
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// 覆盖图标颜色。收藏星标要用主题色标出「已收藏」。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 17, color: color),
      tooltip: tooltip,
      // 导航按钮不抢焦点，但也不能让地址栏继续占着焦点（键盘糊在网页上）。
      onPressed: onPressed == null
          ? null
          : () {
              FocusManager.instance.primaryFocus?.unfocus();
              onPressed!();
            },
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
    );
  }
}
