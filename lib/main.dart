import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/logging/app_log.dart';
import 'core/platform/platform_info.dart';
import 'core/platform/storage_paths.dart';

Future<void> main() async {
  // 整个启动流程放进 zone，才能捕获到异步链路里的未处理异常。
  // 不这么做的话，后台下载/嗅探里抛的错只会让任务静默失败，日志里什么都没有。
  runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      AppLog.instance.install();
      logInfo('Boot', '启动，平台=${PlatformInfo.displayName}');

      try {
        await StoragePaths.init();
        await AppLog.instance.attachFile();
      } catch (e, s) {
        // 路径初始化失败基本意味着存储不可用，继续启动只会在第一次下载时
        // 抛一个更难懂的错，不如直接把原因显示出来。
        logError('Boot', '存储初始化失败: $e\n$s');
        await AppLog.instance.flushNow();
        runApp(_FatalApp(message: e.toString()));
        return;
      }

      logInfo('Boot', '存储根目录: ${StoragePaths.root.path}');
      runApp(const ProviderScope(child: SniffingBrowserApp()));
    },
    (Object error, StackTrace stack) {
      // zone 里漏出来的异常。记下来，不要让它静默消失。
      logError('Zone', '$error\n$stack');
    },
  );
}

class _FatalApp extends StatelessWidget {
  const _FatalApp({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.error_outline, size: 40),
                const SizedBox(height: 12),
                const Text('存储目录初始化失败'),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
