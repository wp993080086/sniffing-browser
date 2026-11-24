> 记录路径：.agents/logs/changes/20261124/forbidden-retry.md

# 403 有限轮次自动重试

- 日期：2026-11-24
- 任务：用户反馈 403 后没有自动重试。核实结论：403 一直被归类为「站点拒绝」，
  只在 IO 层静默换头重试，不进任务级自动重试。按用户选择加 3 轮有限重试。
- 内容：
  - `file_downloader.dart`：`DownloadException` 新增 `forbidden`，从
    `cause` 取 `DioException.response.statusCode == 403`。
  - `download_queue.dart`：`_runWithNetworkRecovery` 区分网络与 403；
    403 最多重试 `_forbiddenRetries = 3` 轮，复用 3 / 10 / 20 秒节奏。
    每轮重新走 `_runOnce` → 下载入口会重新取 WebView Cookie，
    会话轮换 / 短暂限流造成的 403 能自愈。3 轮后仍失败照旧报错。
  - `download_task.dart`：新增 `retryReason`；`waitForNetwork` 可带原因，
    离开等待状态时与 `retryAt` 一起清空。
  - `download_tile.dart`：倒计时前缀按原因显示，403 为
    「站点拒绝访问，N 秒后自动重试」，不再说「等待网络」。
  - 文档：README 已知限制、tech-design 5.3 重试分层同步 403 策略。
  - 测试：新增 403 队列用例（3 轮等待 + 最终失败）、任务 `retryReason`
    清理断言、卡片 403 文案断言。
- 结果：
  - `flutter analyze` 干净；全量 `flutter test` 263 通过 / 9 跳过 / 0 失败。
  - `flutter build apk --release` 成功（170.2s，104.4MB）。
  - `flutter build windows --release` 成功（75.3s），`data/app.so` 已更新，
    bundle 内 ffmpeg 与许可证齐全。
  - 已知边界：签名过期 / IP 被封的 403 仍会失败（3 轮共约 33 秒后报错），
    这是预期；真机验证待用户侧执行。
