> 记录路径：.agents/logs/changes/20261123/hls-file-name-with-page-title.md

# HLS 下载文件名带来源页标题

- 日期：2026-11-23
- 任务：点 `playlist.m3u8` 下载时，文件名变成 `playlist_页面标题.m3u8`

- 内容：
  - `download_queue.dart`：新增 `DownloadQueue.fileNameWithPageTitle`（仅 HLS 且标题非空时
    拼 `base_标题.ext`，走 `StoragePaths.sanitizeFileName`）；`enqueue` / `_createTask`
    加可选 `pageTitle` 参数。
  - `resource_tile.dart`：下载按钮传 `ref.read(tabManagerProvider).title`。
  - 关键时序：标题在 `handleLoadStop` 的 `getTitle()` 之后才有，而 m3u8 常在
    `onLoadStart` 阶段就被 capture（那时标题还是上一页的），因此**不在嗅探时取标题**，
    改在下载时取；换页会清空嗅探列表，当前页即来源页。
  - 其它入队点（抖音解析、DASH 配对）不传 `pageTitle`，行为完全不变。
  - 新增 `test/hls_file_name_test.dart`：拼接、空标题、非法字符、超长截断、非 HLS 不受影响。

- 结果：`flutter analyze` 无问题；`flutter test` 238 通过 / 9 跳过 / 0 失败。未 commit。
