> 记录路径：.agents/logs/plans/20261124/forbidden-retry.md

# 403 自动重试方案与落地

- 日期：2026-11-24
- 任务：确认 403 无自动重试的原因，并按用户选择实现有限轮次重试。
- 内容：
  - 排查：403 是 `badResponse`，`_isNetworkFailure` 判为 false，队列直接
    rethrow → fail；IO 层只有每套请求头 3 次线性退避 + 两套换头，界面无感知。
  - 方案：403 单独给 3 轮任务级重试（3 / 10 / 20 秒），每轮重新取 Cookie；
    等待状态复用 `waitingNetwork`，用 `retryReason` 区分文案。
  - 验证：单元 / 组件测试 + 全量测试 + 两端打包。
- 结果：已完成。详见 `.agents/logs/changes/20261124/forbidden-retry.md`。
