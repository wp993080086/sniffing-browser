import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sniffingbrowser/core/constants/app_constants.dart';
import 'package:sniffingbrowser/core/logging/app_log.dart';
import 'package:sniffingbrowser/core/platform/platform_info.dart';
import 'package:sniffingbrowser/core/platform/storage_paths.dart';

/// 日志导出的核心诉求：崩溃重开之后，上一次会话的现场还在导出的 txt 里。
void main() {
  late Directory root;
  late File logFile;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sniff_log_');
    await StoragePaths.initWithRoot(root);
    AppLog.instance.resetForTesting();
    logFile = File(p.join(StoragePaths.root.path, 'logs', 'app.log'));
  });

  tearDown(() async {
    AppLog.instance.resetForTesting();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('导出包含磁盘上上一次会话留下的日志', () async {
    await logFile.parent.create(recursive: true);
    await logFile.writeAsString('2026-11-23 10:00:00.000 I/Boot 上次启动\n');
    await AppLog.instance.attachFile();

    logInfo('Download', '本次启动的下载失败 403');

    final String text = await AppLog.instance.exportBundle();
    expect(text, contains('上次启动'));
    expect(text, contains('本次启动的下载失败 403'));
  });

  test('已落盘的行不会在导出里重复', () async {
    await AppLog.instance.attachFile();
    logInfo('Test', '唯一的一条');
    await AppLog.instance.flushNow();

    final String text = await AppLog.instance.exportBundle();
    expect('唯一的一条'.allMatches(text).length, 1);
  });

  test('落盘之后新增的行也会出现在导出里', () async {
    await AppLog.instance.attachFile();
    logInfo('Test', '先写入');
    await AppLog.instance.flushNow();
    logInfo('Test', '刚发生还没落盘');

    final String text = await AppLog.instance.exportBundle();
    expect(text, contains('先写入'));
    expect(text, contains('刚发生还没落盘'));
    expect('先写入'.allMatches(text).length, 1);
  });

  test('导出头部带版本、平台与存储路径', () async {
    await AppLog.instance.attachFile();
    AppLog.instance.bump('cdp.responseReceived');

    final String text = await AppLog.instance.exportBundle();
    expect(text, contains(AppConstants.version));
    expect(text, contains(PlatformInfo.displayName));
    expect(text, contains(StoragePaths.root.path));
    expect(text, contains('=== 计数器 ==='));
    expect(text, contains('cdp.responseReceived: 1'));
  });

  test('文件末尾被截断成半个汉字也不影响导出', () async {
    await logFile.parent.create(recursive: true);
    // 进程被杀时最后一行可能只写了 UTF-8 的前两个字节。
    await logFile.writeAsBytes(<int>[
      ...utf8.encode('2026-11-23 10:00:00.000 I/Boot 正常一行\n'),
      0xE4,
      0xBD,
    ]);
    await AppLog.instance.attachFile();
    logInfo('Boot', '新会话');

    final String text = await AppLog.instance.exportBundle();
    expect(text, contains('正常一行'));
    expect(text, contains('新会话'));
  });

  test('启动分隔线能区分不同会话', () async {
    await AppLog.instance.attachFile();
    AppLog.instance.banner('启动 ${AppConstants.version} · 测试');

    final String text = await AppLog.instance.exportBundle();
    expect(text, contains('启动 ${AppConstants.version} · 测试'));
  });
}
