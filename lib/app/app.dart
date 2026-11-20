import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../core/constants/app_constants.dart';
import '../features/browser/presentation/browser_page.dart';

class SniffingBrowserApp extends ConsumerStatefulWidget {
  const SniffingBrowserApp({super.key});

  @override
  ConsumerState<SniffingBrowserApp> createState() => _SniffingBrowserAppState();
}

class _SniffingBrowserAppState extends ConsumerState<SniffingBrowserApp> {
  @override
  void initState() {
    super.initState();
    // 恢复上次的转换 / 下载记录和历史、收藏。放在这里而不是 main()：
    // Provider 树在 runApp 之后才存在；也不能放进 build，否则每次重建都会
    // 再读一次磁盘。
    //
    // 设置放最前面：下载队列的代理与分片并发都是现取，但启动日志里先有
    // 「代理 xx、并发 x」才好排查后面的事。
    unawaited(ref.read(appSettingsProvider).load());
    unawaited(ref.read(transcodeQueueProvider).restore());
    unawaited(ref.read(downloadQueueProvider).restore());
    unawaited(ref.read(historyProvider).restore());
    unawaited(ref.read(bookmarkProvider).restore());
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const BrowserPage(),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF2F6FED),
        brightness: brightness,
      ),
      visualDensity: VisualDensity.adaptivePlatformDensity,
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
