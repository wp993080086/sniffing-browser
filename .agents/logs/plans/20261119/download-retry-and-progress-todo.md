> 记录路径：.agents/logs/plans/20261119/download-retry-and-progress-todo.md

# 下载待修问题清单

- 日期：2026-11-19
- 任务：记录用户反馈的三个下载相关问题，待下一轮统一修复（当前手机 App 正在下载，不动代码、不重装、不 force-stop）
- 内容：

## 1. 中途超时后点「重试」无效，重新从资源列表下载却能成功（本次新反馈，优先级最高）

现象：

- HLS 下到一半（206 片左右）弹出红色错误「连接超时，站点可能限制了这个地址」；
- 点卡片上的「重试」，仍报同一条错误，多次无效；
- 回到网页，在嗅探资源列表里重新点同一个 `video.m3u8` 下载，正常开始下。

代码定位（只读核对，未改动）：

- 文案来自 `lib/features/downloader/data/file_downloader.dart` 的 `_describeError`：
  `connectionTimeout` / `sendTimeout` / `receiveTimeout` / `transformTimeout` 统一映射成这句话；
- 连接超时阈值 `AppConstants.connectTimeout = 20s`，接收超时 `60s`（`file_downloader.dart:39-40`）；
- `DownloadQueue.retry(taskId)` 只重置状态（error / receivedBytes / segmentDone / progress / speed / mergedAudio），
  **复用原 `task.url` 与 `task.headers`，不重新取流**；
- 重新点下载走 `enqueue`，生成新 `task.id`（md5(mediaId + 微秒时间戳)）与新地址、新签名。

初步判断（待日志验证，未下结论）：

- 失败点不是 403 也不是 5xx，是「连不上」：目标 CDN 域名/节点对该 IP 进入冷却、或被 tun/VPN 路径丢包；
- 重试永远打同一个 host，所以必然复现；换新嗅探地址（可能落到另一个 CDN 子域、新签名）才绕开；
- 需要验证：失败那次与成功那次的 host 是否不同；重试时日志有无 `403 后第 2 套请求头`；是否伴随 DNS 失败。

可能的修复方向（待确认后再动手）：

- 重试时对 `connectionTimeout` 做**指数退避 + 换域名**（同 CDN 常有多个子域）；
- 或在重试失败后提示「该地址已失效，回页面重新嗅探」，并提供一键跳回来源页；
- 不改变「不自动重跑」的现有语义（签名易过期，自动跑只会刷 403）。

## 2. 分片进度只显示已完成数，不显示总数

- `DownloadTask.totalSegments` 是 `final`，`updateSegments(done, total)` 只写 `segmentDone`，不回写总数；
- `download_tile.dart:108-111` 因此永远走 `${task.segmentDone} 分片已下载` 分支，看不到「206/430」；
- 进度条百分比本身正确（`progress.value = done/total`）。

## 3. 删除下载记录不清理临时目录

- `StoragePaths.cleanTemp(taskId)` 已实现但**无任何调用点**；
- `DownloadQueue.remove(taskId)` 只从内存与持久化里移除任务，`tmp/<taskId>/` 残留分片会一直占空间；
- 注意别误删仍在续传中的任务目录。

- 结果：三条已全部修复，见 `.agents/logs/changes/20261119/download-retry-and-progress.md`。
  179 测试通过、release APK 已构建；安装时设备断开（`adb devices` 为空），待装。
