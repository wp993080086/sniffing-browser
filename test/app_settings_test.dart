import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sniffingbrowser/features/settings/data/app_settings.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('settings');
    file = File('${dir.path}/settings.json');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('默认值：分片并发 6，代理留空', () async {
    final AppSettings settings = AppSettings(file: file);
    await settings.load();
    expect(settings.segmentConcurrency, AppSettings.defaultSegmentConcurrency);
    expect(settings.proxy, isEmpty);
  });

  test('分片并发被夹在上下限内', () async {
    final AppSettings settings = AppSettings(file: file);
    await settings.load();

    await settings.setSegmentConcurrency(99);
    expect(settings.segmentConcurrency, AppSettings.maxSegmentConcurrency);

    await settings.setSegmentConcurrency(0);
    expect(settings.segmentConcurrency, AppSettings.minSegmentConcurrency);
  });

  test('写盘后重新读回来保持一致', () async {
    final AppSettings first = AppSettings(file: file);
    await first.load();
    await first.setSegmentConcurrency(3);
    await first.setProxy('127.0.0.1:7890');
    expect(await file.exists(), isTrue);

    final AppSettings second = AppSettings(file: file);
    await second.load();
    expect(second.segmentConcurrency, 3);
    expect(second.proxy, '127.0.0.1:7890');
    // 手动代理优先于环境变量
    expect(second.proxyRule.proxy, '127.0.0.1:7890');
  });

  test('文件损坏时按默认值处理，不抛异常', () async {
    await file.writeAsString('{ 这不是 json');
    final AppSettings settings = AppSettings(file: file);
    await settings.load();
    expect(settings.segmentConcurrency, AppSettings.defaultSegmentConcurrency);
  });
}
