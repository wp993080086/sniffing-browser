import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../../core/platform/media_exporter.dart';
import '../../../core/platform/platform_info.dart';

/// 单份导出日志的应用内预览。
///
/// 之前导出只弹系统分享面板，手机上其实看不到内容 —— 分享面板负责把文件送出去，
/// 不负责打开它。这里先把内容摊在自己身上：能滚动、能选中、能复制，看完再决定
/// 要不要发出去。
///
/// 渲染用 [SelectionArea] + `ListView.builder` 逐行铺，而不是一个
/// `SelectableText` 装整篇：日志动辄几千行、几 MB，一次性排版会把主线程卡住；
/// 逐行懒加载既快，又因为外层是同一个选区，跨行仍可连续选中。
class LogViewPage extends StatefulWidget {
  const LogViewPage({super.key, required this.path, this.title});

  /// 文件绝对路径。
  final String path;

  /// 标题，通常是导出时间。留空时回退到文件名。
  final String? title;

  @override
  State<LogViewPage> createState() => _LogViewPageState();
}

/// 预览最多铺这么多行。
///
/// 上限只影响「看」，不影响分享：分享出去的是磁盘上的原文件，永远是完整的。
/// 4 MB 的日志大约两万行，再多就该用搜索而不是肉眼翻了。
const int _maxPreviewLines = 20000;

class _LogViewPageState extends State<LogViewPage> {
  String? _text;
  List<String>? _lines;
  bool _truncated = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // 进程被杀时最后一行可能只剩半个汉字，宽松解码才不至于整份读不出来。
      final String text = utf8.decode(
        await File(widget.path).readAsBytes(),
        allowMalformed: true,
      );
      final List<String> lines = text.split('\n');
      final bool truncated = lines.length > _maxPreviewLines;
      if (!mounted) return;
      setState(() {
        _text = text;
        _lines = truncated ? lines.sublist(0, _maxPreviewLines) : lines;
        _truncated = truncated;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool mobile = PlatformInfo.isMobile;
    final bool ready = _lines != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.title ?? p.basename(widget.path),
          style: const TextStyle(fontSize: 15),
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '复制全文',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: ready ? _copy : null,
          ),
          IconButton(
            tooltip: mobile ? '分享 / 保存' : '用系统程序打开',
            icon: Icon(mobile ? Icons.ios_share : Icons.open_in_new),
            onPressed: ready ? _share : null,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
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

    final List<String>? lines = _lines;
    if (lines == null) {
      return Center(
        child: Text(
          '读取中…',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      );
    }

    final Widget list = SelectionArea(
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: lines.length,
        itemBuilder: (BuildContext context, int index) {
          return Text(
            // 空行也要占高度，否则日志里的分段会被吃掉。
            lines[index].isEmpty ? ' ' : lines[index],
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              fontFamily: 'monospace',
              color: scheme.onSurface,
            ),
          );
        },
      ),
    );

    if (!_truncated) return list;

    // 提示放顶部而不是列表末尾：翻到底才知道内容不全，那已经白翻了。
    return Column(
      children: <Widget>[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          color: scheme.surfaceContainerHighest,
          child: Text(
            '内容较长，仅显示前 $_maxPreviewLines 行。复制与分享的仍是完整日志。',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(child: list),
      ],
    );
  }

  Future<void> _copy() async {
    final String? text = _text;
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('日志已复制到剪贴板')));
  }

  Future<void> _share() async {
    final bool ok = PlatformInfo.isMobile
        ? await MediaExporter.shareFile(widget.path)
        : await MediaExporter.openFile(widget.path);
    if (!mounted) return;
    if (ok) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('没有可用的应用打开，文件在 ${widget.path}')));
  }
}
