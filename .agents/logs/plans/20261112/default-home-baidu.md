> 记录路径：.agents/logs/plans/20261112/default-home-baidu.md

# 默认首页改为百度

- 日期：2026-11-12
- 任务：把首次启动的默认首页从 bing 改为百度。
- 假设：URL 用 `https://www.baidu.com`（标准 https 入口，符合 Android 9+ 明文限制）；`SNIFF_HOME_URL` 覆盖机制保持不变。
- 内容：
  1. 只改 `lib/core/constants/app_constants.dart` 的 `_fallbackHomeUrl` 一行。
  2. 核对 `defaultHomeUrl` 的引用点自动生效。
  3. 验证：`dart analyze`、`bing` 残留检索、Android debug 构建。
  4. 写 changes / reviews 日志与工作区记忆。
- 边界：`browser_provider.dart:42/50` 的地址栏搜索跳转仍指向 bing，属「搜索引擎」而非「默认首页」，本轮不动、回复中向用户确认；`docs/tech-design.md` 与 `README.md` 里的 `bing.com` 是权限踩坑实测记录，不改。
- 结果：已完成。`dart analyze` 无问题、`flutter build apk --debug` EXIT=0（1m35s）、改动仅 1 文件 1 行；地址栏搜索跳转保持 bing，待用户确认是否一并更换。
