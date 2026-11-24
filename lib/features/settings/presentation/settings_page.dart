import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/platform/platform_info.dart';
import '../data/app_settings.dart';
import 'login_state_page.dart';
import 'site_rules_page.dart';
import 'storage_page.dart';

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
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.checklist_rounded, size: 20),
            title: const Text('下载完成后', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              settings.afterDownload.label,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => _pickAfterDownload(settings),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: settings.autoResume,
            onChanged: settings.setAutoResume,
            title: const Text('重启后自动续传', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              '未下完的任务在下次启动时接着下（断点续传，不重新开始）',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 20),
          _SectionTitle('存储'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.storage_outlined, size: 20),
            title: const Text('存储管理', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              '查看下载 / 转换 / 临时文件占用并清理',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => const StoragePage(),
              ),
            ),
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

  /// 选「下载完成后」的动作。桌面端不列导出：产物本来就在下载目录，
  /// 再「导出」只是原地多拷一份。
  Future<void> _pickAfterDownload(AppSettings settings) async {
    final AfterDownload current = settings.afterDownload;
    final AfterDownload? picked = await showDialog<AfterDownload>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('下载完成后', style: TextStyle(fontSize: 15)),
        children: <Widget>[
          for (final AfterDownload value in AfterDownload.values)
            if (value != AfterDownload.export || PlatformInfo.isMobile)
              // 用 ListTile + 勾选而不是 RadioListTile：后者 3.32 之后换了
              // 管理选中值的 API，这套写法在两条 Flutter 版本线上都干净。
              ListTile(
                dense: true,
                title: Text(value.label, style: const TextStyle(fontSize: 13)),
                trailing: value == current
                    ? Icon(
                        Icons.check,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () => Navigator.of(context).pop(value),
              ),
        ],
      ),
    );
    if (picked != null) await settings.setAfterDownload(picked);
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
