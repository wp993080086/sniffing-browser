import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../data/app_settings.dart';
import 'login_state_page.dart';
import 'site_rules_page.dart';

/// 设置页。入口在顶栏第二层的齿轮。
///
/// 目前只有两项，都是「不知道就会一直踩坑」的：分片并发（被 CDN 限流时唯一的
/// 解法）和代理（Dart 的 HttpClient 默认不读系统代理）。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController _proxyController;
  late int _concurrency;

  @override
  void initState() {
    super.initState();
    final AppSettings settings = ref.read(appSettingsProvider);
    _proxyController = TextEditingController(text: settings.proxy);
    _concurrency = settings.segmentConcurrency;
  }

  @override
  void dispose() {
    _proxyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = ref.watch(appSettingsProvider);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String envProxy = settings.envProxyRule.proxy;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          _SectionTitle('网络'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.rule_outlined, size: 20),
            title: const Text('站点规则', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              '${settings.siteRules.length} 条 · 只有自动请求头搞不定的站点才需要',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => const SiteRulesPage(),
              ),
            ),
          ),
          const SizedBox(height: 4),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.login_outlined, size: 20),
            title: const Text('登录态管理', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              '查看 / 清除网站 Cookie，登录后下载不用重复填头的那套',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => const LoginStatePage(),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _SectionTitle('下载'),
          Row(
            children: <Widget>[
              const Text('分片并发', style: TextStyle(fontSize: 14)),
              const Spacer(),
              Text(
                '$_concurrency',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          Slider(
            value: _concurrency.toDouble(),
            min: AppSettings.minSegmentConcurrency.toDouble(),
            max: AppSettings.maxSegmentConcurrency.toDouble(),
            divisions:
                AppSettings.maxSegmentConcurrency -
                AppSettings.minSegmentConcurrency,
            label: '$_concurrency',
            // 拖动过程只改本地值，松手才落盘：每跳一格写一次 JSON 没意义。
            onChanged: (double value) =>
                setState(() => _concurrency = value.round()),
            onChangeEnd: (double value) =>
                settings.setSegmentConcurrency(value.round()),
          ),
          _Hint(
            '单个 HLS 任务同时下几个分片，默认 '
            '${AppSettings.defaultSegmentConcurrency}。'
            '频繁出现「第 N 个分片失败」通常是被 CDN 限流，调到 3 或更低再试；'
            '网络很好时调高到 8~10 能略快一些。',
          ),
          const SizedBox(height: 20),
          _SectionTitle('网络'),
          TextField(
            controller: _proxyController,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'HTTP 代理',
              hintText: '127.0.0.1:7890',
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: TextButton(
                onPressed: () async {
                  await settings.setProxy(_proxyController.text);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      const SnackBar(
                        content: Text('已保存，新发起的请求立即生效'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                },
                child: const Text('保存'),
              ),
            ),
          ),
          _Hint(
            '留空表示直连。支持 http 与 socks5，例如 '
            '`socks5://127.0.0.1:1080`。'
            '${envProxy.isEmpty ? "" : "环境变量里读到 $envProxy，留空时用它。"}',
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

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          height: 1.5,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
