> 记录路径：.agents/logs/plans/20261112/block-app-scheme-navigation.md

# 拦截移动端自定义协议跳转，修复 B 站页面 ERR_UNKNOWN_URL_SCHEME

- 日期：2026-11-12
- 任务：让 B 站等含唤起 App 跳转的页面能在 Android WebView 里正常显示
- 内容：
  - 根因：`webview_host.dart` 未接 `shouldOverrideUrlLoading`，`useShouldOverrideUrlLoading` 默认 false；站点跳 `bilibili://` / `intent://` 时 WebView 报 `ERR_UNKNOWN_URL_SCHEME`，整页变错误页
  - 步骤 1：`InAppWebViewSettings` 加 `useShouldOverrideUrlLoading: !_useCdp`（仅移动端，Windows 不动，避免改动 `onLoadStart` 触发路径影响 CDP 嗅探）
  - 步骤 2：加 `shouldOverrideUrlLoading` 回调，非 http/https 返回 `CANCEL` 并记 warn，其余显式返回 `ALLOW`
  - 步骤 3：同步 `docs/tech-design.md` 2.2 表格与 8.0 异常行为
  - 步骤 4：`dart analyze` / `flutter test` / `flutter build apk --debug` 回归
- 约束：不碰 Windows 导航链路、不设 UA、不改原生工程、不扩大到导出 / FFmpeg
- 结果：已完成。`dart analyze` 无问题、`flutter test` 52 通过 / 8 跳过、`flutter build apk --debug` EXIT=0（48s）；文档已同步；待用户模拟器实测运行时效果
