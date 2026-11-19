import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sniffing_browser/app/providers.dart';
import 'package:sniffing_browser/features/sniffer/data/thumbnail_cache.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_item.dart';
import 'package:sniffing_browser/features/sniffer/domain/media_type.dart';
import 'package:sniffing_browser/features/sniffer/presentation/resource_tile.dart';

MediaItem _item(String id, {MediaType type = MediaType.image}) => MediaItem(
  id: id,
  url: 'https://example.com/$id.jpg',
  type: type,
  firstSeenAt: DateTime(2026, 1, 1),
  fileName: '$id.jpg',
);

/// 画一张 2×2 的图并编码成 PNG，当作缩略图的真实字节。
Future<Uint8List> _png() async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 2, 2),
    Paint()..color = const Color(0xFF3366FF),
  );
  final ui.Image image = await recorder.endRecording().toImage(2, 2);
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<void> _pump(WidgetTester tester, ThumbnailCache cache, MediaItem item) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[thumbnailCacheProvider.overrideWithValue(cache)],
      child: MaterialApp(
        home: Scaffold(body: ResourceTile(item: item)),
      ),
    ),
  );
}

void main() {
  testWidgets('取到图时列表项渲染缩略图', (WidgetTester tester) async {
    final ThumbnailCache cache = ThumbnailCache(
      loader: (MediaItem item) => _png(),
    );

    // 图片解码走引擎的真实线程，必须在 runAsync 里推进，
    // 否则假时钟永远等不到解码结果（表现为整个用例卡死）。
    await tester.runAsync(() async {
      await _pump(tester, cache, _item('a'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsNothing);
  });

  testWidgets('取不到图时退回类型图标', (WidgetTester tester) async {
    final ThumbnailCache cache = ThumbnailCache(
      loader: (MediaItem item) async => null,
    );

    await _pump(tester, cache, _item('a'));
    await tester.pump();

    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
  });

  testWidgets('音频不走缩略图，始终是类型图标', (WidgetTester tester) async {
    int calls = 0;
    final ThumbnailCache cache = ThumbnailCache(
      loader: (MediaItem item) async {
        calls++;
        return null;
      },
    );

    await _pump(tester, cache, _item('a', type: MediaType.audio));
    await tester.pump();

    expect(calls, 0);
    expect(find.byIcon(Icons.music_note_outlined), findsOneWidget);
  });
}
