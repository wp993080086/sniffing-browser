import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform/webview_cookies.dart';
import '../features/browser/data/bookmark_service.dart';
import '../features/browser/data/bookmark_store.dart';
import '../features/browser/data/history_service.dart';
import '../features/browser/data/history_store.dart';
import '../features/browser/providers/tab_manager.dart';
import '../features/downloader/data/download_queue.dart';
import '../features/downloader/data/download_store.dart';
import '../features/downloader/data/file_downloader.dart';
import '../features/sniffer/data/sniffer_service.dart';
import '../features/sniffer/data/thumbnail_cache.dart';
import '../features/sniffer/data/thumbnail_service.dart';
import '../features/settings/data/app_settings.dart';
import '../features/transcoder/data/transcode_queue.dart';
import '../features/transcoder/data/transcode_store.dart';

/// 全局 Provider。
///
/// 这几个都是应用级单例，注册在 ProviderScope 顶层。
/// 挂到页面里的话，切页导致 dispose，后台任务完成时回调就找不到它们了。

/// 多页签：每个页签一份网页状态和嗅探结果，这里暴露「当前页签」。
final ChangeNotifierProvider<TabManager> tabManagerProvider =
    ChangeNotifierProvider<TabManager>((Ref ref) => TabManager());

/// 当前页签的嗅探结果。
///
/// 用普通 Provider 而不是 ChangeNotifierProvider：返回值归某个页签所有，
/// 不能由 provider 负责销毁 —— 切页签时 provider 会重建，旧页签却还活着。
/// 需要跟随资源列表刷新时用 `ListenableBuilder(listenable: sniffer)`。
final Provider<SnifferService> snifferProvider = Provider<SnifferService>(
  (Ref ref) => ref.watch(tabManagerProvider).activeSniffer,
);

/// 嗅探列表缩略图：内存缓存 + 并发限制 + 请求去重，应用级单例。
///
/// 不落盘 —— 嗅探结果本身不持久化，重启后列表就空了。
final Provider<ThumbnailCache> thumbnailCacheProvider =
    Provider<ThumbnailCache>(
      (Ref ref) => ThumbnailCache(loader: ThumbnailService.load),
    );

/// 转换队列带持久化：任务记录写在应用私有根目录，重启后还能看到历史，
/// 未完成的（pending）会接着跑。测试里直接 `TranscodeQueue()` 即不落盘。
final ChangeNotifierProvider<TranscodeQueue> transcodeQueueProvider =
    ChangeNotifierProvider<TranscodeQueue>(
      (Ref ref) => TranscodeQueue(store: TranscodeStore()),
    );

/// 下载队列依赖转码队列：DASH 分片的音视频要合并。
///
/// 反过来不依赖 —— 转码队列不知道下载队列的存在，合并完成只通过
/// `onFinished` 回调通知，避免两个单例互相持有。
///
/// 带持久化：记录写在应用私有 files 目录，重启后历史还在，
/// 没下完的标成「已中断，可重试」。测试里直接 `DownloadQueue()` 即不落盘。
///
/// 注入 [WebViewCookies.forUrl]：嗅探拿到的头里没有 Cookie（Android 的
/// `WebResourceRequest` 不返回），下载时按每个请求 URL 现取，见 5.6。
final ChangeNotifierProvider<DownloadQueue> downloadQueueProvider =
    ChangeNotifierProvider<DownloadQueue>((Ref ref) {
      // 用 read 而不是 watch：设置一变就重建队列会 dispose 掉正在跑的下载。
      final AppSettings settings = ref.read(appSettingsProvider);
      return DownloadQueue(
        downloader: FileDownloader(
          // 代理按请求现取，设置页改完对后续请求立刻生效。
          dio: FileDownloader.createDio(proxy: () => settings.proxyRule),
          cookieLoader: WebViewCookies.forUrl,
        ),
        transcoder: ref.watch(transcodeQueueProvider),
        poolSupplier: () => ref.read(snifferProvider).items,
        segmentConcurrency: () => settings.segmentConcurrency,
        siteRules: () => settings.siteRules,
        afterDownload: () => settings.afterDownload,
        autoResume: () => settings.autoResume,
        store: DownloadStore(),
      );
    });

/// 应用设置：分片并发、代理。落盘在私有根目录的 `settings.json`。
final ChangeNotifierProvider<AppSettings> appSettingsProvider =
    ChangeNotifierProvider<AppSettings>((Ref ref) => AppSettings());

/// 浏览历史。全局一份——历史本来就跨页签，切页签不该换一份记录。
///
/// 落盘在应用私有根目录的 `history.json`，重启后还在。
/// 测试里直接 `HistoryService()` 即纯内存。
final ChangeNotifierProvider<HistoryService> historyProvider =
    ChangeNotifierProvider<HistoryService>(
      (Ref ref) => HistoryService(store: HistoryStore()),
    );

/// 收藏夹。独立文件，清历史不影响收藏。
final ChangeNotifierProvider<BookmarkService> bookmarkProvider =
    ChangeNotifierProvider<BookmarkService>(
      (Ref ref) => BookmarkService(store: BookmarkStore()),
    );
