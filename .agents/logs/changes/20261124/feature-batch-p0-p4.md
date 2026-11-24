> 记录路径：.agents/logs/changes/20261124/feature-batch-p0-p4.md

# 五项功能：完成后动作 / 预览 / 批量管理 / 重启续传 / 轨选择

- 日期：2026-11-24
- 任务：按 P0~P4 顺序落地并逐项验证。

## 改动

| 项 | 文件 | 内容 |
|---|---|---|
| P0 | `settings/data/app_settings.dart`、`settings/presentation/settings_page.dart`、`downloader/data/download_queue.dart` | 新增 `AfterDownload`（不做事 / 导出 / 转 MP4 / 抽 MP3）；队列在任务落定与合并完成后按设置分派，`_afterDownloadApplied` 去重；不适用类型静默跳过 |
| P1 | `sniffer/presentation/media_preview_page.dart`（新增）、`resource_tile.dart`、`download_action.dart`（新增） | 点整行进预览：图片 `Image.network`（带嗅探头）、音视频交给 WebView 内置播放器、HLS/DASH 只展示元信息；下载动作抽成 `enqueueDownload` 共用 |
| P2 | `downloader/data/download_queue.dart`、`presentation/library_page.dart` | `deleteFiles(ids)` 只删私有根目录内的产物（越界不删、删不掉保留记录）；`transcodeFiles(ids)` 按类型挑 MP4/MP3；下载库长按多选、全选、批量删除/转码，单条菜单加「删除文件」 |
| P3 | `downloader/data/download_queue.dart`、`app_settings.dart`、`app/providers.dart` | `autoResume`（默认开）注入队列；`restore()` 把 pending/running/paused 重新排队并 `_pump()`；未注入时为 false，测试与旧调用点不联网 |
| P4 | `dash/mpd_models.dart`、`dash/mpd_parser.dart`、`dash/dash_downloader.dart`、`hls/m3u8_models.dart`、`hls/m3u8_parser.dart`、`hls/hls_downloader.dart`、`domain/track_option.dart`（新增）、`download_action.dart` | MPD 解析 `lang`、`listTracks` 枚举全部轨、`selectTracks` 支持按 id 指定（找不到退回最佳）；HLS 解析 `EXT-X-MEDIA` 字幕轨、`probe()` 一次给清晰度 + 字幕、`preferredVariantUri` 按选择下载；任务记录 `videoTrackId` / `audioTrackId` / `subtitleTrackId` / `subtitleTag`；下载前弹选择面板（多选项才弹），HLS 字幕落成同名 `.vtt` |

## 关键取舍

- 轨道选择只做「有多选项才弹」：探测失败或只有一条就直接下，选择不能成为下载前置条件。
- 字幕只支持 HLS（`EXT-X-MEDIA TYPE=SUBTITLES`）。DASH 的 text AdaptationSet 需要给 `DashDownloader` 的双轨模型加第三条轨，改动风险高于收益，本次不做。
- 字幕下载失败只记日志，不把已完成的视频判失败。
- 删除文件只在 `StoragePaths.root` 内生效，已导出的 MediaStore 副本不碰；删文件失败时保留记录。

## 验证

- `flutter analyze` 零 issue
- 新增测试：`download_finish_action_test.dart`（7 项）、`media_preview_test.dart`（3 项）、`track_selection_test.dart`（9 项）
- 受影响的既有测试：`dash_mpd_test` / `dash_merge_test` / `resource_tile_test` / `library_page_test` / `download_store_test` 全部通过
- 全量：`flutter test -j 1` → **282 通过 / 9 跳过 / 0 失败**（70 秒）
- 注意：默认并发跑全量时 `dash_merge_ffmpeg_test` 会因子进程抢资源超时（2 分钟），单并发或单文件跑 2 秒通过。以后跑全量建议加 `-j 1`。
