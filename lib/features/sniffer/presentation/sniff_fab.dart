import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../browser/providers/tab_manager.dart';
import 'fab_position.dart';
import 'resource_panel.dart';

/// 右下角的嗅探入口。
///
/// 56dp 标准 FAB 尺寸，毛玻璃底（半透明 + 背景高斯模糊），只留图标 + 计数角标；
/// 可以拖到任意位置，位置只记在内存里（杀掉应用回默认右下角）。
///
/// 必须是 [Stack] 的直接子节点（内部用 `Positioned.fill` 铺满自己算坐标）。
class SniffFab extends ConsumerWidget {
  const SniffFab({super.key});

  /// 56 = Material FAB 标准尺寸，是「一指点中」最稳的边长。
  static const double size = 56;

  /// 拖动时离网页区域边界的最小间距，任何一侧都不许小于它。
  static const double minEdge = 16;

  /// 默认停靠：右侧 16、距底部 60（让开底部手势条与安全区）。
  static const double defaultRight = 16;
  static const double defaultBottom = 60;

  /// 圆角：56 的方块配 18 比较接近 FAB 的观感。
  static const double radius = 18;

  /// 测试用：拿到按钮本体（外层的 `Positioned.fill` 铺满整个网页区域）。
  static const Key buttonKey = ValueKey<String>('sniff_fab');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Size area = Size(constraints.maxWidth, constraints.maxHeight);
          final Offset fallback = Offset(
            area.width - size - defaultRight,
            area.height - size - defaultBottom,
          );
          final Offset current = clampOffset(
            ref.watch(sniffFabPositionProvider).offset ?? fallback,
            area,
          );

          return Stack(
            children: <Widget>[
              Positioned(
                left: current.dx,
                top: current.dy,
                child: _SniffButton(area: area, fallback: fallback),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 拖出边界时直接夹住，不留下越界坐标（否则缩回窗口会看到按钮在屏幕外）。
  static Offset clampOffset(Offset raw, Size area) {
    final double maxX = (area.width - size - minEdge).clamp(
      minEdge,
      double.infinity,
    );
    final double maxY = (area.height - size - minEdge).clamp(
      minEdge,
      double.infinity,
    );
    return Offset(raw.dx.clamp(minEdge, maxX), raw.dy.clamp(minEdge, maxY));
  }
}

class _SniffButton extends ConsumerWidget {
  const _SniffButton({required this.area, required this.fallback});

  final Size area;
  final Offset fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 角标显示「当前页签」捕获了多少，切页签会跟着变。
    // sniffer 现在是普通 Provider，新资源进来不会自动刷新，得自己订阅。
    final TabManager tabs = ref.watch(tabManagerProvider);
    return ListenableBuilder(
      listenable: tabs.activeSniffer,
      builder: (BuildContext context, Widget? child) =>
          _buildButton(context, ref, tabs.activeSniffer.count),
    );
  }

  Widget _buildButton(BuildContext context, WidgetRef ref, int count) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showResourcePanel(context),
      onPanUpdate: (DragUpdateDetails details) {
        final SniffFabPosition position = ref.read(sniffFabPositionProvider);
        final Offset base = position.offset ?? fallback;
        position.update(SniffFab.clampOffset(base + details.delta, area));
      },
      child: Tooltip(
        message: count > 0 ? '$count 个资源 · 可拖动' : '嗅探中 · 可拖动',
        child: SizedBox(
          key: SniffFab.buttonKey,
          width: SniffFab.size,
          height: SniffFab.size,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Positioned.fill(
                child: _GlassSurface(
                  child: Center(
                    child: Icon(
                      count > 0 ? Icons.radar : Icons.radar_outlined,
                      size: 26,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
              if (count > 0)
                Positioned(
                  top: 2,
                  right: 2,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 18),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    height: 18,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: scheme.surface, width: 1.5),
                    ),
                    child: Text(
                      count > 99 ? '99+' : '$count',
                      style: TextStyle(
                        fontSize: 10,
                        height: 1,
                        fontWeight: FontWeight.w600,
                        color: scheme.onPrimary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 毛玻璃底：半透明填充 + 背景高斯模糊。
///
/// 阴影画在裁剪层外面，否则会被 `ClipRRect` 一起裁掉；`ClipRRect` 同时挡住
/// `BackdropFilter` 向边缘外的模糊扩散（不挡的话四角会糊出去）。
class _GlassSurface extends StatelessWidget {
  const _GlassSurface({required this.child});

  final Widget child;

  static const double _blur = 14;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final BorderRadius radius = BorderRadius.circular(SniffFab.radius);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: const Color(0xFF000000).withValues(alpha: 0.16),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: _blur, sigmaY: _blur),
          child: DecoratedBox(
            decoration: BoxDecoration(
              // 0.3 透明：既透出下面的页面，又保住图标的对比度。
              color: scheme.surface.withValues(alpha: 0.3),
              borderRadius: radius,
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
