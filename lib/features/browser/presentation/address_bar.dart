import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../providers/browser_provider.dart';

/// 地址栏。自带返回 / 前进 / 刷新。
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
      text: ref.read(browserProvider).currentUrl,
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
    final BrowserController browser = ref.watch(browserProvider);
    final ColorScheme scheme = Theme.of(context).colorScheme;

    // 页面跳转后同步地址栏，但用户正在输入时不打断。
    ref.listen<BrowserController>(browserProvider, (
      BrowserController? previous,
      BrowserController next,
    ) {
      if (!_focusNode.hasFocus && _textController.text != next.currentUrl) {
        _textController.text = next.currentUrl;
      }
    });

    return Row(
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
                  Icons.language,
                  size: 15,
                  color: scheme.onSurfaceVariant,
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
              ),
              onSubmitted: _submit,
            ),
          ),
        ),
        _NavButton(
          icon: browser.isLoading ? Icons.close : Icons.refresh,
          tooltip: browser.isLoading ? '停止' : '刷新',
          onPressed: () => browser.reload(),
        ),
      ],
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 16),
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
    );
  }
}
