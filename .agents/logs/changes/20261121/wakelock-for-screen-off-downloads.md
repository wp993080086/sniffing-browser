> 记录路径：.agents/logs/changes/20261121/wakelock-for-screen-off-downloads.md

# 熄屏后下载进度完全不动：前台服务缺唤醒锁

- 日期：2026-11-21
- 任务：用户反馈「熄屏之后下载进度完全没前进；重新打开屏幕后应用还在后台、
  没有被杀死，过一会又重连好继续下载了」，要求查明原因。

## 一、根因

前台服务只把进程钉在前台状态，**不阻止熄屏后 CPU 进 Doze**。CPU 一睡：

- Dart 的 `Future.delayed` 不触发 —— 断网恢复的 3/10/20/30/60s 重试定时器冻住；
- TCP 读写挂起，连接最终被系统收掉；
- 但进程还活着、通知还在，所以用户看到的是「进度完全不动」而不是「应用被杀」。

亮屏后 CPU 恢复，定时器补跑、连接被判定失败，`_runWithNetworkRecovery` 介入，
于是「过一会又重连好继续下载了」。这条时间线与现象逐项吻合，也解释了为什么
上一轮加的前台服务和无限等待都没能把熄屏这段时间救回来 —— 两者都依赖定时器
或 socket 还能跑。

同类案例：streamyfin 的下载服务（dataSync 前台服务 + OkHttp）有完全相同的故障，
修复方式就是加 `PARTIAL_WAKE_LOCK`。

## 二、改法

`AndroidManifest.xml`：加 `android.permission.WAKE_LOCK`（普通权限，无运行时弹窗）。

`DownloadForegroundService.kt`：

- `onCreate` 拿 `PowerManager.PARTIAL_WAKE_LOCK`，tag `sniffing_browser:download`；
- `onDestroy` release；
- 不设超时：大文件可能下几十分钟，Dart 侧没有续期通道；进程被杀时系统会自动
  回收锁，不会泄漏；
- 拿不到锁只记警告，不让下载失败（前台服务本身还在）；
- 生命周期跟随服务，所以等待网络重试期间也持有 —— 否则重试定时器同样冻住，
  永远等不到网络恢复；
- 加 `TAG = "DownloadFgService"` 两条 acquire/release 日志，方便 adb 确认。

## 三、验证

- `flutter build apk --release --target-platform android-arm64` 通过（84.7MB）；
- 本轮只改 Kotlin + Manifest + 文档，Dart 侧无逻辑变更；
- 真机验证待用户执行：下一个几分钟的视频 → 锁屏 5 分钟 → 亮屏，进度应当从未停过，
  且 `adb logcat -s DownloadFgService` 能看到 acquire/release 成对出现。

## 四、边界

- 唤醒锁只保证 CPU 不睡；Wi-Fi 自身休眠、蜂窝/Wi-Fi 切换仍可能断流，由任务层
  等待网络兜住（现在定时器能正常跑了）。
- Android 15+ 的 dataSync 前台服务每 24 小时有 6 小时额度，超长下载仍可能被系统
  叫停；普通视频远达不到，暂不处理。
- 厂商 ROM 的「省电策略 / 后台高耗电」仍可能单独冻结进程，需用户把应用加白名单。
