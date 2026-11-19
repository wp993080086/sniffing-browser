> 记录路径：.agents/logs/plans/20261112/custom-home-search-engines.md

# 自写 Flutter 首页 + 百度/bing 搜索引擎切换

- 日期：2026-11-12
- 任务：用户拍板三项（Flutter 起始页 / 地址栏下拉全局生效 / 默认百度），实现自写首页与双引擎切换。
- 假设：
  - `SNIFF_HOME_URL` 保留，设了就跳过自写首页、直接加载该 URL（沿用上轮说明）。
  - 首页不另做引擎 UI，共用地址栏状态；不提供独立「返回首页」按钮，地址栏空输入回车即回首页。
  - 首页不发网络请求，启动时 sniff 计数器为 0 属正常。
- 内容：
  1. `app_constants.dart`：`defaultHomeUrl` 改为可空 `startupUrl`（只读环境变量），删 `_fallbackHomeUrl`。
  2. `browser_provider.dart`：加 `SearchEngine` 枚举（默认百度）、`isHomePage`、`setSearchEngine`；`normalizeInput` 按引擎拼搜索 URL，两处重复合并为 `_searchUrl`；空输入返回空串，`navigate` 空串时回首页。
  3. `webview_host.dart`：`initialUrlRequest` 仅在 `startupUrl` 非空时给，否则 null。`onWebViewCreated` 的 attach / CDP 安装不动。
  4. 新增 `home_page.dart`：纯 Flutter 起始页（标题 + 搜索框 + 当前引擎提示），提交走 `navigate`。
  5. `browser_page.dart`：body 用 Stack，`WebViewHost` 常驻，用 `Consumer` 精确订阅 `isHomePage` 叠加不透明覆盖层。
  6. `address_bar.dart`：地址栏加引擎下拉，读 `searchEngine`、调 `setSearchEngine`。
  7. `docs/tech-design.md` 8.0：A1 改为「首页显示 + 首次导航后 loadStop > 0」，补「首页不发请求、A2 需打开网页后读计数器」。
  8. 新增 `test/browser_provider_test.dart`：覆盖空输入、URL 原样、域名补 https、两个引擎的搜索 URL。
  9. 验证：`flutter analyze`、`flutter test`、`flutter build apk --debug`；写 changes / reviews 与工作区记忆。
- 边界：不动嗅探 / 下载 / 转码链路、不动 `MainActivity.kt`、不改 README 实测记录、不引新依赖、不启动移动端原生能力。
- 结果：已完成。全量 `flutter test` 52 通过 / 8 个 e2e 按预期跳过（新用例 7/7）、`flutter analyze` 全库无问题、`flutter build apk --debug` EXIT=0（1m17s）、`pubspec.lock` 未变。待办：用户在 Windows / Android 各 F5 验运行时行为。
