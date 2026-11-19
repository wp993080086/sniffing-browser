> 记录路径：.agents/logs/reviews/20261112/block-app-scheme-navigation.md

# 复核：自定义协议跳转拦截

- 日期：2026-11-12
- 任务：审查本轮改动是否最小、是否会影响已验收链路
- 内容：
  - 根因成立：插件 `InAppWebViewClient.java:74-105` 在 `useShouldOverrideUrlLoading=false` 时 `return false`，URL 交还 WebView；错误页文案不在项目代码内，是系统 WebView 自带
  - 关键坑已规避：`WebViewChannelDelegate.java:975` 的 `decodeResult(null)` 返回 `CANCEL`，故回调必须显式 `ALLOW`，否则会拦掉所有导航；代码已按此写
  - Windows 保持不启用：插件 Windows `in_app_webview.cpp:509` 明示该开关会改变 `onLoadStart` / `onProgressChanged` 触发路径，而 `onLoadStart` 是 `sniffer.clear()` 与 `setCurrentPage` 的触发点，动了会波及 CDP 嗅探与 W1 基线
  - 开启后 Android 主框架导航会经 Dart 决策、由插件 `loadUrl` 重新发起（`InAppWebViewClient.java:117-127`），属插件标准行为；官方注明首次加载与 POST 不触发该回调，本项目导航均为 GET，可接受
  - 格式核对：把文件复制到临时文件跑 `dart format` 后 diff，差异全部落在既有代码（`_nudgeAutoplay`、logWarn 字符串拼接、`onPermissionRequest`），本轮新增行无差异，故未格式化周边代码
  - 残余风险：静态分析与构建只能证明可编译，拦截是否让 B 站页面真正停留、重定向是否多发请求，需真机 / 模拟器实测
- 结果：通过。待办：用户 F5 后打开 B 站页面确认，并在诊断页「只看问题」里核对 `拦截非网页协议跳转` 日志；若 Windows exe 上也出现同类报错，另行评估是否扩展开关
