> 记录路径：.agents/logs/reviews/20261112/default-home-baidu.md

# 默认首页改动复核

- 日期：2026-11-12
- 任务：复核改动是否精准、有无遗漏引用。
- 内容：
  - 逐行核对 diff：仅 1 行字符串常量替换，无周边改动、无格式调整。
  - 全库检索 `bing.com` 剩 4 处：`browser_provider.dart:42/50` 为地址栏搜索跳转（本轮有意不动）、`README.md:182` 与 `docs/tech-design.md:165` 为权限踩坑实测记录（不改，否则篡改历史事实）。
  - `defaultHomeUrl` 的 3 个引用点均自动生效，无需同步修改。
  - 分类器核对：`media_classifier.dart:51-52` 只过滤 `baidustatic.com/hm` / `hm.baidu.com` 统计埋点，不影响首页加载；但分类器按扩展名判定，百度首页图片多为无后缀 CDN URL，`sniffer.captured` 可能偏低，A3 应使用资源带后缀的测试页判定。
- 结果：通过。待办：用户确认搜索引擎是否一并换百度；A3 用例注意不要用默认首页当唯一依据。
