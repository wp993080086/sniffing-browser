> 记录路径：.agents/logs/changes/20261123/dash-mpd-download.md

# DASH / MPD 分片重组下载

- 日期：2026-11-23
- 任务：让 `.mpd` 清单也能下载，而不只是嗅探到的完整 `.m4s` 分片。

## 内容

- `pubspec.yaml` 新增 `xml: ^6.5.0`（MPD 解析）；`petitparser` 作为传递依赖进入 lock。
- 新增 `lib/features/downloader/data/dash/`：
  - `mpd_models.dart`：`MpdManifest` / `MpdPeriod` / `MpdAdaptationSet` /
    `MpdRepresentation`，以及模板与 BaseURL 的继承模型；
  - `mpd_parser.dart`：命名空间无关的节点查找、多层 `BaseURL` 解析、
    `SegmentTemplate` 父层继承、ISO 8601 时长、`$Number$` / `$Time$` /
    `$RepresentationID$` / `$Bandwidth$` 展开、`selectTracks` 按带宽挑轨；
  - `dash_downloader.dart`：init 段 + 分片并发下载、`.part` 分片级续传、
    复用 `SegmentMerger` 拼接；音视频各出一个文件；音轨失败降级为无声视频。
- `download_queue.dart`：`_runOnce` 的 DASH 抛错分支替换为 `_runDash`；
  完成后排 `dashMerge`（复用现有 FFmpeg 合并命令，无 `-shortest`）覆盖回同一任务路径；
  `fileNameWithPageTitle` 扩展到 DASH，最终产物是 `manifest_页面名.mp4`。
- 明确拒绝三类：DRM、直播无界 timeline、`SegmentBase` 单文件封装；上限 20000 分片。

## 结果

- `flutter analyze` 干净；新增 `test/dash_mpd_test.dart` 7 例全过
  （选轨、timeline 展开、DRM 拒绝、时长解析、两轨落盘、队列合并排期、SegmentBase 拒绝）；
  `hls_file_name_test.dart` 增加 DASH 命名用例。
- 真机待验：实际站点的 MPD 是否都走 SegmentTemplate / SegmentList。
