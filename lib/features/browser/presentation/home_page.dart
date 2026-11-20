import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/constants/app_constants.dart';
import '../../resolver/presentation/video_resolver_page.dart';
import '../providers/tab_manager.dart';
import 'bookmark_page.dart';
import 'history_page.dart';

/// 自写起始页。不发网络请求，输入后由 TabManager 转给当前页签导航。
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final SearchEngine engine = ref.watch(tabManagerProvider).searchEngine;

    return ColoredBox(
      color: scheme.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.travel_explore, size: 44, color: scheme.primary),
              const SizedBox(height: 12),
              const Text(
                AppConstants.appName,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: 420,
                child: TextField(
                  textInputAction: TextInputAction.go,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '输入网址或搜索词',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                  onSubmitted: (String value) =>
                      ref.read(tabManagerProvider).navigate(value),
                ),
              ),
              const SizedBox(height: 6),
              // 常用入口贴着输入框放：输入框是这一屏的主操作，
              // 历史 / 收藏 / 解析是它的三个补充动作，不该飘到页面其它角落。
              //
              // 用 Wrap 不用 Row：三个带文字的按钮在 320dp 宽的机器上会顶出屏幕，
              // 换行总比溢出条纹好。
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 2,
                runSpacing: 2,
                children: <Widget>[
                  _HomeAction(
                    icon: Icons.history,
                    label: '历史记录',
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (BuildContext context) => const HistoryPage(),
                      ),
                    ),
                  ),
                  _HomeAction(
                    icon: Icons.star_border,
                    label: '收藏夹',
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (BuildContext context) => const BookmarkPage(),
                      ),
                    ),
                  ),
                  _HomeAction(
                    icon: Icons.movie_outlined,
                    label: '视频解析',
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (BuildContext context) =>
                            const VideoResolverPage(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '当前搜索引擎：${engine.label} · 可在上方工具栏切换',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 首页的次级入口：图标 + 文字，比 `TextButton` 默认样式矮一圈。
class _HomeAction extends StatelessWidget {
  const _HomeAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: TextButton.styleFrom(
        foregroundColor: scheme.onSurfaceVariant,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        minimumSize: const Size(0, 34),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
