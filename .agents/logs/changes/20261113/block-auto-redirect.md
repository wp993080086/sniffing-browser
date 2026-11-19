> 记录路径：.agents/logs/changes/20261113/block-auto-redirect.md

# 拦截自动跳转 + 修正来源页污染导致的 403

- 日期：2026-11-13
- 任务：限制页面自己乱跳；排查 m3u8 下载仍然 403

## 现场日志（真机 app.log）

```
18:31:16 D/Thumb 图片 403 https://surrit.com/6fdc.../640x360/video0.jpeg
18:31:18 W/Download 403 https://surrit.com/6fdc.../640x360/video.m3u8 已发送的头: User-Agent, Origin, Referer, Accept
18:30:29 I/WebView 加载完成（tab_2）: https://diffusedpassionquaking.com/sklnk/1919723?...
18:33:28 I/WebView 加载完成（tab_2）: https://wheelroot.com/api/v1/direct/...
```

对照 curl 复现（同一 m3u8）：

| Referer | 结果 |
|---|---|
| `https://missav.live/...` | 200 |
| `https://wheelroot.com/...`（广告页） | 403 |
| 无 Referer | 403 |
| Origin 换成广告站 | 200（与 Origin 无关） |

结论：surrit.com 只校验 Referer 是否属于视频站。下载 403 不是因为缺 Cookie，
而是**下载用的 Referer 是广告落地页** —— popunder 把当前页顶掉了，
`SnifferService.currentPageUrl`（下载 Referer 的兜底来源）被改成了广告站。

## 改动

**拦截自动跳转（问题 1）**

- `core/utils/site.dart`：新增 `isSameSite(a, b)`，按注册域比较（含 com.cn 等两级后缀、IP）。
- `webview_host.dart`：`shouldOverrideUrlLoading` 抽成 `_handleNavigation`。
  - 非 http(s) 协议 → 取消（原逻辑）。
  - 服务器重定向 → 沿用本次可信度，不重判。
  - 无手势 + 跨站 + 主框架 → 取消（`TabManager.blockAutoRedirect` 开启时），
    并弹一次「已阻止自动跳转」（3 秒节流，带「关闭拦截」）。
  - 用户手势 / 站内跳转 → 放行。
- `tab_manager.dart`：`blockAutoRedirect`（默认 true）+ `setBlockAutoRedirect`。
- `browser_header.dart`：第二层加盾牌开关 `_RedirectGuardButton`。

**来源页不再被污染（问题 2 的根因）**

- `sniffer_service.dart`：`setCurrentPage(url, {trusted = true})`，`trusted == false` 时
  不覆盖当前页。
- `webview_host.dart`：新增 `_navTrusted`，在 `_handleNavigation` 里判定
  （手势或同站），`onLoadStart` / `onLoadStop` 按它决定是否记录来源页。

**诊断日志**

- `file_downloader.dart`：403 时记 `Referer=值`、`Cookie=[名]`、`Server`、`CF-Ray`；
  Cookie 取不到的域名每域名记一次 debug。

## 验证

- `flutter analyze`：No issues。
- `flutter test`：152 通过 / 8 跳过（新增 `site_test.dart` 6 条）。
- `flutter build apk --debug`：成功。真机安装时设备已断开，待复测：
  - 点播放不再被弹到广告站；屏蔽后列表的 pageUrl 仍是被播放页；
  - 同一 m3u8 重下是否还 403（看 403 日志里的 Referer 值是否为视频站）。
