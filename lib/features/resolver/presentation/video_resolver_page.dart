import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/logging/app_log.dart';
import '../../../core/utils/hash_util.dart';
import '../../downloader/data/download_queue.dart';
import '../../sniffer/domain/media_item.dart';
import '../../sniffer/domain/media_type.dart';
import '../data/douyin_hook.dart';
import '../domain/resolved_batch.dart';
import '../domain/resolved_video.dart';

enum _Stage { input, loading, done, failed }

/// 短视频链接解析。
///
/// 整体是一条「用 WebView 代替人去翻页面」的路子：把用户粘的链接丢进一个
/// 真实的 WebView，注入 [DouyinHook] 读页面自己拿到的接口响应，拿到直链就把
/// WebView 拆掉，只留结果卡片和下载按钮。
///
/// WebView 是**可见**的，不藏在 Offstage 后面：抖音的详情接口有时要求登录或
/// 弹验证，用户能直接在上面操作，比对着一个「解析失败」干瞪眼强。
class VideoResolverPage extends ConsumerStatefulWidget {
  const VideoResolverPage({super.key});

  @override
  ConsumerState<VideoResolverPage> createState() => _VideoResolverPageState();
}

class _VideoResolverPageState extends ConsumerState<VideoResolverPage> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  InAppWebViewController? _web;
  Timer? _timeout;
  Timer? _shareFallback;

  _Stage _stage = _Stage.input;
  String? _targetUrl;

  /// 已经改道过的分享页地址，防止在两条路线之间来回弹。
  String? _shareTried;

  String _error = '';
  final ResolvedBatch _batch = ResolvedBatch();

  /// 首条命中后再等这么久收集同批视频，到点才切到结果页。抖音的主页接口
  /// 一次会吐十几条，命中就切的话后面的会丢。
  static const Duration _collectWindow = Duration(seconds: 2);
  Timer? _collectTimer;

  /// 整页兜底时长。抖音的接口正常几百毫秒就回来，40 秒还没动静基本是没戏了。
  static const Duration _totalTimeout = Duration(seconds: 40);

  /// 详情接口等这么久还没结果，就换分享页的 SSR 数据再试一次。
  static const Duration _shareAfter = Duration(seconds: 12);

  @override
  void initState() {
    super.initState();
    // 大部分人是从抖音复制完链接直接切过来的，进来就先看一眼剪贴板。
    WidgetsBinding.instance.addPostFrameCallback((_) => _readClipboard(silent: true));
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _shareFallback?.cancel();
    _collectTimer?.cancel();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _readClipboard({bool silent = false}) async {
    String text = '';
    try {
      final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text ?? '';
    } catch (e) {
      logWarn('Resolver', '读剪贴板失败: $e');
    }

    final String? url = DouyinHook.extractUrl(text);
    if (!mounted) return;
    if (url == null) {
      if (!silent) _toast('剪贴板里没有抖音链接');
      return;
    }
    if (_input.text.trim() == url) return;
    setState(() => _input.text = url);
  }

  void _start() {
    final String? url = DouyinHook.extractUrl(_input.text);
    if (url == null) {
      setState(() {
        _stage = _Stage.failed;
        _error = '没找到抖音链接。把分享文案整段粘进来也可以，会自动挑出其中的链接。';
      });
      return;
    }

    _focus.unfocus();
    logInfo('Resolver', '开始解析: $url');
    _batch.clear();
    setState(() {
      _stage = _Stage.loading;
      _targetUrl = url;
      _error = '';
      _shareTried = null;
    });
    _armTimers(url);
  }

  void _armTimers(String url) {
    _timeout?.cancel();
    _shareFallback?.cancel();

    _timeout = Timer(_totalTimeout, () {
      if (!mounted || _stage != _Stage.loading) return;
      _fail('等了 ${_totalTimeout.inSeconds} 秒还没拿到视频地址。'
          '可能是链接失效、视频被删，或者页面要求登录 —— 可以点「重新解析」再试。');
    });

    final String? id = DouyinHook.awemeId(url);
    if (id == null) return;

    // 详情接口要登录时，分享页的内联数据常常还能拿到。没别的路可走时才换，
    // 免得把本来正常的流程打断。
    _shareFallback = Timer(_shareAfter, () {
      if (!mounted || _stage != _Stage.loading || !_batch.isEmpty) return;
      final String share = DouyinHook.shareUrl(id);
      if (_shareTried == share) return;
      _shareTried = share;
      logInfo('Resolver', '详情接口没结果，改走分享页: $share');
      _web?.loadUrl(urlRequest: URLRequest(url: WebUri(share)));
    });
  }

  void _onHit(List<dynamic> args) {
    if (!mounted || _stage != _Stage.loading) return;
    final String raw = args.isEmpty ? '' : '${args.first}';

    Map<String, Object?>? json;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (e) {
      logWarn('Resolver', '解析回传 JSON 失败: $e');
      return;
    }
    if (json == null) return;

    final ResolvedVideo video = ResolvedVideo.fromJson(json);
    if (!video.isUsable) return;
    if (!_batch.add(video)) return;

    // 第一条命中：停掉整页超时和分享页降级（已经有结果了），开一个短窗口
    // 收集同批的其他视频。窗口到点才切 done，否则主页的十几条会丢。
    if (_collectTimer == null) {
      _timeout?.cancel();
      _shareFallback?.cancel();
      _collectTimer = Timer(_collectWindow, () {
        if (!mounted || _stage != _Stage.loading) return;
        setState(() => _stage = _Stage.done);
      });
    }
    logInfo('Resolver', '解析命中: ${video.displayName}（共 ${_batch.videos.length} 条）');
  }

  void _fail(String message) {
    _timeout?.cancel();
    _shareFallback?.cancel();
    _collectTimer?.cancel();
    _collectTimer = null;
    setState(() {
      _stage = _Stage.failed;
      _error = message;
    });
    logWarn('Resolver', message);
  }

  void _reset() {
    _timeout?.cancel();
    _shareFallback?.cancel();
    _collectTimer?.cancel();
    _collectTimer = null;
    _web = null;
    _batch.clear();
    setState(() {
      _stage = _Stage.input;
      _targetUrl = null;
      _shareTried = null;
      _error = '';
    });
  }

  void _download() {
    final List<ResolvedVideo> videos = _batch.selected;
    if (videos.isEmpty) return;

    final DownloadQueue queue = ref.read(downloadQueueProvider);
    for (final ResolvedVideo video in videos) {
      queue.enqueue(
        MediaItem(
          id: HashUtil.md5Short(video.url),
          url: video.url,
          type: MediaType.video,
          firstSeenAt: DateTime.now(),
          // 直链是抖音 CDN 的，Referer 按站点要求补上；缺了它部分节点会 403。
          pageUrl: 'https://www.douyin.com/',
          fileName: video.fileName,
          contentLength: video.sizeBytes > 0 ? video.sizeBytes : null,
          mimeType: 'video/mp4',
          requestHeaders: const <String, String>{
            'Referer': 'https://www.douyin.com/',
          },
          label: '抖音',
        ),
      );
    }

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            videos.length == 1
                ? '已加入下载队列：${videos.first.displayName}'
                : '已加入下载队列：${videos.length} 个视频',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool busy = _stage == _Stage.loading;

    return Scaffold(
      appBar: AppBar(
        title: const Text('视频解析'),
        actions: <Widget>[
          if (_stage == _Stage.done || _stage == _Stage.failed)
            TextButton(
              onPressed: _reset,
              child: const Text('重新解析', style: TextStyle(fontSize: 13)),
            ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _input,
                    focusNode: _focus,
                    minLines: 1,
                    maxLines: 3,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '粘贴抖音分享链接或整段文案',
                      hintStyle: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      suffixIcon: IconButton(
                        tooltip: '从剪贴板粘贴',
                        icon: const Icon(Icons.content_paste, size: 17),
                        onPressed: () => _readClipboard(),
                      ),
                    ),
                    onSubmitted: (_) => busy ? null : _start(),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: FilledButton(
                    onPressed: busy ? null : _start,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                    ),
                    child: const Text('解析', style: TextStyle(fontSize: 13)),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _content()),
        ],
      ),
    );
  }

  Widget _content() {
    switch (_stage) {
      case _Stage.input:
        return _idleView();
      case _Stage.loading:
        return _loadingView();
      case _Stage.done:
        return _resultView();
      case _Stage.failed:
        return _failedView();
    }
  }

  Widget _idleView() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.movie_filter_outlined, size: 40, color: scheme.primary),
            const SizedBox(height: 14),
            const Text('把抖音链接粘到上面', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 8),
            Text(
              '在抖音里点「分享 → 复制链接」，整段文案直接粘进来也行。\n'
              '解析用的是页面自己的接口响应，不需要额外的账号或 key。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _loadingView() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      children: <Widget>[
        // 状态条和 WebView 上下排，不叠放：Android 的 platform view 会盖在
        // Flutter 图层上面，Stack 里那些提示文字会被页面整个遮掉。
        Container(
          width: double.infinity,
          color: scheme.surfaceContainerHighest,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: <Widget>[
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '正在解析…页面卡住时可以手动点一下播放',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(_targetUrl!)),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              mediaPlaybackRequiresUserGesture: false,
              // 嗅探那一套全关掉：这里只要页面自己跑起来，不需要我们看每个请求。
              useShouldInterceptRequest: false,
              useOnLoadResource: false,
              useShouldOverrideUrlLoading: true,
              supportMultipleWindows: false,
              thirdPartyCookiesEnabled: true,
              transparentBackground: false,
            ),
            initialUserScripts: UnmodifiableListView<UserScript>(<UserScript>[
              UserScript(
                source: DouyinHook.script,
                // 必须是文档开始前注入：晚一步，首屏那次详情请求已经发出去了。
                injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                forMainFrameOnly: true,
              ),
            ]),
            onWebViewCreated: (InAppWebViewController controller) {
              _web = controller;
              controller.addJavaScriptHandler(
                handlerName: DouyinHook.channel,
                callback: _onHit,
              );
            },
            // 站点会往 App 里跳（snssdk1128:// 之类），拦掉，否则整页变成错误页。
            shouldOverrideUrlLoading:
                (InAppWebViewController controller, NavigationAction action) async {
                  final String scheme =
                      action.request.url?.scheme.toLowerCase() ?? '';
                  if (scheme != 'http' && scheme != 'https') {
                    logInfo('Resolver', '拦截站外跳转: ${action.request.url}');
                    return NavigationActionPolicy.CANCEL;
                  }
                  return NavigationActionPolicy.ALLOW;
                },
            onLoadStop: (InAppWebViewController controller, WebUri? url) async {
              logInfo('Resolver', '页面就绪: ${url ?? "(空)"}');
              // SSR 数据有时在 hydration 之后才挂上，加载完成再补扫一遍。
              try {
                await controller.evaluateJavascript(source: DouyinHook.rescan);
              } catch (_) {
                // 页面可能正在跳转，扫不到就算了，还有定时补扫兜着。
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _failedView() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, size: 34, color: scheme.error),
            const SizedBox(height: 12),
            Text(
              _error,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _start,
              child: const Text('重试', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultView() {
    final List<ResolvedVideo> videos = _batch.videos;
    if (videos.isEmpty) return _failedView();
    // 单条保持原来的大卡片：用户粘的就是一个视频，不该多看一层勾选。
    if (videos.length == 1) return _singleResultView(videos.first);
    return _multiResultView(videos);
  }

  Widget _singleResultView(ResolvedVideo video) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: <Widget>[
        if (video.cover.isNotEmpty)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(
              video.cover,
              height: 200,
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        const SizedBox(height: 14),
        Text(
          video.displayName,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 14,
            height: 1.45,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (video.subtitle.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            video.subtitle,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: _download,
          icon: const Icon(Icons.download, size: 18),
          label: const Text('加入下载队列', style: TextStyle(fontSize: 13)),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: _reset,
          child: const Text('换个链接', style: TextStyle(fontSize: 13)),
        ),
      ],
    );
  }

  Widget _multiResultView(List<ResolvedVideo> videos) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int selected = _batch.selected.length;
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Checkbox(
              value: _batch.isSelectedAll,
              // 全选实际上不切状态，只把勾选/取消交给每一行处理。
              onChanged: (bool? value) =>
                  setState(() => _batch.selectAll(value ?? false)),
            ),
            Text(
              '全选 · 已选 $selected / ${videos.length}',
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
        Expanded(
          child: ListView.separated(
            itemCount: videos.length,
            separatorBuilder: (BuildContext context, int index) =>
                const Divider(height: 1),
            itemBuilder: (BuildContext context, int index) {
              final ResolvedVideo video = videos[index];
              return CheckboxListTile(
                value: _batch.isSelected(video),
                onChanged: (_) => setState(() => _batch.toggle(video)),
                title: Text(
                  video.displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: video.subtitle.isEmpty
                    ? null
                    : Text(
                        video.subtitle,
                        style: TextStyle(fontSize: 11, color: scheme.outline),
                      ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          child: Column(
            children: <Widget>[
              FilledButton.icon(
                onPressed: selected > 0 ? _download : null,
                icon: const Icon(Icons.download, size: 18),
                label: Text(
                  selected > 0 ? '下载选中的 $selected 个' : '请先选择视频',
                  style: const TextStyle(fontSize: 13),
                ),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
              ),
              TextButton(
                onPressed: _reset,
                child: const Text('换个链接', style: TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
