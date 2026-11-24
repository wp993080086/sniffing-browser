> 记录路径：.agents/logs/plans/20261123/retry-countdown-and-resume-progress.md

# 失败重试体验：动态倒计时、熄屏续跑、进度无感

- 日期：2026-11-23
- 任务：解决三个反馈 —— 重试倒计时不动态、熄屏后倒计时是否继续、重试后进度从 0 跳变且速度虚高。
- 内容：
  - 倒计时：任务记录绝对死线 `retryAt`，卡片用 1 秒定时器按死线反算剩余秒数，
    只重建倒计时那一行。死线用 `DateTime.now()` 而非递减计数，熄屏/后台被压后也不会偏。
  - 熄屏：确认等待期间 `_start` 仍占着并发槽，`_runningCount > 0` 使前台服务与
    `PARTIAL_WAKE_LOCK` 保持持有，`Future.delayed` 能照常到点；取消仍可打断等待。
  - 进度跳变：失败状态进度条不再强制归零；`retry()` 不再清 `receivedBytes` /
    `segmentDone` / `progress`（底层 `.part` 与分片目录本就保留）；单文件下载的
    速度采样补 `skipFirstFrame`，续传首帧只做基线，避免几百 MB/s 假速度。
- 结果：已落地并验证。analyze 干净，定向 20 例、全量 261 通过 / 9 跳过；
  release APK 与 Windows 绿包均重新构建，产物含本次改动。
  详见 `.agents/logs/changes/20261123/retry-countdown-and-resume-progress.md`。
