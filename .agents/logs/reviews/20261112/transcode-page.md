> 记录路径：.agents/logs/reviews/20261112/transcode-page.md

# 复核：转换独立页 + 持久化

- 日期：2026-11-12
- 改动范围：3 个新文件（页面 / store / 测试）+ 6 个改文件（queue、providers、app、
  download_page、download_tile、文档）；Kotlin 与 `pubspec` 未动。

## 检查项

| 项 | 结论 |
| --- | --- |
| 是否影响既有下载链路 | 未动下载队列；下载页只加了 AppBar 入口，列表与菜单逻辑不变 |
| 桌面端行为 | 持久化与页面都跨平台；`transcode_jobs.json` 落在桌面 `下载/SniffingBrowser/` 下 |
| 持久化是否拖慢 UI | 落盘 300ms 防抖 + 异步写，不阻塞主线程；进度不触发写盘 |
| 写盘安全性 | 临时文件 + rename；单条坏数据只跳过该条；读取异常按空列表 |
| 重启语义 | running → failed（可重试），pending → 续跑；不会假装还在跑 |
| restore 幂等 | `_restored` 标记，重复调用直接返回（有测试） |
| 生命周期 | `_schedulePersist` 的延迟回调在 `_disposed` 后直接 return；队列仍由 ProviderScope 持有 |
| 测试稳定性 | 轮询等待终态（5s 上限），不依赖固定 sleep；落盘等待 400ms > 300ms 防抖窗口 |
| 依赖锁 | `pubspec.lock` 未变（新增文件只用 `dart:convert` / `dart:io` / `path`） |
| 格式 | 新文件按 Dart 3.12 格式器书写；`dart format` 无差异 |

## 结论

通过。`flutter analyze` No issues、`flutter test` 75 通过 / 8 跳过、
`flutter build apk --debug` EXIT=0（17.4s）。

## 残留

- 下载队列仍未持久化：转换任务能跨重启，但它关联的下载记录重启就没了，
  所以转换页的 `sourceTaskId` 在重启后指向不存在的下载项（页面不依赖它，无影响）。
- `running` 中断后不能断点续跑，只能整条重跑；FFmpeg 不支持中途续写，这个是硬限制。
- 转换页目前没有「打开产物」的动作。Android 上入库后是 `content://` URI，
  要做需要 `Intent.ACTION_VIEW` + FileProvider/媒体库授权，留待后续。
