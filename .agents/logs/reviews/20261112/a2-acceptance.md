> 记录路径：.agents/logs/reviews/20261112/a2-acceptance.md

# A2 验收记录复核

- 日期：2026-11-12
- 任务：复核 A2 判定是否成立、记录是否越界。
- 内容：
  - 计数器含义核对：`webview_host.dart:278-286` 的 onLoadResource 在 url 非空时 bump；`:287-303` 的 shouldInterceptRequest 无条件 bump，随后缓存 headers、`_capture(url)`、返回 null 放行。85 / 83 均 > 0，A2 通过条件满足。
  - 两数不等不是故障：两个回调覆盖的请求集合本就不完全重合（缓存命中、重定向、WebView 内部请求等），差值 2 属正常。
  - 附带结论有依据：用户此前能正常浏览、点下载、看到已完成任务菜单，说明拦截回调未阻塞页面；但没有 `webview.loadStop` / `sniffer.captured` 数字，故未把 A1 / A3 标为通过。
  - 边界保持：8.0「A 用例未全绿前不启动移动端原生导出与 FFmpeg」未放宽，A2 通过不等于本期通过。
- 结果：通过。待办：补 A1 / A3~A6 判定依据与 A2 真机复验；之后再由用户决定是否放宽范围、启动移动端原生工作。
