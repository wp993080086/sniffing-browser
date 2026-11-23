> 记录路径：.agents/logs/changes/20261123/code-review-fixes.md

# 代码审查后的逻辑修复与文档校准

- 日期：2026-11-23
- 任务：修复审查发现的真实缺陷、收敛重复代码、校准过期注释与文档
- 内容：
  - 新增 `lib/features/downloader/data/segment_writer.dart`：分片原子写入（`.writing` → rename）
  - `hls_downloader.dart` / `dash_downloader.dart`：改用原子写入；并发下限 clamp；DASH 音轨索引不再写死 1；修正注释
  - `file_downloader.dart`：403 诊断结论改为函数内传递，消除并发串味
  - `download_queue.dart`：抽 `_SpeedSampler` 统一三处速度采样；`retry()` 清 `_pairRejected`；通知栏纳入等待/暂停任务
  - `TranscodeBridge.kt`：后台线程异常兜底；取消不误杀其他会话；probe 前取消直接返回
  - `transcode_job.dart` / `transcode_queue.dart`：完成回调支持多个，去重入队不吞回调
  - `webview_cookies.dart`：异常补日志
  - `storage_manager.dart`：注入 temp 目录时 keep 路径一致；`storage_page.dart` 加并发清理提示
  - `storage_paths.dart`：`tempDirFor` 注释补 DASH
  - `system_ffmpeg_engine.dart`：修正与实现相反的注释
  - 新增测试：`segment_writer_test.dart`、`transcode_dedupe_test.dart`
  - 文档：README、rules/01、rules/04、tech-design 第 7 章
  - 审查记录：`.agents/logs/reviews/20261123/code-quality-review.md`
- 结果：`flutter analyze` 无问题；全量测试 257 通过 / 9 跳过 / 0 失败；Kotlin 编译通过。未提交。
