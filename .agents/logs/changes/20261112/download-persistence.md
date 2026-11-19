> 记录路径：.agents/logs/changes/20261112/download-persistence.md

# 下载记录持久化

- 日期：2026-11-12
- 任务：让下载记录跨重启保留，并回答「存内存还是存缓存」这个问题。
- 存储位置结论（关键）：
  - **不放内存**：`List<DownloadTask>` 是进程内状态，应用一被杀就没了，谈不上持久化。
  - **不放 cache 目录**：Android 的 `cache` 会在存储紧张时被系统静默清掉，用户也能在
    设置里一键「清除缓存」。写在那里等于没持久化，而且失效时机不可控。
  - **放私有 files 目录**：`StoragePaths.root`（Android 是
    `Android/data/<包名>/files/SniffingBrowser`，桌面是用户下载目录下的
    `SniffingBrowser`），和 `transcode_jobs.json` 同级，文件名为 `download_tasks.json`。
  - 下载产物本来就落在 `root/downloads`，HLS 临时分片在 `root/tmp/<taskId>`——都在
    files 下，不受 cache 回收影响，这正好是断点续传需要的前提。
- 新增文件：
  - `lib/features/downloader/data/download_store.dart`：`download_tasks.json` 读写。
    存全部任务字段（url / headers / type / pairedTaskId / isCompanion / mergedAudio /
    savedPath / container / needsRemux / exportStatus 等），**不存进度百分比**。
    临时文件 + rename 原子写；单条解析失败只跳过该条；上限 200 条。
    恢复时走 `setStatus()` 而不是直接改字段，否则界面读的 `statusNotifier` 会停在 pending。
  - `test/download_store_test.dart`：10 例（round-trip 含配对/合并/导出结论、空文件、
    坏 JSON、坏单条、超上限截断、产物在/不在的两种恢复、未完成一律标可重试且不自动跑、
    取消与失败原样保留、restore 幂等、恢复后的状态写回磁盘）。
- 修改文件：
  - `lib/features/downloader/data/download_queue.dart`：构造参数加 `DownloadStore? store`；
    新增 `restore()`、`_schedulePersist()`（300ms 防抖）。落盘点：入队、开始运行、
    终态、取消、重试、移除、清空、导出结果、DASH 合并回调。
  - `lib/app/providers.dart`：`DownloadQueue(store: DownloadStore())`。
  - `lib/app/app.dart`：`initState` 里一并 `restore()` 下载队列。
  - `docs/tech-design.md`：0 章已落地/未落地、5.6 并发与持久化、5.7 补下载侧差异、
    7 章目录与测试清单、8.0 新增 B10/B11、异常行为表「App 重启」、风险表。
  - `README.md`：模块表新增一行、未实现清单移出「下载队列持久化」、补「单文件字节级续传」。
  - `.agents/rules/01`、`02`、`04`：状态、文件落点补「记录不写 cache」、目录结构。
- 恢复语义（与转换队列刻意不同）：
  - `completed`：stat 一次产物，文件还在就保持完成；被清掉了标失败「文件已被删除」，
    避免列表写着完成、点导出才发现是空的。
  - `pending` / `running` / `paused`：**一律标「应用重启，下载已中断，可重试」，不自动重跑**。
    下载地址（m3u8 / m4s）多半带签名，隔一段时间就过期，自动跑只会刷一屏 403，
    移动网络下更是白耗流量。转换队列能自动续跑是因为它只用本地文件。
  - 用户点重试时 task id 不变，`tmp/<taskId>/seg_*.part` 还在，所以 HLS 是真的分片级续传。
- 结果：`flutter analyze` No issues；`flutter test` **85 通过 / 8 e2e 跳过**；
  `flutter build apk --debug` EXIT=0。
- 边界：单文件下载仍无字节级续传（`.part` 由 dio `deleteOnError` 清掉，重下）；
  恢复出来的两条 DASH 轨若都已下完但从没合并过，不会自动补一次合并，需要用户在
  转换页手动重试那条 `dashMerge` 任务（它自己也落盘了）。
