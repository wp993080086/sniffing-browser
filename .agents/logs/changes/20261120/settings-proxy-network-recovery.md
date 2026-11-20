> 记录路径：.agents/logs/changes/20261120/settings-proxy-network-recovery.md

# 断网自动续传、设置页与代理、ABI 过滤修正

- 日期：2026-11-20
- 任务：按用户指定的六项顺序收尾 —— 推送、修两个失效配置、断网无限重试、卡片加「等待网络」、代理支持、设置页可调分片并发

## 1. 推送

`e9cfab6..c0c62fc` 已推到 `origin/main`。

## 2. 两个「看着有、实际没生效」的配置

- **ABI 过滤**：`defaultConfig.ndk.abiFilters` 确实不生效（`flutter build apk` 透传
  `-Ptarget-platform` 覆盖它）。改为 `packaging { jniLibs { excludes += "lib/armeabi-v7a/**", "lib/x86/**" } }`。
  实测：不带 `--target-platform` 构建，APK 内只剩 `lib/arm64-v8a/` 与 `lib/x86_64/`，
  `armeabi-v7a` 条目数为 0。32 位设备会在安装阶段报 `NO_MATCHING_ABIS`，
  不再出现「能装但一转码就崩」。
- **`tools/verify_download.dart`**：`dart run` 无法运行（下载链路 import
  `flutter/foundation`，`dart run` 没有 dart:ui）。脚本改成暴露 `Future<int> run({mode})`，
  新增 `test/download_real_e2e_test.dart` 借 `flutter test` 的运行环境，默认 skip，
  用 `SNIFF_E2E=1` 打开。`main(List<String>)` 签名与 flutter_test 的 listener 冲突，
  一并去掉。

## 3. 断网不再判死

第一版（当天早些时候）把 2 分钟等待表放在 `FileDownloader` 里，问题是不落成可见状态：进度冻住两分钟像卡死，超时后仍要人工点重试。

- `FileDownloader`：单次请求只做 0.5s / 1.5s 短退避；结论写进
  `DownloadException.network`（`_isNetworkFailure` 判定：超时 / 连接失败 /
  `unknown` 底下的 `SocketException` / `TlsException` / `HandshakeException`）。
- `DownloadQueue._runWithNetworkRecovery`：`network == true` 时任务转
  `waitingNetwork`，按 3 / 10 / 20 / 30 / 60 秒递增重试，第 4 次之后固定一分钟，
  **无总时长上限**。每轮重跑 `_runFile` / `_runHls`，靠 `.part` 与 `seg_*.part` 续传。
- 等待可被取消打断（`Future.any([delay, token.whenCancel])`）；`cancel()` 的条件从
  `running` 改为 `isRunningOrWaiting`，否则等待中取消要干等满一分钟。
- 站点类失败（403 / 404 / 5xx）不进这套逻辑，仍按 `retries` 快速失败。

## 4. 卡片上的「等待网络」

- `DownloadStatus` 增加 `waitingNetwork`（label `等待网络`），`DownloadTask.waitForNetwork()`
  同时把速度归零（否则卡片上挂着断网前最后一刻的 MB/s）。
- 卡片文案「等待网络，30 秒后自动重试」；进度条冻在原处而不是转不确定动画
  （转圈反而像在重下）；菜单里「取消」对这个状态可见。
- `activeCount` 把 `waitingNetwork` 算作进行中，顶栏角标与实际一致。

## 5. 代理

- 新增 `core/platform/proxy_rule.dart`：手动值优先，否则读 `https_proxy` /
  `HTTPS_PROXY` / `http_proxy` / `HTTP_PROXY` / `all_proxy` / `ALL_PROXY`；
  `no_proxy` 支持 `localhost` / `.corp.com` / `*`；`socks5://` 转 `SOCKS5 host:port`。
- `FileDownloader.createDio(proxy: ...)` 用 `IOHttpClientAdapter` + `HttpClient.findProxy`
  闭包，每次连接现取规则 —— 设置改完对后续请求立即生效，不重建队列。

## 6. 设置页

- 顶栏第二层加齿轮入口（图标不带文字，那一排已经四个按钮）。
- `features/settings/`：`AppSettings`（落盘 `settings.json`，私有 files 目录）+
  设置页。分片并发 1~12，默认 6，拖动只改本地值、松手落盘；代理输入框 + 保存。
- `HlsDownloader` 的并发改为回调取值，`DownloadQueue` 透传
  `segmentConcurrency`，改完对下一条任务生效。

## 验证

- `flutter analyze` 无问题；`flutter test` 全量 **189 通过**（9 skip，含新增
  `test/download_queue_network_test.dart` 2 例与 `test/download_real_e2e_test.dart`）。
- 队列用例覆盖：断网 → `waitingNetwork` → 网络回来 → 自动完成；等待中取消 →
  `canceled` 而不是 `failed`。
- `flutter build apk --release` 成功；不带 `--target-platform` 的构建已验证 ABI 只剩
  arm64 + x86_64。

## 待办

- 真机复验：熄屏 5 分钟以上，回来看卡片是否显示「等待网络」并在解锁后自动续。
- 设置页的分片并发 / 代理目前只有编译与单测覆盖，未在真机上点过。
- B1~B12 真机验收仍未执行。
