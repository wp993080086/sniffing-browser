> 记录路径：.agents/logs/changes/20261113/multi-tab.md

# 多页签 + 返回手势拦截

- 日期：2026-11-13
- 任务：解决「返回手势直接退应用」与「点链接只会顶掉当前页」，加多页签与两栏卡片瀑布流切换器。

## 内容

**根因**

- 返回退应用：`BrowserPage` 没接 `PopScope`，系统返回直接 finish activity，WebView 的历史完全没用上。
- 没有多页签：`webview_host.dart` 全局只有一个 `InAppWebView`，且 `supportMultipleWindows: false`，
  站点的 `target=_blank` / `window.open` 被 WebView 当成当前页导航，所以点一条链接当前页就被顶掉。

**新增**

- `providers/browser_tab.dart`：一个页签 = 一个 `BrowserController` + 一个 `SnifferService` + `pendingUrl`。
- `providers/tab_manager.dart`：页签集合 / 活跃页签 / 存活 WebView 的 LRU / progress 转发 / `handleBack`。
  - `maxLive = 4`（同时存在的原生 WebView），`maxTabs = 20`；
  - 淘汰只回收 WebView，页签保留，`pendingUrl` 记住地址，切回时重建；
  - `IndexedStack` 子节点顺序按 `_live` 插入顺序，不按活跃时间重排（否则 key 对调、WebView 全重建）。
- `presentation/tab_switcher.dart`：底部 Modal + 两栏卡片瀑布流。
  - 卡片高度用 `TextPainter` 按标题 1~2 行实测，逐个放进较矮的一列；
  - 点卡片切换并关面板，点叉只关该页签，底部「新建」建首页页签。
- `browser_provider.dart`：加 `detach()`、`markExternal()`、`goBackIfPossible()`。

**改**

- `webview_host.dart`：接收 `BrowserTab`，回调全部走 `tab.sniffer` / `tabManagerProvider`；
  注册 `sb_open_tab` JS handler，`onLoadStop` 注入脚本接管 `a[target=_blank]`、`window.open`、Ctrl/Cmd 点击。
- `browser_page.dart`：`PopScope(canPop: false)` → 网页能后退就后退 → 否则 `SystemNavigator.pop()`；
  内容区改 `IndexedStack` 承载存活页签。
- `providers.dart`：删 `browserProvider`，加 `tabManagerProvider`；`snifferProvider` 改成普通
  `Provider` 返回 `activeSniffer`（不能由 provider 销毁，页签还活着）。
- `resource_panel.dart` / `sniff_fab.dart`：改用 `ListenableBuilder(listenable: activeSniffer)` 订阅刷新。
- `browser_header.dart`：第二层加页签入口（显示总数）；`address_bar` / `home_page` 改读 `tabManagerProvider`。

**取舍**

- 不用插件的 `onCreateWindow`：需要把 `windowId` 绑到新 WebView，而新 WebView 异步创建，时序难对齐，
  Windows 侧行为也不一致。注入脚本 + JS handler 完全可控，且不依赖平台实现。
- 页签不持久化：与嗅探结果、FAB 位置一致，杀掉应用回一个首页。
- 不引入瀑布流依赖：页签上限 20，两列 `Column` 手分列足够。

## 结果

- `flutter analyze`：No issues
- `flutter test`：**123 通过 / 8 e2e 跳过**（新增 `tab_manager_test.dart` 10 条、
  `tab_switcher_test.dart` 3 条；`browser_header_test` 补页签入口断言）
- `flutter build apk --debug`：EXIT=0，12.7s

**待真机验证**：多页签切换是否瞬时、非活跃页签的 WebView 会不会叠在当前页上
（`IndexedStack` + Android platform view 的已知风险，叠加的话改成每页签 `Offstage`）、
`target=_blank` 是否真的开新页签、返回手势的三级行为。
