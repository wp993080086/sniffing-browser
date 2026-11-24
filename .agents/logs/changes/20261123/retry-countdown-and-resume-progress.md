> 记录路径：.agents/logs/changes/20261123/retry-countdown-and-resume-progress.md

# 失败重试体验：动态倒计时、熄屏续跑、进度无感

- 日期：2026-11-23
- 任务：修复重试倒计时静态、确认熄屏等待、消除重试后的进度跳变与假速度。
- 内容：
  - `download_task.dart`：`networkWaitSeconds` 改为 `DateTime? retryAt` 绝对死线，
    新增 `retryRemainingSeconds`（到点返回 0）；`waitForNetwork(Duration)` 写死线；
    `setStatus` 离开 waiting 时清空死线。
  - `download_queue.dart`：调用改传 `Duration`；`retry()` 不再重置
    `receivedBytes / segmentDone / progress`（`.part` 与分片目录本来就在，重试是续传，
    清零只会造成 0 → 断点的视觉跳变）；`_runFile` 速度采样补 `skipFirstFrame`。
  - `download_tile.dart`：等待网络改用 `_RetryCountdown`（1 秒定时器，只重建该行，
    按死线反算剩余秒）；失败状态进度条保留 `progress.value`，不再强制 0。
  - 测试：`download_task_test` 增 2 例（死线反算、过期不为负）；
    `download_tile_test` 增 2 例（倒计时文案 + 断点进度、失败保留进度）。
- 结果：
  - `flutter analyze`：No issues found。
  - 定向测试 20 例全过；全量 `flutter test` 261 通过 / 9 跳过 / 0 失败。
  - `flutter build apk --release` 成功（132.6s，104.4MB，仅 arm64-v8a / x86_64）。
    首次 release 构建在 Gradle 阶段卡死 1.5 小时无输出，停掉后 `gradlew --stop`
    重启守护进程，二次构建正常。
  - `flutter build windows --release` 成功（53.4s），`data/app.so` 已更新；
    bundle 内 `ffmpeg.exe` 与 GPLv3 许可证仍在。
  - 熄屏结论：等待网络时 `_start` 仍占并发槽，`_runningCount > 0`，
    前台服务与 `PARTIAL_WAKE_LOCK` 持续持有，`Future.delayed` 能到点重试；
    卡片倒计时按绝对死线算，亮屏回来不偏。进程被系统杀掉仍会中断（既有边界）。
  - 真机验证待用户侧执行：断网重试倒计时递减、熄屏后仍自动恢复、
    重试瞬间进度与速度是否平滑。
