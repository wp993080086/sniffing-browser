> 记录路径：.agents/logs/changes/20261123/login-state-management.md

# 登录态管理

- 日期：2026-11-23
- 任务：回答「上次登录下次自动登录是谁做的」，并给出可用的查看 / 清除入口。

## 结论

浏览器负责**保存并带回** Cookie（本应用重启不清 Cookie，下载时还会按 URL 现取注入）；
网站负责**是否下发长期免登录凭证**。只发会话 Cookie 的站点，浏览器无法代替自动登录。
因此没有做「自动登录」开关——那个开关在任何实现里都做不了网站那一半的事。

## 内容

- `webview_cookies.dart`：新增 `CookieSummary`（只有 name / domain / 过期时间 / 标志，
  **不保存 value**）与 `forSite` / `all` / `clearSite` / `clearAll`；非 Android 返回空。
- 新增 `settings/presentation/login_state_page.dart`：站点 URL 输入、Cookie 列表
  （持久 / 会话区分）、清除该站、清除全部（均二次确认），页面内解释职责边界。
- `settings_page.dart` 网络段加「登录态管理」入口。
- `test/webview_cookies_test.dart`：持久 / 过期 / 会话三种判定。

## 结果

- `flutter analyze` 干净；新增测试 2 例通过。
- 真机待验：Android `CookieManager.getAllCookies()` 是否能拿到域名与过期时间
  （依赖 `WebViewFeature.GET_COOKIE_INFO`，拿不到时界面显示「域名未知」）。
