import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/features/sniffer/domain/media_item.dart';
import 'package:sniffingbrowser/features/sniffer/domain/media_type.dart';
import 'package:sniffingbrowser/features/sniffer/presentation/media_preview_page.dart';

/// 预览页只测「不建播放器」的那条分支：图片和音视频要真实平台视图，
/// widget 测试里跑不起来，也不该为了测它去 mock 整个 WebView。
void main() {
  MediaItem item(MediaType type, {int? length}) => MediaItem(
    id: 'p-$type',
    url: 'https://cdn.example.com/index.m3u8',
    type: type,
    firstSeenAt: DateTime(2026, 11, 24),
    fileName: 'index.m3u8',
    contentLength: length,
    label: '1280x720',
  );

  Future<void> pump(WidgetTester tester, MediaItem media) {
    return tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: MediaPreviewPage(item: media)),
      ),
    );
  }

  testWidgets('HLS 不尝试播放，说明「下载后自动合并」', (WidgetTester tester) async {
    await pump(tester, item(MediaType.hls));

    expect(find.textContaining('下载后自动合并'), findsOneWidget);
    expect(find.textContaining('分片'), findsOneWidget);
  });

  testWidgets('底部元信息带类型、大小与原始地址', (WidgetTester tester) async {
    await pump(tester, item(MediaType.dash, length: 1024 * 1024));

    // 页面标题区和底部元信息条都会出现类型名，这里只要求「有出现」。
    expect(find.textContaining('DASH 流'), findsWidgets);
    expect(find.textContaining('1.0 MB'), findsOneWidget);
    expect(
      find.textContaining('https://cdn.example.com/index.m3u8'),
      findsOneWidget,
    );
  });

  testWidgets('顶部有下载入口', (WidgetTester tester) async {
    await pump(tester, item(MediaType.hls));
    expect(find.byTooltip('下载'), findsOneWidget);
  });
}
