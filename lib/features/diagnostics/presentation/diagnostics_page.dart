import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/logging/app_log.dart';
import '../../../core/platform/platform_info.dart';

/// 诊断页：看日志、看通道计数器。
///
/// 存在的理由很实际：嗅探“没抓不到东西”时，从界面上看不出是哪条通道没通。
/// 有了计数器能一眼判断：
/// - `cdp.responseReceived` 为 0 → CDP 没挂上
/// - `sniffer.shouldIntercept` 为 0 → 原生回调没来
/// - 两者都有但 `sniffer.captured` 为 0 → 分类器把所有东西都过滤掉了
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  bool _onlyProblems = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('诊断'),
        actions: <Widget>[
          IconButton(
            tooltip: _onlyProblems ? '显示全部' : '只看警告和错误',
            icon: Icon(_onlyProblems ? Icons.filter_alt : Icons.filter_alt_outlined),
            onPressed: () => setState(() => _onlyProblems = !_onlyProblems),
          ),
          IconButton(
            tooltip: '复制全部',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () async {
              // 先取 messenger 再 await，避免跨异步间隙用 context。
              final ScaffoldMessengerState messenger =
                  ScaffoldMessenger.of(context);
              final String text = AppLog.instance.diagnosticsHeader() +
                  AppLog.instance.export();
              await Clipboard.setData(ClipboardData(text: text));
              messenger.showSnackBar(
                const SnackBar(content: Text('日志已复制到剪贴板')),
              );
            },
          ),
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () {
              AppLog.instance.clear();
              AppLog.instance.resetCounters();
              setState(() {});
            },
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: AppLog.instance,
        builder: (BuildContext context, Widget? _) {
          return Column(
            children: <Widget>[
              _EnvironmentCard(),
              Expanded(child: _buildLogList()),
            ],
          );
        },
      ),
    );
  }

  Widget _buildLogList() {
    final List<LogEntry> all = AppLog.instance.entries;
    final List<LogEntry> source = _onlyProblems
        ? all
            .where((LogEntry e) =>
                e.level == LogLevel.warn || e.level == LogLevel.error)
            .toList()
        : all;

    if (source.isEmpty) {
      return Center(
        child: Text(
          _onlyProblems ? '没有警告或错误' : '暂无日志',
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }

    // 最新的在最上面，出问题时不用滚到底
    final List<LogEntry> reversed = source.reversed.toList();

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: reversed.length,
      itemBuilder: (BuildContext context, int index) {
        final LogEntry entry = reversed[index];
        return _LogRow(entry: entry);
      },
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry});

  final LogEntry entry;

  Color _color(BuildContext context) {
    switch (entry.level) {
      case LogLevel.error:
        return Colors.red.shade400;
      case LogLevel.warn:
        return Colors.orange.shade700;
      case LogLevel.info:
        return Theme.of(context).textTheme.bodyMedium?.color ?? Colors.black87;
      case LogLevel.debug:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 36,
            child: Text(
              entry.level.tag,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: _color(context),
                fontFamily: 'monospace',
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              '${entry.tag}  ${entry.message}',
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: _color(context),
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EnvironmentCard extends StatelessWidget {
  const _EnvironmentCard();

  @override
  Widget build(BuildContext context) {
    final Map<String, int> counters = AppLog.instance.counters;
    final List<MapEntry<String, int>> entries = counters.entries.toList()
      ..sort((MapEntry<String, int> a, MapEntry<String, int> b) =>
          b.value.compareTo(a.value));

    final String channel = PlatformInfo.isWindowsDesktop ? 'CDP' : '原生回调';

    return Card(
      margin: const EdgeInsets.all(10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '${PlatformInfo.displayName} · 嗅探通道 $channel',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              AppLog.instance.logFile?.path ?? '日志文件不可用（仅内存记录）',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: entries.map((MapEntry<String, int> e) {
                final bool zero = e.value == 0;
                return Chip(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  label: Text(
                    '${e.key}  ${e.value}',
                    style: TextStyle(
                      fontSize: 10,
                      color: zero ? Colors.grey : null,
                    ),
                  ),
                );
              }).toList(),
            ),
            if (entries.isEmpty)
              const Text(
                '暂无计数。打开一个网页后回到这里看。',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
          ],
        ),
      ),
    );
  }
}
