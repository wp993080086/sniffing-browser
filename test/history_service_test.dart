import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sniffingbrowser/features/browser/data/history_service.dart';
import 'package:sniffingbrowser/features/browser/data/history_store.dart';

void main() {
  late Directory dir;
  late HistoryStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('history_test');
    store = HistoryStore(file: File(p.join(dir.path, 'history.json')));
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  HistoryService service({int maxEntries = 500}) =>
      HistoryService(store: store, maxEntries: maxEntries);

  test('记录网页后最新的一条在最前', () {
    final HistoryService history = HistoryService();
    history.record(url: 'https://a.com/1', title: 'A');
    history.record(url: 'https://b.com/2', title: 'B');

    expect(history.count, 2);
    expect(history.entries.first.url, 'https://b.com/2');
    expect(history.entries.first.title, 'B');
  });

  test('非网页地址不记录', () {
    final HistoryService history = HistoryService();
    history.record(url: 'about:blank');
    history.record(url: 'blob:https://a.com/xxx');
    history.record(url: 'data:text/html,x');
    history.record(url: '');

    expect(history.isEmpty, isTrue);
  });

  test('同地址重复访问只留一条并提到最前', () {
    final HistoryService history = HistoryService();
    history.record(url: 'https://a.com', title: '旧标题');
    history.record(url: 'https://b.com');
    history.record(url: 'https://a.com', title: '新标题');

    expect(history.count, 2);
    expect(history.entries.first.url, 'https://a.com');
    // 标题取最近一次，不是第一次那个。
    expect(history.entries.first.title, '新标题');
  });

  test('超过上限时丢最旧的', () {
    final HistoryService history = HistoryService(maxEntries: 3);
    for (int i = 1; i <= 5; i++) {
      history.record(url: 'https://a.com/$i');
    }

    expect(history.count, 3);
    expect(history.entries.map((e) => e.url), <String>[
      'https://a.com/5',
      'https://a.com/4',
      'https://a.com/3',
    ]);
  });

  test('删除单条与清空', () {
    final HistoryService history = HistoryService();
    history.record(url: 'https://a.com');
    history.record(url: 'https://b.com');

    history.remove('https://a.com');
    expect(history.count, 1);
    expect(history.entries.single.url, 'https://b.com');

    history.clear();
    expect(history.isEmpty, isTrue);
  });

  test('落盘后能被新实例读回', () async {
    final HistoryService first = service();
    first.record(url: 'https://a.com/x', title: 'X');
    await first.flush();

    final HistoryService second = service();
    await second.restore();

    expect(second.count, 1);
    expect(second.entries.single.url, 'https://a.com/x');
    expect(second.entries.single.title, 'X');
  });

  test('记录文件损坏时按空处理，不抛异常', () async {
    await File(p.join(dir.path, 'history.json')).writeAsString('{ 坏掉的');

    final HistoryService history = service();
    await history.restore();

    expect(history.isEmpty, isTrue);
    // 坏文件之后还能正常写入。
    history.record(url: 'https://a.com');
    await history.flush();
    expect(history.count, 1);
  });

  test('isWebUrl 只认 http/https', () {
    expect(HistoryService.isWebUrl('https://a.com'), isTrue);
    expect(HistoryService.isWebUrl('HTTP://a.com'), isTrue);
    expect(HistoryService.isWebUrl('file:///tmp/a'), isFalse);
    expect(HistoryService.isWebUrl('sniffing://x'), isFalse);
  });
}
