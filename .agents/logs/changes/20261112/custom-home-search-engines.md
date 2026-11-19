> 记录路径：.agents/logs/changes/20261112/custom-home-search-engines.md

# 自写 Flutter 首页 + 百度/Bing 切换

- 日期：2026-11-12
- 任务：按用户拍板的三项（Flutter 起始页 / 地址栏下拉全局生效 / 默认百度）实现自写首页与双引擎切换。
- 内容：
  - `lib/core/constants/app_constants.dart`：删 `_fallbackHomeUrl`，`defaultHomeUrl` 改为可空 `startupUrl`（只从 `SNIFF_HOME_URL` 取，未设置返回 null）。
  - `lib/features/browser/providers/browser_provider.dart`：新增 `SearchEngine` 枚举（百度默认 / Bing）、`isHomePage`、`searchEngine` getter、`setSearchEngine`；`normalizeInput` 按引擎拼搜索 URL、两处重复合并为 `_searchUrl`；空输入返回空串，`navigate` 空串时回首页。
  - `lib/features/browser/presentation/webview_host.dart`：`initialUrlRequest` 仅在 `startupUrl` 非空时给，否则 null；`onWebViewCreated` 的 attach / CDP 安装未动。
  - 新增 `home_page.dart`：纯 Flutter 起始页（标题 + 搜索框 + 当前引擎提示），提交走 `navigate`。
  - `browser_page.dart`：`ref.read` → `ref.watch`；body 改 Stack，`WebViewHost` 常驻、首页用 `Positioned.fill` 覆盖。
  - `address_bar.dart`：新增 `_EnginePicker` 下拉，读 `searchEngine`、调 `setSearchEngine`。
  - `docs/tech-design.md`：8.0 A1 改为「首页显示 + 首次导航后 loadStop > 0」，补「首页行为」说明；第 7 章目录补 `home_page.dart`、测试数 6→7。
  - `.agents/rules/04-目录结构.md`：browser/presentation 补 `home_page`。
  - 新增 `test/browser_provider_test.dart`：7 个用例覆盖空输入、URL 原样、域名补 https、两引擎搜索、首页状态流转。
- 结果：`flutter test` 全量 52 通过 / 8 个 e2e 按预期跳过，新用例 7/7；`flutter analyze` 全库 No issues found；`flutter build apk --debug` EXIT=0（1m17s）；新文件 dart format 0 changed；`pubspec.lock` 未变；文档围栏 56 个成对、章节 0~10 编号不变。
- 边界：未加独立「返回首页」按钮（地址栏空输入回车回首页）；未改 README 实测记录、未动嗅探 / 下载 / 转码链路、未引新依赖。运行时行为（两端首次导航）需用户 F5 验证。
