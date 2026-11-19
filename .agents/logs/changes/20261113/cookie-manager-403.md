# HLS 403：接入 CookieManager + 平台化 UA

- 日期：2026-11-13
- 触发：真机下载 `video.m3u8` 报「403 拒绝访问，缺少 Referer 或 Cookie」
- 记录路径：`.agents/logs/changes/20261113/cookie-manager-403.md`

## 定位

1. `download_queue.dart:_createTask` **已经**在 headers 缺 Referer 时补 `item.pageUrl`，
   `sniffer_service` 也有 `_currentPageUrl` 兜底 —— Referer 这一环不是根因。
2. `file_downloader._sanitizeHeaders` 在缺 UA 时会补一个**写死的桌面 Chrome UA**，
   Android 上也一样。
3. 真正的缺口：Android 的 `WebResourceRequest.getRequestHeaders()` **不返回 Cookie**。
   Cookie 由原生网络栈按 CookieManager 注入，Dart 侧看不到，所以
   `sniffer_service.cacheRequestHeaders()` 存下来的头里永远没有 Cookie。
   要登录态 / 校验 Cookie 的 m3u8、m4s 必然 403。

## 改动

| 文件 | 内容 |
| --- | --- |
| `lib/core/platform/webview_cookies.dart`（新） | `WebViewCookies.forUrl` → `CookieManager.instance().getCookies(url: WebUri(url))` 拼成 `name=value; ...`；仅 Android 生效，取不到返回 null，异常吞掉 |
| `lib/features/downloader/data/file_downloader.dart` | 加 `CookieLoader` typedef 与可选构造参数；`download` / `fetchBytes` 在**发起前**用 `_withCookies(url, headers)` 补 Cookie（每个请求各取一次，按 URL）；新增 `mergeCookies`（public + `@visibleForTesting`）；403 时 `logWarn` 记「已发送的头名」；缺省 UA 改为按平台（移动端移动 UA） |
| `lib/features/downloader/data/download_queue.dart` | `_hls` 改 `late final`，默认 `HlsDownloader(downloader: _downloader)` —— HLS 与单文件共用同一个 downloader，Cookie/超时/重试策略不会两套 |
| `lib/app/providers.dart` | 注入 `FileDownloader(cookieLoader: WebViewCookies.forUrl)` |

## 取舍

- **不在入队时取 Cookie**：HLS 分片常换到 CDN 域名，必须按各自 URL 查；
  入队时拿的是 playlist 域的 Cookie，对分片无效。
- **合并而不是覆盖**：嗅探到的 Cookie 头是页面当时真实生效的那份，同名以它为准；
  CookieManager 补的是缺的部分。
- **HLS 复用同一个 FileDownloader**：否则要改 HlsDownloader 的三个 fetch 调用点，
  且以后调超时/重试会漏掉一边。
- **只 Android 生效**：Windows 走 CDP，`requestWillBeSent` 的 headers 自带 Cookie。
- 取 Cookie 失败静默降级：宁可照常发、让真实错误暴露，也不要抛一个与 403 无关的异常。

## 测试

- 新增 `test/file_downloader_cookies_test.dart`（5 条）：只有 jar 那份 / 同名优先 /
  各自独有项保留 / 空值与非法片段 / 值里带等号不被截断。
- 没测 `_withCookies` 本身：它依赖 WebView 通道；合并逻辑已抽成纯函数单测覆盖。
- `flutter analyze` 0 issue；`flutter test` **110 通过 / 8 跳过**；
  `flutter build apk --debug` EXIT=0（21.9s）。

## 真机复验

1. 同一个 `video.m3u8` 重新下载 —— 应该不再 403；
2. 若仍 403，看日志里 `403 <url> 已发送的头: ...`：
   - 有 `Referer`、有 `Cookie` → 站点多半还要 `Origin` / `Sec-Fetch-*` / 动态签名，
     属已知边界；
   - 有 `Referer`、无 `Cookie` → CookieManager 里确实没有该域 Cookie
     （页面没登录或 Cookie 是 3rd-party 被拦）；
   - 两个都没有 → 嗅探没缓存到该 URL 的头，且 `pageUrl` 为空。
3. 顺带看 mp4 / m4s 直链是否也恢复（同一套头）。
