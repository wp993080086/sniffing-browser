import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../data/log_exporter.dart';
import 'log_view_page.dart';

/// 导出过的日志列表。
///
/// 日志页只看内存里的最近 800 条，导出文件里才有上次启动、崩溃重启之前的完整
/// 现场。留这个入口是为了「昨天导出的那份还能翻回来」，而不是每次排错都重新
/// 导一遍 —— 重导出来的已经不是当时那份了。
class LogExportsPage extends StatefulWidget {
  const LogExportsPage({super.key});

  @override
  State<LogExportsPage> createState() => _LogExportsPageState();
}

/// 列表项：文件句柄 + 显示用标签 + 大小。
///
/// 大小在加载时一次读好：`ListTile` 的副标题是同步构建的，渲染时再 `length()`
/// 就得为每一行开一次异步 IO。
class _ExportItem {
  const _ExportItem({
    required this.file,
    required this.label,
    required this.size,
  });

  final File file;
  final String label;
  final int size;
}

class _LogExportsPageState extends State<LogExportsPage> {
  List<_ExportItem>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final List<_ExportItem> items = <_ExportItem>[];
      for (final File file in await LogExporter.list()) {
        int size = 0;
        try {
          size = await file.length();
        } catch (_) {
          // 读不到大小不影响打开，显示 0 就行。
        }
        items.add(
          _ExportItem(file: file, label: LogExporter.labelOf(file), size: size),
        );
      }
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('导出记录', style: TextStyle(fontSize: 16)),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _buildBody(context, scheme),
    );
  }

  Widget _buildBody(BuildContext context, ColorScheme scheme) {
    final String? error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '读取失败：$error',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.error),
          ),
        ),
      );
    }

    final List<_ExportItem>? items = _items;
    if (items == null) {
      return Center(
        child: Text(
          '读取中…',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      );
    }

    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            '还没有导出过日志。\n在日志页点右上角的分享图标导出一份。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      separatorBuilder: (BuildContext context, int index) =>
          const Divider(height: 1, indent: 16, endIndent: 16),
      itemBuilder: (BuildContext context, int index) {
        final _ExportItem item = items[index];
        return ListTile(
          leading: const Icon(Icons.description_outlined, size: 20),
          title: Text(item.label, style: const TextStyle(fontSize: 13)),
          subtitle: Text(
            '${p.basename(item.file.path)} · ${_humanSize(item.size)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (BuildContext context) =>
                  LogViewPage(path: item.file.path, title: item.label),
            ),
          ),
        );
      },
    );
  }

  static String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
