import 'package:flutter/material.dart';

/// 列表为空时的占位。历史和收藏共用，免得两页各写一份还写出不同间距。
class EmptyHint extends StatelessWidget {
  const EmptyHint({
    super.key,
    required this.icon,
    required this.title,
    required this.hint,
  });

  final IconData icon;
  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 40, color: scheme.outline),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 4),
          Text(
            hint,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
