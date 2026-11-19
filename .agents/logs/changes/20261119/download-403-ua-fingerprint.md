# 下载 403 根因：UA 与客户端指纹对不上

日期：2026-11-19

## 现象

真机下载 `b.surrit.com/.../video.m3u8` 稳定 403，提示「缺少 Referer 或 Cookie」，
但日志里 Referer 是正确的视频页地址、Cookie 为空也一样 403：

```
W/Download 403 https://b.surrit.com/.../video.m3u8
Referer=https://missav.ws/snos-461-uncensored-leak Cookie=[(无)]
Server=cloudflare CF-Ray=a5cc15870d259802-NRT
```

缩略图（`video4.jpeg` 等）同样 403，说明不是下载链路独有的问题。

## 排查过程

1. PC 上 curl 同地址：带同一个 Referer → 200；不带 Referer → 403（Cloudflare
   「Sorry, you have been blocked」）。说明站点确实校验 Referer，但我们的 Referer 没问题。
2. 逐项对比 UA / Accept / Accept-Encoding / Origin / Sec-Fetch-*：全部 200，
   说明「加了某个头才 403」的假设不成立。
3. 关键一步：用**同一份 Dart 代码**（同样的 dio + HttpClient）分别经手机代理与
   直连请求，逐个变体打印状态码 —— Dart 一律 403，curl 一律 200。差异只剩客户端本身。
4. 再按 UA 分组：

   | UA | 结果 |
   |---|---|
   | `Dart/3.9 (dart:io)`（不设 UA 的默认值） | 200 |
   | `okhttp/4.12.0` | 200 |
   | Chrome 移动 / 桌面、Firefox、Safari | 403 |
   | 空字符串 | 403 |

   结论：Cloudflare 的 Browser Integrity Check 比对「UA 声称的浏览器」与 TLS
   指纹，`dart:io` 的指纹不是 Chrome，冒充 Chrome 就被判成伪装。

顺带排除了两个误导项：手机的 Clash 出口是英国 VPS（143.20.35.91），一度怀疑
IP 被封，但经同一出口用 curl 访问是 200，IP 无关；Cookie 也确实为空，且站点
在无 Cookie 情况下也接受 curl。

## 改动

- 新增 `lib/core/platform/browser_headers.dart`：`withBrowserHeaders`（补
  `Accept` / `Accept-Language` / `sec-ch-ua*` / `Sec-Fetch-*`）、
  `withNeutralUserAgent`（换中性 UA 并去掉自相矛盾的客户端提示）。
- `FileDownloader`：403 时按「补浏览器头 → 换中性 UA」两套头依次重试，成功即
  继续；404 / 超时不重试；最终仍失败才打诊断日志（含 Referer、Cookie 名、
  Server、CF-Ray，以及 403 响应体里的 Cloudflare error code）。
- `ThumbnailService._image`：403 时用中性 UA 重试一次。
- 错误文案从「403 拒绝访问，缺少 Referer 或 Cookie」改成带诊断结论的表述，
  不再把锅甩给 Referer。

## 验证

- 单测新增 `browser_headers_test.dart`（6 条）、`file_downloader_403_test.dart`（3 条，
  用「UA 含 Mozilla 就 403」的假 adapter 模拟 BIC）；
- `flutter analyze` 无问题；`flutter test` 174 通过 / 8 跳过；
- `flutter build apk --release` 成功（118MB），已装机。

## 遗留

真机上「403 后第 2 套请求头成功」这条日志还需要实测确认一次（`I/Download`
级别），确认后可以把首套头也直接收敛到中性 UA，省掉一次请求。
