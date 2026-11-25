import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sniffingbrowser/features/browser/data/bookmark_service.dart';
import 'package:sniffingbrowser/features/browser/data/bookmark_store.dart';

void main() {
  late Directory dir;
  late BookmarkStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bookmark_test');
    store = BookmarkStore(file: File(p.join(dir.path, 'bookmarks.json')));
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  BookmarkService service({int maxEntries = 300}) =>
      BookmarkService(store: store, maxEntries: maxEntries);

  test('toggle 一次收藏、再一次取消', () {
    final BookmarkService bookmarks = BookmarkService();

    expect(bookmarks.toggle(url: 'https://a.com', title: 'A'), isTrue);
    expect(bookmarks.contains('https://a.com'), isTrue);
    expect(bookmarks.count, 1);

    expect(bookmarks.toggle(url: 'https://a.com'), isFalse);
    expect(bookmarks.contains('https://a.com'), isFalse);
    expect(bookmarks.isEmpty, isTrue);
  });

  test('最新收藏的排在最前', () {
    final BookmarkService bookmarks = BookmarkService();
    bookmarks.toggle(url: 'https://a.com');
    bookmarks.toggle(url: 'https://b.com');

    expect(bookmarks.entries.first.url, 'https://b.com');
  });

  test('非网页地址不能收藏', () {
    final BookmarkService bookmarks = BookmarkService();

    expect(bookmarks.toggle(url: 'about:blank'), isFalse);
    expect(bookmarks.toggle(url: ''), isFalse);
    expect(bookmarks.isEmpty, isTrue);
  });

  test('超过上限时丢最早的', () {
    final BookmarkService bookmarks = BookmarkService(maxEntries: 2);
    bookmarks.toggle(url: 'https://a.com');
    bookmarks.toggle(url: 'https://b.com');
    bookmarks.toggle(url: 'https://c.com');

    expect(bookmarks.count, 2);
    expect(bookmarks.contains('https://a.com'), isFalse);
  });

  test('落盘后能被新实例读回', () async {
    final BookmarkService first = service();
    first.toggle(url: 'https://a.com/x', title: 'X');
    await first.flush();

    final BookmarkService second = service();
    await second.restore();

    expect(second.count, 1);
    expect(second.contains('https://a.com/x'), isTrue);
    expect(second.entries.single.title, 'X');
  });

  test('contains 对空串恒为 false', () {
    final BookmarkService bookmarks = BookmarkService();
    bookmarks.toggle(url: 'https://a.com');

    expect(bookmarks.contains(''), isFalse);
  });
}
