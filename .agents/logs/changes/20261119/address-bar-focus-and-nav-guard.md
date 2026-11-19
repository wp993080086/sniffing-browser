> 记录路径：.agents/logs/changes/20261119/address-bar-focus-and-nav-guard.md

# 地址栏焦点、可疑跳转隔离、盾牌说明

- 日期：2026-11-19
- 任务：修「点网页键盘收不掉」；把「拦下可疑跳转」改成「隔离到后台页签」；给拦截开关补状态提示
- 内容：
  - 新增 `lib/features/browser/data/nav_guard.dart`：顶层导航判定从 `WebViewHost` 抽成纯逻辑，返回 `allow / isolate` 两态（非 http 协议仍由调用方 `CANCEL`）。判定依据是页面自报的真实点击，不是 `NavigationAction.hasGesture` —— Android 上「点搜索结果 → 脚本中转 → 跳转」的 `hasGesture` 为 false，只看它会把正常点击一起干掉。另外识别同站的弹窗中转页（`/pop?url=<外站>`），否则它按站内跳转被放行，当前页被顶成空壳。
  - `webview_host.dart`：
    - `_openTabPatch` 改名 `_pagePatch`，追加 capture 阶段 click 监听，写入 `window.__sbLastTap = href \t 时间戳` 并 `callHandler('sb_user_tap')`；
    - 新增 `_readPageTap`：导航前 `evaluateJavascript` 读该值喂给 `NavGuard.noteTap`，300ms 超时兜底（后台页签的 WebView 是挂起的，求值可能不返回）；
    - `_handleNavigation` 按 `NavGuard.decide` 分流，`isolate` 走新增的 `_isolate`：`TabManager.openInBackground` 建后台页签 + SnackBar「查看」，当前页不动；
    - `_isolate` 自我抑制：`BrowserTab.spawnedInBackground` 为真的隔离页不再派生，同 host 30 秒内只隔离一次，避免一次点击裂变十几个页签。
  - `address_bar.dart` / `browser_header.dart` / `browser_page.dart`：`_submit` 之外的入口也调 `FocusManager.instance.primaryFocus?.unfocus()`；网页区域的点击靠 `sb_user_tap` 回报（platform view 的点击 Flutter 收不到）。
  - 盾牌按钮（`_RedirectGuardButton`）点击后弹状态提示，「已开启 / 已关闭自动跳转拦截」。
  - `docs/tech-design.md`：插件能力表更正（`evaluateJavascript` / `addJavaScriptHandler` / `shouldOverrideUrlLoading` 的实际用途），8.0 增补「可疑跳转隔离」判定表与「地址栏焦点」。
- 结果：
  - `flutter analyze` 无问题；`flutter test` 164 通过 / 8 跳过（`nav_guard_test.dart` 12 条）。
  - `flutter build apk --release` 成功，已 `adb install -r` 上机。
  - 真机待验：点搜索结果能正常打开、点网页收起键盘、被隔离的跳转能在后台页签看到。
