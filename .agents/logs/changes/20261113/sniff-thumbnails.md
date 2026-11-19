> 记录路径：.agents/logs/changes/20261113/sniff-thumbnails.md

# 嗅探列表缩略图（图片 + 视频首帧）

- 日期：2026-11-13
- 任务：用户问「嗅探列表没有预览图正常吗」。确认这是原设计的取舍
  （tech-design 8.0「本期不做资源缩略图」），用户选择补齐，范围定为
  **只做图片和视频首帧**，音频 / HLS / DASH 继续用类型图标。
- 内容：
  - `lib/features/sniffer/data/thumbnail_cache.dart`（新）：内存 LRU（120 条）+
    同 id 请求去重 + 并发 3 + 排队上限 8 + 12 秒超时 + 失败结论也缓存；
    超限跳过的请求不记结论，滚回来还能再试。
  - `lib/features/sniffer/data/thumbnail_service.dart`（新）：按类型分派。
    图片走 `HttpClient` 带嗅探缓存的请求头重新取一次，`instantiateImageCodec`
    的 `targetWidth` 直接降采样到 160px 再编成 PNG；视频在 Android 走
    `sniffing_browser/thumbnailer` 通道，桌面走本机 ffmpeg `-frames:v 1`
    输出 PNG 到管道；鸿蒙返回 null。
  - `android/.../ThumbnailBridge.kt`（新）：`MediaMetadataRetriever`
    抽帧。线程池固定 2 线程（无超时参数，一条卡住不影响其他条目），
    缩放后压 PNG 回传，`AtomicBoolean` 保证只 reply 一次，`release()` 放 finally。
  - `MainActivity.kt` 注册第三个通道，与导出/转码并列。
  - `resource_tile.dart`：把类型图标容器换成 `_ResourceThumb`，`FutureBuilder`
    取图，失败/未加载/不支持都退回原来的图标；`didUpdateWidget` 按 `item.id`
    重新取图（列表复用 State 会换 item）。
  - `providers.dart` 新增 `thumbnailCacheProvider`（应用级单例，不落盘）。
  - `test/thumbnail_cache_test.dart`（新，8 条）：缓存命中、并发合并、
    失败缓存、超时释放额度、不支持类型、LRU 淘汰、排队上限、并发峰值。
  - `test/resource_tile_test.dart`（新，3 条）：取到图渲染 `Image`、
    取不到退回图标、音频不走缩略图。图片解码走引擎真实线程，
    断言必须包在 `tester.runAsync` 里，否则假时钟等不到解码结果、
    整个用例会卡死（踩过一次）。
- 关键取舍：
  - **不落盘**：嗅探结果本身不持久化，重启后列表就空，为一次性缩略图写磁盘没有收益。
  - **不显示 loading**：几十条同时转圈比没图更难看；加载期间就是类型图标。
  - **单图上限 3 MB**：超过宁可给图标，不在手机上为一张缩略图啃几 MB。
  - **不做点击放大预览**：列表只负责辨认「是不是这条」。
- 结果：`flutter analyze` No issues；`flutter test` 96 通过 / 8 跳过；
  `flutter build apk --debug` EXIT=0（55.4s）。真机待验：图片缩略图、
  B 站 m4s 首帧、403 站点退回图标。
- 已知限制：需要登录态且 Cookie 没随请求头带下来的站点 403；Android 9+
  明文 `http://` 图片可能被系统策略拦掉；鸿蒙视频缩略图恒为图标。
