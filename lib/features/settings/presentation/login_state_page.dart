import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/platform/webview_cookies.dart';

/// 登录态管理。
///
/// 这里只做浏览器那一半的事：看 / 清 WebView Cookie。
/// 「下次是否自动登录」由网站决定是否下发长期 Cookie，浏览器无法替它做主，
/// 所以界面上把这件事讲清楚，而不是放一个点了也没用的「自动登录」开关。
class LoginStatePage extends ConsumerStatefulWidget {
  const LoginStatePage({super.key});

  @override
  ConsumerState<LoginStatePage> createState() => _LoginStatePageState();
}

class _LoginStatePageState extends ConsumerState<LoginStatePage> {
  late final TextEditingController _urlController;
  List<CookieSummary> _cookies = const <CookieSummary>[];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(
      text: ref.read(tabManagerProvider).currentUrl,
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _inspect() async {
    final String url = _urlController.text.trim();
    if (url.isEmpty) return;
    final List<CookieSummary> cookies = await WebViewCookies.forSite(url);
    if (!mounted) return;
    setState(() {
      _cookies = cookies;
      _loaded = true;
    });
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
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool supported = WebViewCookies.isSupported;

    return Scaffold(
      appBar: AppBar(title: const Text('登录态管理')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '「下次自动登录」是谁决定的？',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  '浏览器负责把网站写下的 Cookie 存好，并在每次请求时带回去；'
                  '应用重启后它们默认还在。是否下发「长期免登录凭证」由网站决定：'
                  '只发会话 Cookie 的站点，关掉页面就得重新登录，浏览器无法绕过。',
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.6,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '下载时会自动注入当前 WebView 里这个地址的 Cookie，'
                  '因此在这里清掉登录后下载会重新出现 403。',
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.6,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (!supported) ...<Widget>[
            const SizedBox(height: 12),
            _Card(
              child: Text(
                '当前平台的 WebView Cookie 由系统自行管理，'
                '这里只能查看 Android 上的登录态。',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.6,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          const _SectionTitle('按站点查看'),
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: '站点地址',
              hintText: 'https://example.com/video/123',
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: TextButton(
                onPressed: supported ? _inspect : null,
                child: const Text('查看'),
              ),
            ),
          ),
          if (_loaded) ...<Widget>[
            const SizedBox(height: 10),
            if (_cookies.isEmpty)
              Text(
                '这个地址没有可见的 Cookie（也可能还没登录过）',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              )
            else
              ..._cookies.map<Widget>(
                (CookieSummary c) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    c.isPersistent ? Icons.lock_outline : Icons.timer_outlined,
                    size: 18,
                    color: c.isPersistent ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  title: Text(c.name, style: const TextStyle(fontSize: 12)),
                  subtitle: Text(
                    '${c.domain ?? '域名未知'} · ${c.expiryLabel}'
                    '${c.isHttpOnly == true ? ' · HttpOnly' : ''}',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: supported
                  ? () async {
                      final bool ok = await _confirm(
                        title: '清除该站登录态',
                        message: '会清掉这个地址对应的 Cookie，下次访问需要重新登录。',
                      );
                      if (!ok) return;
                      final bool done =
                          await WebViewCookies.clearSite(_urlController.text.trim());
                      if (!mounted) return;
                      _toast(done ? '已清除' : '没有可清除的 Cookie');
                      await _inspect();
                    }
                  : null,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('清除该站 Cookie'),
            ),
          ],
          const SizedBox(height: 24),
          const _SectionTitle('全部站点'),
          OutlinedButton.icon(
            onPressed: supported
                ? () async {
                    final bool ok = await _confirm(
                      title: '清除全部登录态',
                      message: '所有站点的 Cookie 都会被删除，包括已经免登录的站点。',
                    );
                    if (!ok) return;
                    final bool done = await WebViewCookies.clearAll();
                    if (!mounted) return;
                    _toast(done ? '已清除全部 Cookie' : '没有可清除的 Cookie');
                    if (_loaded) await _inspect();
                  }
                : null,
            icon: const Icon(Icons.delete_forever_outlined, size: 18),
            label: const Text('清除全部 Cookie'),
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

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }
}
