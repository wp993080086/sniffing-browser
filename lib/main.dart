import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/platform/storage_paths.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await StoragePaths.init();
  } catch (e) {
    // 路径初始化失败基本意味着存储不可用，继续启动只会在第一次下载时
    // 抛一个更难懂的错，不如直接把原因显示出来。
    runApp(_FatalApp(message: e.toString()));
    return;
  }

  runApp(const ProviderScope(child: SniffingBrowserApp()));
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
