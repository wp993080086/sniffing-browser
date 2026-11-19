> 记录路径：.agents/logs/reviews/20261112/custom-home-search-engines.md

# 自写首页与双引擎复核

- 日期：2026-11-12
- 任务：复核新增逻辑是否贴合范围、是否引入回归。
- 内容：
  - 接线核对：`defaultHomeUrl` / `_fallbackHomeUrl` 全库零残留；`startupUrl` 仅被 BrowserController 初值与 WebViewHost 初始请求读取，两处值一致。
  - 首次导航风险已规避：选「WebView 常驻 + 覆盖层」而非条件创建，保证 `onWebViewCreated` 在启动时就执行 `browser.attach` 与 `_cdp.install`，`navigate` 不会因 `_web == null` 早返回而失效。
  - 首页不发网络请求：启动瞬间 `webview.loadStop` 与两个 sniff 计数器为 0 属正常，8.0 已写明 A1 / A2 须在首次导航后读数；昨日记录的 A2（85 / 83）结论仍成立，但读数时机变了。
  - 订阅粒度：`BrowserPage` 改用 `ref.watch` 会让整页重建，但 `WebViewHost` 为 const 且是 StatefulWidget，State 与 WebView 实例保留，不会重复创建。
  - 单测覆盖两引擎前缀、空输入、URL / 域名分支、首页状态流转；未测 widget 渲染与真实 WebView 导航（需设备）。
  - 遗留：`SNIFF_HOME_URL` 设置时跳过自写首页；未做独立返回首页按钮；README 功能表未同步（避免「验证状态」列产生歧义），功能说明以 8.0 为准。
- 结果：通过。待办：用户在 Windows 与 Android 各 F5 验一次启动首页、首次搜索跳转、引擎下拉切换。
