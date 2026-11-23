> 记录路径：.agents/logs/reviews/20261123/code-quality-review.md

# 代码质量审查：逻辑 / 重复 / 目录 / 注释 / 文档

- 日期：2026-11-23
- 任务：用户要求逐项检查逻辑实现是否合理、重复是否多、目录与函数分布是否合理、
  注释是否清晰、README 与 rules 是否落伍，并逐项解决
- 内容：

## A. 逻辑实现

审查发现 15 项，其中真实缺陷已修 9 项：

| 问题 | 处理 |
|---|---|
| `TranscodeBridge.kt` 后台线程无 try/catch，异常时 Dart 永久 await、队列卡死 | 已修：兜底回复 failed；取消落在 probe 前直接返回；去掉全局 `FFmpegKit.cancel()` 避免误杀 |
| DASH 音轨索引写死 `track == 1`，纯音轨 MPD 误判 | 已修：显式算 `audioTrack`；纯音轨失败按整单失败处理 |
| HLS/DASH 分片与 init 直接写 `.part`，崩溃后截断分片被当完整分片合并 | 已修：新增 `segment_writer.dart`，先写 `.writing` 再 rename |
| 分片并发下限只有注释，0 会让 `Future.wait([])` 空跑 | 已修：两个下载器都 clamp 到 ≥1 |
| 403 诊断 hint 是共享实例字段，并发任务串味 | 已修：改为函数返回值逐层传递 |
| 转码入队去重吞掉新的 `onFinished` | 已修：`TranscodeJob` 支持多个收尾回调 |
| Cookie 层 5 处异常无日志 | 已修：全部补 `logWarn`，不抛给 UI |
| `retry()` 不清 `_pairRejected`，重试后无法重新配对 | 已修 |
| 通知栏只统计 running，等待网络时显示 0 项 | 已修：纳入 waitingNetwork / paused |
| `StorageManager` 注入 temp 目录时 keep 路径走全局目录 | 已修：用注入的 `_temp` 拼路径 |
| dispose 丢 300ms 防抖窗口的最后一次状态 | **回退尝试**：补写引入 Windows 文件锁竞争，测试 teardown 失败；收益不足以牺牲稳定性，记录为已知限制 |

未修但有结论：
- `system_ffmpeg_engine.dart`「非 0 退出码但产物有效算成功」注释与代码不符——
  不改行为（区分坏帧与半截文件要再跑 ffprobe，代价大于收益），改注释如实说明。
- `cancelTranscode` 忽略 Dart 传的 jobId——串行模型下按当前 session 取消是正确行为，
  已在注释写明；不再调全局 cancel。
- 未结束任务的临时目录永久保留——是续传设计，不是缺陷。

## B. 重复代码

| 问题 | 处理 |
|---|---|
| HLS/DASH/单文件三份几乎逐字相同的速度采样 | 已修：抽 `_SpeedSampler`，单文件 500ms 窗口、流媒体 1s + 首帧基线 |
| 状态谓词在 activeCount / pauseAll 手写 | 未改：三处语义不同（含 pending 与否），强行复用要新增谓词，收益小 |
| 静默删除、大小写不敏感头查找、文件名拆解等轻微重复 | 未改：各 3~4 行、跨模块耦合，收敛会扩大改动面 |

## C. 目录与函数分布

大搬动（system_ffmpeg_engine 下沉 core、DownloadQueue 拆分）代价高、收益不明确，
本次不动代码；在 `rules/04` 登记三条已确认的取舍及理由，避免下次审查重复讨论。

## D. 注释

已修 5 处与实现相反或重复的注释：桌面转码「非 0 退出码」、HLS/DASH 的 `bytes` 语义、
DASH 清理失败后果、`tempDirFor` 漏 DASH、HLS `_prepareSegment` 重复段落。

## E. 文档时效

已校准：
- `README.md`：开头补 DASH/存储管理；「两套 E2E」改三条；四个 MethodChannel 表格；
  未实现清单删掉已落地的 Android 回退与 DASH；更新 B 站/YouTube 缺口表述；目录树补 settings。
- `rules/01`：删掉「DASH 不做 MPD 重组」，补能力边界；校准文档日期自相矛盾。
- `rules/04`：按实际目录重写（core 文件、dash、library、settings、四个 Kotlin 文件、
  4 个 channel、verify_download 驱动方式），登记 C 类取舍。
- `docs/tech-design.md` 第 7 章：包名 `com/wp/sniffing_browser`、4 个 channel、
  library 页已存在、`verify_download` 不能 `dart run`、测试文件列举与目录树更新。

- 结果：`flutter analyze` 无问题；全量 `flutter test` 257 通过 / 9 跳过 / 0 失败；
  `:app:compileReleaseKotlin` 成功。未提交、未推送。
