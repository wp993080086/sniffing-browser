> 记录路径：.agents/logs/changes/20261112/block-app-scheme-navigation.md

# 拦截移动端自定义协议跳转

- 日期：2026-11-12
- 任务：修复 B 站等页面跳 `bilibili://` / `intent://` 时整页报 `ERR_UNKNOWN_URL_SCHEME`
- 内容：
  - `lib/features/browser/presentation/webview_host.dart`：settings 加 `useShouldOverrideUrlLoading: !_useCdp`；新增 `shouldOverrideUrlLoading` 回调，非 http/https 记 warn 并 `CANCEL`，其余显式 `ALLOW`
  - `docs/tech-design.md`：2.2 表格该行改为「仅移动端，拦截非 http 协议」；8.0 异常行为表新增一行
  - 未改：Windows 导航链路、UA、原生工程、导出 / FFmpeg 链路、测试文件
- 结果：`dart analyze` 改动文件与全库均 No issues；`flutter test` 52 通过 / 8 个 e2e 按预期跳过；`flutter build apk --debug` EXIT=0（48s）；文档围栏 56 个成对、章节编号未变；`pubspec.lock` 未变。待用户在模拟器重新 F5 验证运行时行为
