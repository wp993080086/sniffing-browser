import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_log.dart';
import '../../../core/utils/format_util.dart';
import '../domain/media_item.dart';
import '../domain/media_type.dart';
import 'download_action.dart';

/// 嗅探结果的预览页。
///
/// 目的只有一个：**在下之前确认是不是要的那个东西**。列表里几十条
/// `videoplayback`、`index.m3u8`，名字完全看不出内容，点开看一眼比下完再删便宜
/// 得多。
///
/// 分三种处理：
/// - 图片：直接放大图，可缩放（`Image.network` 支持带 Referer / Cookie 请求头）
/// - 音视频：用 WebView 打开该地址，交给系统内置播放器；地址带着嗅探时缓存
///   的请求头，否则 CDN 一律 403
/// - HLS / DASH：不预览。流是几百个分片，WebView 也播不了不加密的 m3u8，
///   与其转圈不如把元信息和「下载后自动合并」讲清楚
class MediaPreviewPage extends ConsumerWidget {
  const MediaPreviewPage({super.key, required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          item.fileName ?? item.type.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15),
        ),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.download_rounded, size: 20),
            tooltip: '下载',
            // 流媒体在下之前先让人选清晰度 / 音轨；普通文件直接入队。
            onPressed: () => downloadWithChoice(context, ref, item),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: switch (item.type) {
              MediaType.image => _ImageView(item: item),
              MediaType.video || MediaType.audio => _PlayerView(item: item),
              MediaType.hls ||
              MediaType.dash ||
              MediaType.other => _StreamInfo(item: item),
            },
          ),
          _MetaBar(item: item),
        ],
      ),
    );
  }
}

/// 大图预览。取不到图时直接说明原因，不留空白。
class _ImageView extends StatelessWidget {
  const _ImageView({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return InteractiveViewer(
      minScale: 1,
      maxScale: 4,
      child: Center(
        child: Image.network(
          item.url,
          // 少了 Referer / Cookie，CDN 上的图一律 403，预览等于没做。
          headers: item.requestHeaders,
          fit: BoxFit.contain,
          errorBuilder:
              (BuildContext context, Object error, StackTrace? stack) =>
                  _Unavailable(
                    title: '图片打不开',
                    detail: '站点可能需要登录态，或链接已过期。下载多半也会失败。',
                    color: scheme.error,
                  ),
        ),
      ),
    );
  }
}

/// 音视频预览：WebView 打开原始地址，交给平台内置播放器。
///
/// 不自己拼 `<video>` 页面：HTML5 的 `video` 标签带不了自定义请求头，
/// 而这里几乎每个地址都需要 Referer / Cookie。直接给 WebView 一个带头的
/// [URLRequest]，请求由浏览器自己发，头也是浏览器自己带的。
class _PlayerView extends StatefulWidget {
  const _PlayerView({required this.item});

  final MediaItem item;

  @override
  State<_PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends State<_PlayerView> {
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (_failed) {
      return _Unavailable(
        title: '没法直接播放',
        detail: '该地址可能要求登录态，或是浏览器不支持的编码。下载后再用本地播放器打开。',
        color: scheme.error,
      );
    }

    return InAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(widget.item.url),
        headers: widget.item.requestHeaders,
      ),
      initialSettings: InAppWebViewSettings(
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        transparentBackground: false,
        // 预览页不拦请求：Windows 上开启这个开关会把每个请求挂起等 Dart 回话，
        // 直接卡死（见 `.agents/rules/03`）。
        useShouldInterceptRequest: false,
      ),
      onReceivedError:
          (
            InAppWebViewController controller,
            WebResourceRequest request,
            WebResourceError error,
          ) {
            AppLog.instance.bump('preview.loadError');
            if (mounted) setState(() => _failed = true);
          },
    );
  }
}

/// 流媒体与其它类型：只摆事实，不假装能放。
class _StreamInfo extends StatelessWidget {
  const _StreamInfo({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool stream = item.type.isStream;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              stream ? Icons.playlist_play_rounded : Icons.insert_drive_file,
              size: 44,
              color: scheme.outline,
            ),
            const SizedBox(height: 14),
            Text(
              stream ? '${item.type.label}，下载后自动合并' : '这类资源没法预览',
              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Text(
              stream
                  ? '流媒体是几百个分片，浏览器里直接打开也放不出来。'
                        '下载时会把分片拼成完整文件，TS 源再点一次「转为 MP4」即可。'
                  : '可以下载后交给对应的应用打开。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: scheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部元信息条：类型、大小、来源页。列表里放不下的信息补在这里。
class _MetaBar extends StatelessWidget {
  const _MetaBar({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<String> parts = <String>[
      item.type.label,
      if (item.mimeType != null) item.mimeType!,
      if (item.contentLength != null) FormatUtil.bytes(item.contentLength),
      if (item.label != null) item.label!,
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            parts.join(' · '),
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            item.url,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: scheme.outline, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({
    required this.title,
    required this.detail,
    required this.color,
  });

  final String title;
  final String detail;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.block, size: 36, color: color),
            const SizedBox(height: 12),
            Text(title, style: TextStyle(fontSize: 14, color: color)),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
