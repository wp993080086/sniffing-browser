> 记录路径：.agents/logs/plans/20261112/download-persistence.md

# 下载记录持久化：先定存储位置

- 日期：2026-11-12
- 任务：用户问「可以存应用内存里，或者是应用缓存里」，需要先判定落盘位置，再实现。
- 背景：上一轮加了「转换」页与转换任务落盘，下载队列仍是纯内存，重启即清空。
- 方案对比：
  | 位置 | 能否跨重启 | 风险 | 结论 |
  | --- | --- | --- | --- |
  | 内存（现状 `List<DownloadTask>`） | 否 | 进程被杀即丢 | 不选 |
  | `getCacheDir()` / `cache` | 能，但不保证 | 系统空间紧张时静默清理、用户可一键清缓存、部分 ROM 24h 后清 | 不选 |
  | `StoragePaths.root`（私有 files） | 是 | 只有卸载 / 用户手动清数据才会消失 | **选它** |
- 落盘内容取舍：存任务身份与终态（URL、headers、配对关系、产物路径、状态），
  **不存进度百分比**——每秒变几次，写盘无意义还磨损闪存，恢复后从 0 开始。
- 恢复语义设计：与转换队列刻意不一致。
  - 转换任务 `pending` 自动续跑（本地文件，一定还能跑）。
  - 下载任务未完成的一律标「已中断，可重试」且不自动跑：地址多为签名 URL，会过期；
    移动网络下自动开跑是坏体验。
  - `completed` 额外 stat 产物，文件没了就标失败，避免「显示完成但导不出来」。
- 实施步骤：
  1. `download_store.dart`：JSON 读写，字段对齐 `DownloadTask`，原子写，上限 200 条。
  2. `download_queue.dart`：加 store、`restore()`、300ms 防抖落盘、各状态迁移点埋线。
  3. `providers.dart` / `app.dart`：生产侧接上 store 并在启动时 restore。
  4. 测试：round-trip、坏数据容错、上限、四种恢复分支、restore 幂等、写回磁盘。
  5. 文档 / 规则 / 日志同步；analyze + test + build 验证。
- 结果：见 `.agents/logs/changes/20261112/download-persistence.md`。
