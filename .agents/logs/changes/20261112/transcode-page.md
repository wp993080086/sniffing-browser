> 记录路径：.agents/logs/changes/20261112/transcode-page.md

# 转换独立页面 + 任务持久化

- 日期：2026-11-12
- 任务：把「转换进度 / 任务列表」从下载项内的一行小字，提升为独立页面，并让任务可跨重启保留。
- 新增文件：
  - `lib/features/transcoder/presentation/transcode_page.dart`：任务列表页。
    每条显示源文件名、`kind.label · 状态/百分比`、进度条；菜单给取消 / 重试 / 移除记录；
    AppBar 有「清空已完成」。完成态优先显示 `exportMessage`（移动端落库目录），
    桌面退回显示产物文件名；合并任务显示「已合并到原视频文件」。
  - `lib/features/transcoder/data/transcode_store.dart`：`transcode_jobs.json` 读写。
    存 id / 源与产物路径 / kind / createdAt / 二路输入 / sourceTaskId / displayName /
    replaceSource / status / error / exportMessage / exported；**不存进度**。
    临时文件 + rename 原子写；单条解析失败只跳过该条；上限 100 条。
  - `test/transcode_store_test.dart`：8 例（round-trip、空文件、坏 JSON、坏单条、
    超上限截断、running 标中断 + pending 续跑、restore 幂等、移除/清空同步落盘）。
- 修改文件：
  - `lib/features/transcoder/data/transcode_queue.dart`：构造参数加 `TranscodeStore? store`；
    新增 `restore()`（running→failed「应用重启，转换已中断，可重试」、pending 重新排队、
    只执行一次）、`clearFinished()`、`activeCount`、`_schedulePersist()`（300ms 防抖）。
    入队 / 取消 / 重试 / 移除 / 开始运行 / 终态都触发落盘。
  - `lib/app/providers.dart`：`TranscodeQueue(store: TranscodeStore())`。
  - `lib/app/app.dart`：改为 `ConsumerStatefulWidget`，`initState` 里 `restore()`。
    放这里有原因：Provider 树在 runApp 之后才存在，也不能放 build（会反复读盘）。
  - `lib/features/downloader/presentation/download_page.dart`：AppBar 加「转换」入口，
    `Badge` 显示 `activeCount`。
  - `lib/features/downloader/presentation/download_tile.dart`：入队 SnackBar 加
    「查看进度」action，跨 await 前先抓住 `NavigatorState`。
  - `docs/tech-design.md`：0 章已落地 / 未落地、5.7 UI 交互重写 + 新增「任务持久化」、
    6 章 `TranscodeJob` 字段、7 章目录与测试清单、8.0 B8/B9、异常行为表「App 重启」行。
  - `README.md`：模块表 + 转换页说明 + 未实现清单（下载队列仍未持久化）。
  - `.agents/rules/01`、`04`：状态与目录、新增「界面职责」约定。
- 结果：`flutter analyze` No issues；`flutter test` **75 通过 / 8 e2e 跳过**；
  `flutter build apk --debug` EXIT=0（17.4s），APK 227MB。
- 边界：下载队列仍不持久化；`running` 任务无法断点续跑（FFmpeg 不支持），只能重试；
  恢复出来的 pending 任务从 0 进度重跑。
