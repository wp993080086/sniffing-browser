> 记录路径：.agents/logs/plans/20261123/hls-file-name-with-page-title.md

# HLS 下载文件名带来源页标题

- 日期：2026-11-23
- 任务：点 `playlist.m3u8` 下载时，文件名变成 `playlist_页面标题.m3u8`

- 内容：
  1. 用户已确认：「页面名」取网页标题（`<title>`），生效范围仅 HLS/m3u8。
  2. 时序勘验：`onLoadStart` 时标题是上一页的，`m3u8` 常在 `onLoadStop` 前就被 capture，
     所以不能在嗅探那一刻取标题。改在**下载时**取 `tabManagerProvider.title`
     （此时 `handleLoadStop` 已跑完 `getTitle()`；且换页会清空嗅探列表，当前页即来源页）。
  3. `DownloadQueue.enqueue` / `_createTask` 加可选 `pageTitle`；新增纯函数
     `fileNameWithPageTitle`，仅 `MediaType.hls` 且标题非空时拼 `base_标题.ext`，
     走 `StoragePaths.sanitizeFileName` 清洗非法字符与 120 字上限。
  4. `ResourceTile` 下载按钮传当前页标题；抖音解析等其它入队点不传，行为不变。
  5. 补纯函数单测：空标题、非法字符、超长截断、非 HLS 不受影响。

- 结果：`flutter analyze` 无问题；新增 5 个用例全部通过。
