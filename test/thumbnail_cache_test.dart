import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/features/sniffer/data/thumbnail_cache.dart';
import 'package:sniffingbrowser/features/sniffer/domain/media_item.dart';
import 'package:sniffingbrowser/features/sniffer/domain/media_type.dart';

MediaItem _item(String id, {MediaType type = MediaType.image}) => MediaItem(
  id: id,
  url: 'https://example.com/$id.jpg',
  type: type,
  firstSeenAt: DateTime(2026, 1, 1),
);

Uint8List _bytes(int length) => Uint8List(length);

void main() {
  group('ThumbnailCache 取图与缓存', () {
    test('同一 id 只加载一次，第二次直接命中', () async {
      int calls = 0;
      final ThumbnailCache cache = ThumbnailCache(
        loader: (MediaItem item) async {
          calls++;
          return _bytes(4);
        },
      );

      expect(await cache.get(_item('a')), isNotNull);
      expect(await cache.get(_item('a')), isNotNull);
      expect(calls, 1);
      expect(cache.cachedCount, 1);
    });

    test('并发请求同一 id 会合并成一个 loader 调用', () async {
      int calls = 0;
      final Completer<Uint8List?> gate = Completer<Uint8List?>();
      final ThumbnailCache cache = ThumbnailCache(
        loader: (MediaItem item) {
          calls++;
          return gate.future;
        },
      );

      final Future<Uint8List?> first = cache.get(_item('a'));
      final Future<Uint8List?> second = cache.get(_item('a'));
      gate.complete(_bytes(4));

      expect(await first, isNotNull);
      expect(await second, isNotNull);
      expect(calls, 1);
    });

    test('失败结论也会缓存，不会每次滚回来都重试', () async {
      int calls = 0;
      final ThumbnailCache cache = ThumbnailCache(
        loader: (MediaItem item) async {
          calls++;
          throw StateError('403');
        },
      );

      expect(await cache.get(_item('a')), isNull);
      expect(await cache.get(_item('a')), isNull);
      expect(calls, 1);
    });

    test('超时按失败处理并释放并发额度', () async {
      final ThumbnailCache cache = ThumbnailCache(
        maxConcurrent: 1,
        timeout: const Duration(milliseconds: 30),
        loader: (MediaItem item) => item.id == 'a'
            ? Completer<Uint8List?>().future
            : Future<Uint8List?>.value(_bytes(4)),
      );

      expect(await cache.get(_item('a')), isNull);
      // 名额没释放的话，这一句会一直挂到测试超时。
      expect(await cache.get(_item('b')), isNotNull);
    });

    test('音频 / HLS / DASH 没有缩略图，loader 不会被调用', () async {
      int calls = 0;
      final ThumbnailCache cache = ThumbnailCache(
        loader: (MediaItem item) async {
          calls++;
          return _bytes(4);
        },
      );

      expect(await cache.get(_item('a', type: MediaType.audio)), isNull);
      expect(await cache.get(_item('b', type: MediaType.hls)), isNull);
      expect(await cache.get(_item('c', type: MediaType.dash)), isNull);
      expect(calls, 0);
      expect(cache.supports(MediaType.image), isTrue);
      expect(cache.supports(MediaType.video), isTrue);
      expect(cache.supports(MediaType.other), isFalse);
    });
  });

  group('ThumbnailCache 容量与并发', () {
    test('超过上限淘汰最久未使用的条目', () async {
      final List<String> loaded = <String>[];
      final ThumbnailCache cache = ThumbnailCache(
        maxEntries: 2,
        loader: (MediaItem item) async {
          loaded.add(item.id);
          return _bytes(4);
        },
      );

      await cache.get(_item('a'));
      await cache.get(_item('b'));
      // 摸一下 a，让它变成“最近用过”，被淘汰的应是 b。
      await cache.get(_item('a'));
      await cache.get(_item('c'));

      expect(cache.cachedCount, 2);
      expect(cache.peek('b'), isNull);
      expect(loaded, <String>['a', 'b', 'c']);

      await cache.get(_item('b'));
      expect(loaded, <String>['a', 'b', 'c', 'b']);
    });

    test('排队超过上限时这一轮直接跳过，且不记成失败', () async {
      int calls = 0;
      final Completer<Uint8List?> gate = Completer<Uint8List?>();
      final ThumbnailCache cache = ThumbnailCache(
        maxConcurrent: 1,
        maxQueued: 1,
        loader: (MediaItem item) {
          calls++;
          return gate.future;
        },
      );

      final Future<Uint8List?> running = cache.get(_item('a'));
      final Future<Uint8List?> queued = cache.get(_item('b'));
      // 第三个连排队资格都没有。
      expect(await cache.get(_item('c')), isNull);

      gate.complete(_bytes(4));
      expect(await running, isNotNull);
      expect(await queued, isNotNull);
      expect(calls, 2);

      // 被跳过的那条没留下失败结论，之后还能再取。
      expect(cache.cachedCount, 2);
    });

    test('同时进行的 loader 不超过 maxConcurrent', () async {
      int running = 0;
      int peak = 0;
      final ThumbnailCache cache = ThumbnailCache(
        maxConcurrent: 2,
        loader: (MediaItem item) async {
          running++;
          if (running > peak) peak = running;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          running--;
          return _bytes(4);
        },
      );

      await Future.wait(<Future<Uint8List?>>[
        cache.get(_item('a')),
        cache.get(_item('b')),
        cache.get(_item('c')),
        cache.get(_item('d')),
      ]);

      expect(peak, 2);
      expect(cache.cachedCount, 4);
    });
  });
}
