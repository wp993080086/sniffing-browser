> 记录路径：.agents/logs/reviews/20261112/download-persistence.md

# Review：下载记录持久化

- 日期：2026-11-12
- 范围：`download_store.dart`（新增）、`download_queue.dart`、`providers.dart`、`app.dart`、
  `test/download_store_test.dart`（新增）、文档与规则。
- 核对项：
  - [x] 存储位置在私有 files 目录（`StoragePaths.root`），未写 cache，未写内存
  - [x] `pubspec.lock` 未变，未引入新依赖
  - [x] 字段覆盖完整：`pairedTaskId` / `isCompanion` / `mergedAudio` 都存了，
        否则 DASH 配对关系在重启后断链
  - [x] 恢复时走 `setStatus()`：界面读 `statusNotifier`，只改 `_status` 会让列表
        一直显示「等待中」
  - [x] `completed` 恢复设 `progress = 1`；被判「文件已被删除」时重置为 0，
        避免失败任务挂满进度条
  - [x] 落盘点齐全：入队 / 开始运行 / 终态 / 取消 / 重试 / 移除 / 清空 / 导出结果 /
        DASH 合并回调
  - [x] 300ms 防抖，`_persistScheduled` 在 `dispose` 后不再写
  - [x] 写盘走 `.tmp` + rename，单条坏数据只跳过该条
  - [x] `restore()` 幂等（`_restored` 标志），不会因为 build 重建而重复加载
- 发现并修掉的问题：
  1. 草稿里误留了一行无效变量声明（`final TaskMessage? _ = null`），已删。
  2. 「文件已被删除」分支原先没有重置进度，`completed` 解码时设的 1.0 会留在
     失败任务上，UI 会显示满进度条。已补 `task.progress.value = 0`。
- 刻意不做的：
  - 恢复后自动重跑未完成任务 —— 地址过期 + 移动流量，坏体验，见 changes 记录。
  - 恢复时补一次 DASH 配对合并。两条轨都下完但合并没跑完的极端情况，转换页里
    那条 `dashMerge` 任务本身也落了盘，用户点重试即可。
  - 不动 `FileDownloader` 的 `.part` 策略（dio `deleteOnError` 会清掉半截文件）。
- 格式：新增两个文件跑了 `dart format`；三个修改文件未格式化——比对后确认差异
  全部落在既有行（Dart 3.12 新格式器风格），按项目惯例不制造无关 diff。
- 验证：`flutter analyze` No issues；`flutter test` 85 通过 / 8 e2e 跳过；
  `flutter build apk --debug` EXIT=0。
- 待办（需真机）：B10（下载中杀 App 后不自动重跑、点重试走分片续传）、
  B11（产物被删后的失败提示）。
