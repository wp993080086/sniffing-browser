import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/platform/storage_paths.dart';
import '../../../core/utils/format_util.dart';
import '../data/storage_manager.dart';

/// 应用私有目录的存储管理。
///
/// 只统计和清理私有 `downloads/` / `tmp/`。已导出到相册 / 音乐 / 下载目录的
/// MediaStore 副本不归应用管，这里既不统计也不删除。
class StoragePage extends ConsumerStatefulWidget {
  const StoragePage({super.key});

  @override
  ConsumerState<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends ConsumerState<StoragePage> {
  StorageUsage? _usage;
  bool _cleaning = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final StorageUsage usage = await const StorageManager().scan(
      tasks: ref.read(downloadQueueProvider).tasks,
      jobs: ref.read(transcodeQueueProvider).jobs,
    );
    if (!mounted) return;
    setState(() => _usage = usage);
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
          persist: false,
        ),
      );
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
  }) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _clean({bool temp = false, bool orphan = false}) async {
    if (_cleaning) return;
    final bool ok = await _confirm(
      title: temp ? '清理临时分片' : '清理无主文件',
      message: temp
          ? '只清理不属于未完成 / 失败任务的临时分片，'
              '正在下载和等待续传的任务不受影响。'
          : '只删除下载目录里没有下载或转换记录引用的文件，'
              '包括已经移除记录后剩下的孤儿文件。'
              '已导出到相册 / 音乐的副本不受影响。',
      action: '确认清理',
    );
    if (!ok || !mounted) return;

    setState(() => _cleaning = true);
    final StorageCleanResult result = await const StorageManager().clean(
      tasks: ref.read(downloadQueueProvider).tasks,
      jobs: ref.read(transcodeQueueProvider).jobs,
      temp: temp,
      orphan: orphan,
    );
    if (!mounted) return;
    setState(() => _cleaning = false);
    await _refresh();
    if (!mounted) return;
    _toast(
      result.count == 0
          ? '没有需要清理的文件'
          : '已清理 ${result.count} 项，释放 ${FormatUtil.bytes(result.freed)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final StorageUsage? usage = _usage;

    return Scaffold(
      appBar: AppBar(
        title: const Text('存储管理', style: TextStyle(fontSize: 17)),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: () => unawaited(_refresh()),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          _SectionTitle('占用'),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    usage == null
                        ? '统计中…'
                        : FormatUtil.bytes(usage.totalBytes),
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '应用私有目录合计，不含已导出副本',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (usage != null) ...<Widget>[
                    _Metric(
                      label: '下载 / 转换产物',
                      value: FormatUtil.bytes(usage.productBytes),
                      note: '${usage.productCount} 个文件',
                    ),
                    _Metric(
                      label: '其中断点缓存 .part',
                      value: FormatUtil.bytes(usage.partialBytes),
                      note: '${usage.partialCount} 个文件',
                    ),
                    _Metric(
                      label: '无主文件',
                      value: FormatUtil.bytes(usage.orphanBytes),
                      note: '${usage.orphanCount} 个文件',
                    ),
                    _Metric(
                      label: '临时分片',
                      value: FormatUtil.bytes(usage.tempBytes),
                      note: '${usage.tempCount} 项，其中可清理 '
                          '${FormatUtil.bytes(usage.cleanableTempBytes)}',
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          _SectionTitle('清理'),
          if (usage != null && usage.cleanableTempBytes > 0)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                '清理期间如果有新下载开始，先暂停下载再清理更稳妥。',
                style: TextStyle(fontSize: 11, color: Colors.orange),
              ),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cleaning_services_outlined, size: 20),
            title: const Text('清理可安全清理的临时分片', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              usage == null
                  ? '统计中…'
                  : '${usage.cleanableTempCount} 项 · '
                      '${FormatUtil.bytes(usage.cleanableTempBytes)}',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: _cleaning || usage == null || usage.cleanableTempCount == 0
                ? null
                : () => unawaited(_clean(temp: true)),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.delete_sweep_outlined, size: 20),
            title: const Text('清理无主文件', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              usage == null
                  ? '统计中…'
                  : '${usage.orphanCount} 个文件 · '
                      '${FormatUtil.bytes(usage.orphanBytes)}',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: _cleaning || usage == null || usage.orphanCount == 0
                ? null
                : () => unawaited(_clean(orphan: true)),
          ),
          const SizedBox(height: 12),
          _Hint(
            '私有目录：${StoragePaths.root.path}\n'
            '系统应用信息里的「清除缓存」通常不清这里；'
            '「清除数据」或卸载会删掉全部下载、设置和登录态。',
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.note});

  final String label;
  final String value;
  final String note;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(value, style: const TextStyle(fontSize: 12)),
              Text(
                note,
                style: TextStyle(fontSize: 10, color: scheme.outline),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        height: 1.5,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}
