> 记录路径：.agents/logs/changes/20261113/home-history-bookmarks.md

# 首页历史记录 / 收藏夹入口与对应页面

- 日期：2026-11-13
- 任务：首页输入栏下方增加「历史记录」「收藏夹」两个入口，并实现两个页面。

## 内容

**新增**

- `browser/domain/history_entry.dart`、`bookmark_entry.dart`：两个条目模型。
  历史存「地址 + 标题 + 访问时间」，收藏存「地址 + 标题 + 收藏时间」。
- `browser/data/history_store.dart`、`bookmark_store.dart`：JSON 落盘，各一个文件
  （`history.json` / `bookmarks.json`），单条解析失败只跳过该条。
- `browser/data/history_service.dart`：`record` / `remove` / `clear` / `restore` / `flush`。
  - 同地址去重：再次访问移除旧记录、插到最前，标题取最近一次；
  - 上限 500 条，超出丢最旧；只收 `http/https`；
  - 300ms 防抖落盘，`flush()` 给测试和退出前用。
- `browser/data/bookmark_service.dart`：`toggle` / `contains` / `remove` / `clear`，
  上限 300 条，按加入时间倒序。
- `core/utils/json_file.dart`：两个 store 共用的「读 JSON + 临时文件 rename 原子写」。
- `browser/presentation/history_page.dart`：按天分组（今天 / 昨天 / 月日），
  单条删除、清空（带确认），点条目导航并在当前页签打开。
- `browser/presentation/bookmark_page.dart`：按加入时间倒序，单条取消、清空。
- `browser/presentation/empty_hint.dart`：两页共用的空态。

**改**

- `home_page.dart`：输入框下方一行「历史记录 / 收藏夹」，`TextButton.icon` 压到 34 高。
- `address_bar.dart`：刷新按钮左侧加星标，已收藏时图标变主题色并弹 1 秒 SnackBar。
  放这里而不是顶栏第二层：第二层已有引擎、页签、下载、诊断，320 宽再加会溢出，
  地址栏是 `Expanded`，吞得下这一个图标。
- `providers.dart`：注册 `historyProvider` / `bookmarkProvider`。
- `app.dart`：`initState` 里 `restore()` 两个新 store。
- `webview_host.dart`：`onLoadStop` 里在 `_tabs.handleLoadStop` 之后记一条历史。

**取舍**

- 记录点放在 `onLoadStop` 而不是地址栏提交：提交只是意图，重定向、失败页、
  被 `shouldOverrideUrlLoading` 拦下的自定义协议都会产生假记录。
- 清历史不影响收藏：两套数据各存一份，语义不同不该互相牵连。
- 历史 / 收藏都不持久化「当前滚动位置」和「页签」——历史是地址簿，不是会话快照。
- 落盘失败只记 warn 不抛：记录丢失不影响浏览，把异常冒到 zone 反而会打断启动。

## 验证

- `flutter analyze`：No issues
- `flutter test`：**142 通过 / 8 个 e2e 跳过**（新增 `history_service_test` 8 条、
  `bookmark_service_test` 6 条、`home_page_test` 5 条）
- `flutter build apk --debug`：EXIT=0，12.8s

## 待真机确认

- 打开几个网页后按返回键回到首页，历史页是否按天分组、条数与实际访问一致；
- 地址栏星标点击后图标变主题色，杀进程重进仍是实心；
- 历史页点条目是否在当前页签打开（不是新页签）。
