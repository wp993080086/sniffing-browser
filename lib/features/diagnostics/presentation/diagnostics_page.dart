import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/logging/app_log.dart';
import '../../../core/platform/media_exporter.dart';
import '../../../core/platform/platform_info.dart';
import '../data/log_exporter.dart';

/// 日志页：看日志、搜索、导出 txt。
///
/// 存在的理由很实际：嗅探“抓不到东西”或者下载静默失败时，界面上看不出是哪条
/// 通道断了。计数器能一眼判断：
/// - `cdp.responseReceived` 为 0 → CDP 没挂上
/// - `sniffer.shouldIntercept` 为 0 → 原生回调没来
/// - 两者都有但 `sniffer.captured` 为 0 → 分类器把所有东西都过滤掉了
///
/// 页面只展示内存里的最近 [AppLog.maxEntries] 条（实时）；导出才把磁盘上的历史
/// 一并带上——崩溃重开之后，内存已经空了，现场只剩在文件里。
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

/// 级别过滤。排错时最常用的是「只看警告以上」，全部 800 条没人翻得完。
enum _LevelFilter {
  all('全部级别'),
  warnUp('警告以上'),
  errorOnly('仅错误');

  const _LevelFilter(this.label);

  final String label;
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  final TextEditingController _search = TextEditingController();
  _LevelFilter _level = _LevelFilter.all;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('运行日志'),
        actions: <Widget>[
          PopupMenuButton<_LevelFilter>(
            tooltip: '按级别过滤',
            icon: Icon(
              _level == _LevelFilter.all
                  ? Icons.filter_alt_outlined
                  : Icons.filter_alt,
            ),
            onSelected: (_LevelFilter value) => setState(() => _level = value),
            itemBuilder: (BuildContext context) =>
                <PopupMenuEntry<_LevelFilter>>[
                  for (final _LevelFilter value in _LevelFilter.values)
                    PopupMenuItem<_LevelFilter>(
                      value: value,
                      child: Row(
                        children: <Widget>[
                          Expanded(child: Text(value.label)),
                          if (value == _level)
                            Icon(
                              Icons.check,
                              size: 16,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                        ],
                      ),
                    ),
                ],
          ),
          IconButton(
            tooltip: '导出为 txt',
            icon: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share),
            onPressed: _exporting ? null : _export,
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (String value) {
              if (value == 'copy') {
                _copy();
              } else {
                _clear();
              }
            },
            itemBuilder: (BuildContext context) =>
                const <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(value: 'copy', child: Text('复制当前日志')),
                  PopupMenuItem<String>(value: 'clear', child: Text('清空日志')),
                ],
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: AppLog.instance,
        builder: (BuildContext context, Widget? _) {
          final List<LogEntry> shown = _filtered();
          return Column(
            children: <Widget>[
              _SearchBar(controller: _search),
              _EnvironmentCard(shown: shown.length),
              if (shown.isEmpty)
                Expanded(
                  child: Center(
                    child: Text(
                      _search.text.trim().isEmpty && _level == _LevelFilter.all
                          ? '暂无日志'
                          : '没有匹配的日志',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              else
                Expanded(child: _LogList(entries: shown)),
            ],
          );
        },
      ),
    );
  }

  /// 过滤后按「新的在上」返回：出问题时不用滚到底部找最后一条。
  List<LogEntry> _filtered() {
    final String query = _search.text.trim().toLowerCase();
    final List<LogEntry> result = <LogEntry>[];
    for (final LogEntry entry in AppLog.instance.entries) {
      if (!_levelAccepts(entry.level)) continue;
      if (query.isNotEmpty) {
        final String haystack = '${entry.tag} ${entry.message}'.toLowerCase();
        if (!haystack.contains(query)) continue;
      }
      result.add(entry);
    }
    return result.reversed.toList();
  }

  bool _levelAccepts(LogLevel level) {
    switch (_level) {
      case _LevelFilter.all:
        return true;
      case _LevelFilter.warnUp:
        return level == LogLevel.warn || level == LogLevel.error;
      case _LevelFilter.errorOnly:
        return level == LogLevel.error;
    }
  }

  Future<void> _export() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _exporting = true);
    try {
      // 导出的是全量（含磁盘历史），不是屏幕上过滤后的子集——排查要的是现场，
      // 不是当前搜索词的命中结果。
      final String text = await AppLog.instance.exportBundle();
      final File file = await LogExporter.write(text);

      if (PlatformInfo.isMobile) {
        final bool shared = await MediaExporter.shareFile(file.path);
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              shared ? '已生成日志文件，选个应用保存或发送' : '已保存到 ${file.path}',
            ),
          ),
        );
      } else {
        // 桌面端没有分享面板，直接交给默认程序打开（txt 一般是记事本）。
        final bool opened = await MediaExporter.openFile(file.path);
        messenger.showSnackBar(
          SnackBar(
            content: Text(opened ? '已导出并打开：${file.path}' : '已导出到 ${file.path}'),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _copy() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String text = await AppLog.instance.exportBundle();
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(const SnackBar(content: Text('日志已复制到剪贴板')));
  }

  void _clear() {
    AppLog.instance.clear();
    AppLog.instance.resetCounters();
    setState(() {});
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: TextField(
        controller: controller,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: '搜索域名、文件名、错误信息',
          hintStyle: const TextStyle(fontSize: 12),
          prefixIcon: const Icon(Icons.search, size: 18),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: '清除',
                  onPressed: controller.clear,
                ),
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}

class _LogList extends StatelessWidget {
  const _LogList({required this.entries});

  final List<LogEntry> entries;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: entries.length,
      itemBuilder: (BuildContext context, int index) {
        final LogEntry entry = entries[index];
        return _LogRow(
          entry: entry,
          // 列表是倒序的，跨天的分隔要看「下一条」也就是 index+1。
          showDate:
              index == entries.length - 1 ||
              !_sameDay(entry.time, entries[index + 1].time),
        );
      },
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry, required this.showDate});

  final LogEntry entry;

  /// 与相邻一条不在同一天时，把日期写在时间前面。
  final bool showDate;

  Color _color(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    switch (entry.level) {
      case LogLevel.error:
        return scheme.error;
      case LogLevel.warn:
        return const Color(0xFFD9822B);
      case LogLevel.info:
        return scheme.onSurface;
      case LogLevel.debug:
        return scheme.onSurfaceVariant;
    }
  }

  String get _time {
    String two(int v) => v.toString().padLeft(2, '0');
    final String clock =
        '${two(entry.time.hour)}:${two(entry.time.minute)}:'
        '${two(entry.time.second)}';
    if (!showDate) return clock;
    return '${two(entry.time.month)}-${two(entry.time.day)} $clock';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 16,
            padding: const EdgeInsets.only(top: 1),
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
          SizedBox(
            width: showDate ? 92 : 62,
            child: Text(
              _time,
              style: TextStyle(
                fontSize: 11,
                height: 1.45,
                color: scheme.onSurfaceVariant,
                fontFamily: 'monospace',
              ),
            ),
          ),
          Expanded(
            child: SelectableText.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: '${entry.tag} ',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(text: entry.message),
                ],
              ),
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
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

class _EnvironmentCard extends StatefulWidget {
  const _EnvironmentCard({required this.shown});

  /// 当前过滤后可见的条数，跟总数一起显示，避免「怎么只剩几条」的疑惑。
  final int shown;

  @override
  State<_EnvironmentCard> createState() => _EnvironmentCardState();
}

class _EnvironmentCardState extends State<_EnvironmentCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Map<String, int> counters = AppLog.instance.counters;
    final List<MapEntry<String, int>> entries = counters.entries.toList()
      ..sort(
        (MapEntry<String, int> a, MapEntry<String, int> b) =>
            b.value.compareTo(a.value),
      );
    final int total = AppLog.instance.entries.length;
    final String channel = PlatformInfo.isWindowsDesktop ? 'CDP' : '原生回调';

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '${PlatformInfo.displayName} · 嗅探通道 $channel · '
                      '${widget.shown == total ? "$total 条" : "${widget.shown}/$total 条"}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                AppLog.instance.logFile?.path ?? '日志文件不可用（仅内存记录）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
              ),
              if (_expanded) ...<Widget>[
                const SizedBox(height: 8),
                if (entries.isEmpty)
                  Text(
                    '暂无计数。打开一个网页后回到这里看。',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  )
                else
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
                            color: zero ? scheme.onSurfaceVariant : null,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
