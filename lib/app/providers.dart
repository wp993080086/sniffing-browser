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

final ChangeNotifierProvider<TranscodeQueue> transcodeQueueProvider =
    ChangeNotifierProvider<TranscodeQueue>((Ref ref) => TranscodeQueue());

/// 下载队列依赖转码队列：DASH 分片的音视频要合并。
///
/// 反过来不依赖 —— 转码队列不知道下载队列的存在，合并完成只通过
/// `onFinished` 回调通知，避免两个单例互相持有。
final ChangeNotifierProvider<DownloadQueue> downloadQueueProvider =
    ChangeNotifierProvider<DownloadQueue>((Ref ref) => DownloadQueue(
          transcoder: ref.watch(transcodeQueueProvider),
          poolSupplier: () => ref.read(snifferProvider).items,
        ));

final ChangeNotifierProvider<BrowserController> browserProvider =
    ChangeNotifierProvider<BrowserController>((Ref ref) => BrowserController());
