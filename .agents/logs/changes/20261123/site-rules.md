> 记录路径：.agents/logs/changes/20261123/site-rules.md

# 站点规则可配置化

- 日期：2026-11-23
- 任务：按域名配置 UA/Referer/额外请求头，替代硬编码特例。

## 内容

- 新增 `lib/features/settings/data/site_rule.dart`：
  - `SiteRule` 模型（domain/userAgent/referer/headers）+ JSON 往返；
  - `ruleMatches` 用「点号边界」后缀匹配，支持子域且不误伤 `evil-example.com`；
  - `applySiteRules` 按命中规则覆盖请求头，同名忽略大小写去重，无改动返回原实例。
- `AppSettings` 加 `siteRules`，落盘 settings.json（新任务现取，不重建队列）。
- `DownloadQueue` 加 `siteRules` 回调，在 `_createTask` 最后套用 —— 自动头/Referer
  兜底先生成，规则优先级最高。
- 新增 `site_rules_page.dart`（规则列表 + 编辑页），设置页「网络」区加入口。
- **刻意不做**：规则里不存 Cookie。Cookie 是登录凭证，明文落盘既会过期也不安全；
  登录态仍由 WebView 的 CookieManager 按请求 URL 现取。

## 结果

- `flutter analyze` 干净；`site_rule_test.dart` 6 例（匹配边界、覆盖顺序、
  空值不覆盖、序列化）+ `app_settings_test.dart` 4 例全过。
- 待真机：设置一个自定义头后确认 403 站点能下。
