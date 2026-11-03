import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/browser/providers/browser_provider.dart';
import '../features/downloader/data/download_queue.dart';
import '../features/sniffer/data/sniffer_service.dart';
import '../features/transcoder/data/transcode_queue.dart';

/// 全局 Provider。
///
/// 这四个都是应用级单例，注册在 ProviderScope 顶层。
/// 挂到页面里的话，切页导致 dispose，后台任务完成时回调就找不到它们了。

final ChangeNotifierProvider<SnifferService> snifferProvider =
    ChangeNotifierProvider<SnifferService>((Ref ref) => SnifferService());

final ChangeNotifierProvider<DownloadQueue> downloadQueueProvider =
    ChangeNotifierProvider<DownloadQueue>((Ref ref) => DownloadQueue());

final ChangeNotifierProvider<TranscodeQueue> transcodeQueueProvider =
    ChangeNotifierProvider<TranscodeQueue>((Ref ref) => TranscodeQueue());

final ChangeNotifierProvider<BrowserController> browserProvider =
    ChangeNotifierProvider<BrowserController>((Ref ref) => BrowserController());
