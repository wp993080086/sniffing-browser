> 记录路径：.agents/logs/plans/20261123/code-review-fixes.md

# 代码质量审查与逐项修复

- 日期：2026-11-23
- 任务：审查逻辑合理性、重复、目录分布、注释、README/rules 时效性，并逐项解决
- 内容：
  - A 类真实缺陷（优先修）：
    1. TranscodeBridge 后台线程缺 try/catch，异常时 Dart 端永久 await
    2. DASH 音轨索引硬编码 `track == 1`，纯音轨 MPD 误判
    3. HLS/DASH 分片 `.part` 非原子写入，崩溃后截断分片被当成完整分片
    4. 分片并发下限无代码兜底，0/负数会让 `Future.wait([])` 空跑
    5. 403 诊断 hint 是共享实例字段，并发任务串味
    6. transcode 入队去重吞掉新的 onFinished 回调
    7. Cookie 层异常全部静默吞掉，无日志
    8. DownloadQueue.retry 不清 `_pairRejected`，重试后无法重新配对
    9. 通知栏只统计 running，等待网络时显示 0 项
    10. StorageManager 注入 temp 目录时 keep 路径不一致；dispose 丢最后一次落盘
  - B 类重复：HLS/DASH/单文件三份进度采样、状态谓词手工重写、静默删除工具四份
  - C 类目录：大搬动（system_ffmpeg_engine 下沉、DownloadQueue 拆分）代价高且收益不明确，
    本次不改代码，在 rules 04 登记现状与取舍理由
  - D 类注释：修正 4 处与实现相反的注释
  - E 类文档：README 未实现清单、rules 01/04、tech-design 第 7 章按代码校准
- 结果：A 类修 9 项（dispose 补写尝试因 Windows 文件锁竞争回退并记录为限制）；
  B 类收敛三份速度采样；C 类不动代码、在 rules/04 登记取舍；D 类修 5 处注释；
  E 类校准 README、rules/01、rules/04、tech-design 第 7 章。
  `flutter analyze` 无问题、全量测试 257 通过 / 9 跳过 / 0 失败、Kotlin 编译通过。
  详见 `.agents/logs/reviews/20261123/code-quality-review.md`。
