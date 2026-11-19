> 记录路径：.agents/logs/changes/20261112/default-home-baidu.md

# 默认首页改为百度

- 日期：2026-11-12
- 任务：把首次启动默认首页从 `https://www.bing.com` 改为 `https://www.baidu.com`。
- 内容：
  - `lib/core/constants/app_constants.dart` 仅改 `_fallbackHomeUrl` 一行；`defaultHomeUrl` getter 与 `SNIFF_HOME_URL` 覆盖机制未动。
  - `webview_host.dart:161` 的 `initialUrlRequest`、`browser_provider.dart:13/37` 的地址栏初值与空输入回退都读同一个 getter，自动生效。
  - 未改 `browser_provider.dart:42/50` 的 bing 搜索跳转（属搜索引擎，非首页）；未改 `README.md` / `docs/tech-design.md` 中作为权限踩坑实测记录的 `bing.com`。
- 结果：`dart analyze lib/core/constants/app_constants.dart` No issues found；`flutter build apk --debug` EXIT=0（1m35s）；`pubspec.lock` 未变；改动范围仅 1 文件 1 行。
- 待确认：地址栏搜索是否也改用百度；百度首页资源多无扩展名，A3 判定不能只依赖默认首页。
