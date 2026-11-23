> 记录路径：.agents/logs/changes/20261123/batch-resolver.md

# 批量解析下载

- 日期：2026-11-23
- 任务：解析页支持多条结果、多选、批量入队。

## 内容

- 新增 `lib/features/resolver/domain/resolved_batch.dart`：纯逻辑集合，负责
  去重（优先 videoId，无则 url）、默认全选、勾选/全选/清空。
- `video_resolver_page.dart`：
  - `_result` 单条 → `_batch` 多条；
  - 首条命中后开 2 秒收集窗口再切 done —— hook 本来就会逐条上报主页接口
    的十几条 aweme（JS 端已有 aweme_list 循环 + seen 去重），命中即切会全丢；
  - 结果页：单条仍是原大卡片（体验不退化），多条显示勾选列表 + 全选 +
    「下载选中的 N 个」；下载时循环入队，SnackBar 报条数。
- hook 脚本本身未改：它早就支持多条上报，缺的是 Dart 侧接住。

## 结果

- `flutter analyze` 干净；新增 `resolved_batch_test.dart` 4 例
  （去重、url 兜底、非法直链、勾选/全选）通过；`douyin_hook_test.dart` 13 例仍过。
- 待真机：主页链接的多条收集窗口是否够 2 秒。
