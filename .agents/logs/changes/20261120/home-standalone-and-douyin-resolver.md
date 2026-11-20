> 记录路径：.agents/logs/changes/20261120/home-standalone-and-douyin-resolver.md

# 首页独立为常驻起始页 + 抖音视频解析

- 日期：2026-11-20
- 任务：
  1. 用户反馈「在首页输入网址就跳到网站了，首页好像不是 WebView，能不能把首页独立出来，不当一个窗口关掉」；
  2. 实现抖音视频下载，入口位置由开发者定。

## 一、首页改为常驻起始页

### 根因

起始页原本寄居在一个普通页签里：`TabManager` 构造时 `_create(activate: true)` 建一个空
页签，`BrowserPage` 在 `activeTab.page.isHomePage` 为真时盖一层 `HomePage`。

问题出在**第一次导航**：`navigate()` 直接对当前页签调 `page.navigate()`，
`_isHomePage` 变 false，起始页就随着这个页签一起变成网站了。之后想回首页只能
「新建页签」，而新建出来的又是一个普通页签，随时能被关掉。

另外用户看得很准：起始页确实不是 WebView —— 它是 Flutter 画的 `Stack` 覆盖层，
底下那个 WebView 加载的是 `about:blank`，纯属浪费一个实例。

### 改法

`BrowserTab` 增加 `pinned` 字段，起始页是 `_tabs[0]` 上那个不可关闭的页签。

- `TabManager` 构造：`_create(id: homeTabId, activate: true, pinned: true)`，
  常量 `homeTabId = 'home'`。
- `_ensureLive`：pinned 直接 return —— 起始页不建 WebView，也不进 `_live`。
- `closeTab`：pinned 直接忽略（`logInfo('起始页不可关闭')`）。
  `_tabs` 因此永不为空，原来「关空后自动补一个首页」的分支删掉，
  关光网页页签时 `next` 自然落到 `_tabs[0]`（起始页）。
- `navigate`：停在起始页时**新建页签**再加载，起始页留在原地。
  `BrowserController.normalize` 改成 static，`TabManager` 复用它做地址归一化。
- `createTab()` 不带地址 = 回起始页（`activateTab(homeTabId)`），
  不再复制第二个空白页签 —— 否则用户会看到两屏一模一样的内容，还分不清哪个关得掉。
- `createTab` 的上限判定排除 pinned（起始页不占名额）。
- `openInNewTab` 降级分支加保护：当前在起始页且页签已满时，不能
  `activeTab.page.navigate()`，那会把起始页就地变成网页。
- `AppConstants.startupUrl`（`SNIFF_HOME_URL`）语义保留：起始页之外再开一个网页页签。
- `tabCount` 改为**不含**起始页，顶栏显示的是真实网页窗口数；为 0 时不显示数字。
- 切换器：起始页仍以卡片出现（否则没有回首页的入口），但没有关闭键，
  标题显示应用名。

### 涉及文件

`lib/features/browser/providers/tab_manager.dart`、`browser_tab.dart`、
`browser_provider.dart`、`presentation/browser_page.dart`、`browser_header.dart`、
`tab_switcher.dart`。

## 二、抖音视频解析

### 为什么不走嗅探器

抖音网页版播放器是 DASH，`<video>` 的 `src` 为 `blob:`，真实地址不在 DOM 里。
但页面自己请求 `/aweme/v1/web/aweme/detail/` 时，响应里的
`video.play_addr.url_list[0]` 就是 `v3-web.douyinvod.com/...mime_type=video_mp4`
的**完整 mp4 直链**，支持 Range。

所以不做签名逆向，只读页面已经拿到的结果：注入 JS 拦截 `fetch` / `XMLHttpRequest`
的响应。签名（`a_bogus` / `msToken` / `verifyFp`）仍由页面自己生成，我们不管。

### 实现

- `lib/features/resolver/data/douyin_hook.dart`
  - `script`：三条通道并行 —— (1) `fetch`/`XHR` 响应里的 `/aweme/` JSON；
    (2) `_ROUTER_DATA` / `_SSR_HYDRATED_DATA` / `RENDER_DATA` / `__INITIAL_STATE__`
    全局变量的递归扫描（带节点预算，防大对象拖死页面）；
    (3) 页面对象遍历兜底。按 `aweme_id` 去重后经 `sb_douyin` 通道回传。
  - `rescan`：`onLoadStop` 后补扫一次，SSR 数据有时在 hydration 之后才挂上。
  - `extractUrl`：从整段分享文案里挑链接。只认抖音域名 —— 粘 B 站链接进来
    也提取得出 URL，但后面必然失败，不如当场判掉让界面直说。
  - `awemeId` / `shareUrl`：分享页降级用。
- `lib/features/resolver/domain/resolved_video.dart`：结果模型。
  `fromJson` 对字段缺失/类型不一致一律退回默认值；`fileName` 走
  `StoragePaths.sanitizeFileName`（作者 + 标题）。
- `lib/features/resolver/presentation/video_resolver_page.dart`：
  - WebView **可见**，不藏 Offstage：抖音详情接口有时要求登录或弹验证，
    用户能直接在上面操作。
  - 注入用 `UserScriptInjectionTime.AT_DOCUMENT_START`。`onLoadStop` 才注入的话，
    首屏那次详情请求已经发出去了，hook 装不上。
  - 状态条与 WebView 上下排（`Column`），不叠放：Android 的 platform view 会盖在
    Flutter 图层上面，`Stack` 里的提示文字会被页面遮掉。
  - 降级：12 秒无果且有 `aweme_id` → 改加载
    `iesdouyin.com/share/video/{id}/`（`_shareTried` 防来回弹）；
    40 秒判失败，可重试。
  - 进入页面先读一次剪贴板，识别到抖音链接就自动填上。
  - 下载：构造 `MediaItem`（`MediaType.video`，带 `Referer: https://www.douyin.com/`，
    `contentLength` 用接口的 `data_size`）后 `queue.enqueue`，pop 回首页并提示。

### 入口位置

放**首页**（`_HomeAction(icon: Icons.movie_outlined, label: '视频解析')`），
不放设置页：解析是一次性动作，不是配置项；首页已有输入框 + 历史/收藏两个次级动作，
加第三个最自然。三个按钮改用 `Wrap`，320dp 宽不会溢出。

### 视频号为什么不做

结构性障碍，不是工程量问题：无网页播放页；`wxaurl.cn` 短链与会话绑定，离开微信失效；
私有 TLS（mmtls）+ AES-128 加密 HLS。市面上的工具全是 PC 端 MITM，依赖
「微信是另一个进程」这个前提，手机 App 做不到。README 与 tech-design 5.9 都已写明。

## 三、验证

- `flutter analyze`：无问题。
- `flutter test`：215 通过，9 skip（新增 `test/douyin_hook_test.dart` 13 例）。
- 既有测试随模型调整：`tab_manager_test.dart` 重写起始页相关用例，
  `tab_switcher_test.dart` / `browser_header_test.dart` 的页签计数断言改为不含起始页。
- `docs/tech-design.md`：新增 5.9（站内视频解析）、5.10（页签模型）。
- README：已实现表补两行，未实现补视频号与 DASH 平台，目录补 `resolver/`。

## 待办

- 真机验证抖音解析：短链 / 长链 / 需要登录的视频各来一次，
  确认 `play_addr` 直链能 206 续传。
- WebView 被检测出非浏览器环境时的表现（可能要调 UA）。
