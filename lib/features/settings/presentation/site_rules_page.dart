import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../data/site_rule.dart';

/// 站点规则管理。
///
/// 绝大多数站点不需要配：request headers 会自动从嗅探结果里取，403 还有两套
/// 自动换头兜底。这里只给自动方案搞不定的特例用 —— 比如某个站点非要一个
/// 自定义鉴权头，或者它要求的 UA 和自动那两套都不一样。
class SiteRulesPage extends ConsumerStatefulWidget {
  const SiteRulesPage({super.key});

  @override
  ConsumerState<SiteRulesPage> createState() => _SiteRulesPageState();
}

class _SiteRulesPageState extends ConsumerState<SiteRulesPage> {
  late List<SiteRule> _rules;

  @override
  void initState() {
    super.initState();
    _rules = List<SiteRule>.from(ref.read(appSettingsProvider).siteRules);
  }

  Future<void> _save() async {
    await ref.read(appSettingsProvider).setSiteRules(_rules);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已保存，新发起的下载立即生效'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _edit(SiteRule? existing) async {
    final SiteRule? result = await Navigator.of(context).push<SiteRule>(
      MaterialPageRoute<SiteRule>(
        builder: (BuildContext context) => _EditPage(rule: existing),
      ),
    );
    if (result == null) return;
    setState(() {
      if (existing == null) {
        _rules.add(result);
      } else {
        final int index = _rules.indexOf(existing);
        if (index >= 0) _rules[index] = result;
      }
    });
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('站点规则', style: TextStyle(fontSize: 17)),
        actions: <Widget>[
          IconButton(
            tooltip: '保存',
            icon: const Icon(Icons.check),
            onPressed: _save,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(null),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text(
              '只有自动请求头搞不定的站点才需要加规则。域名写主域即可，'
              '会自动匹配它的子域；留空的项不覆盖原值。Cookie 不在规则里 —— '
              '登录态从 WebView 现取，写进文件既会过期也不安全。',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: _rules.isEmpty
                ? Center(
                    child: Text(
                      '还没有规则，绝大多数站点也不需要',
                      style: TextStyle(fontSize: 13, color: scheme.outline),
                    ),
                  )
                : ListView.separated(
                    itemCount: _rules.length,
                    separatorBuilder: (BuildContext context, int index) =>
                        const Divider(height: 1),
                    itemBuilder: (BuildContext context, int index) {
                      final SiteRule rule = _rules[index];
                      return ListTile(
                        title: Text(
                          rule.domain,
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          [
                            if (rule.userAgent.isNotEmpty) 'UA',
                            if (rule.referer.isNotEmpty) 'Referer',
                            if (rule.headers.isNotEmpty)
                              '${rule.headers.length} 个头',
                          ].join(' · '),
                          style: TextStyle(fontSize: 11, color: scheme.outline),
                        ),
                        onTap: () => _edit(rule),
                        trailing: IconButton(
                          tooltip: '删除',
                          icon: Icon(
                            Icons.delete_outline,
                            size: 18,
                            color: scheme.error,
                          ),
                          onPressed: () =>
                              setState(() => _rules.removeAt(index)),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 单条规则的编辑页。额外请求头用每行 `Key: Value` 的文本框，避免为几个头
/// 再做一套动态表单 —— 规则本来就是给懂的人兜底用的。
class _EditPage extends StatefulWidget {
  const _EditPage({this.rule});

  final SiteRule? rule;

  @override
  State<_EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<_EditPage> {
  late final TextEditingController _domain;
  late final TextEditingController _ua;
  late final TextEditingController _referer;
  late final TextEditingController _headers;

  @override
  void initState() {
    super.initState();
    final SiteRule? rule = widget.rule;
    _domain = TextEditingController(text: rule?.domain ?? '');
    _ua = TextEditingController(text: rule?.userAgent ?? '');
    _referer = TextEditingController(text: rule?.referer ?? '');
    _headers = TextEditingController(
      text: rule == null
          ? ''
          : rule.headers.entries
              .map((MapEntry<String, String> e) => '${e.key}: ${e.value}')
              .join('\n'),
    );
  }

  @override
  void dispose() {
    _domain.dispose();
    _ua.dispose();
    _referer.dispose();
    _headers.dispose();
    super.dispose();
  }

  void _done() {
    final String domain = _domain.text.trim().toLowerCase();
    if (domain.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('域名不能为空')),
      );
      return;
    }
    final Map<String, String> headers = <String, String>{};
    for (final String line in _headers.text.split('\n')) {
      final int colon = line.indexOf(':');
      if (colon <= 0) continue;
      final String key = line.substring(0, colon).trim();
      final String value = line.substring(colon + 1).trim();
      if (key.isNotEmpty && value.isNotEmpty) headers[key] = value;
    }
    Navigator.of(context).pop(
      SiteRule(
        domain: domain,
        userAgent: _ua.text.trim(),
        referer: _referer.text.trim(),
        headers: headers,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.rule == null ? '添加规则' : '编辑规则'),
        actions: <Widget>[
          TextButton(onPressed: _done, child: const Text('完成')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: <Widget>[
          TextField(
            controller: _domain,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '域名',
              hintText: 'example.com',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _ua,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'User-Agent（可选）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _referer,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Referer（可选）',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _headers,
            minLines: 3,
            maxLines: 8,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '额外请求头（可选）',
              hintText: 'X-Custom-Token: abc123',
              helperText: '每行一个，格式 Key: Value',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }
}
