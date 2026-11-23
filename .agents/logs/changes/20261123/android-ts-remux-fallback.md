> 记录路径：.agents/logs/changes/20261123/android-ts-remux-fallback.md

# Android TS→MP4 只重编音频回退

- 日期：2026-11-23
- 任务：补齐桌面已有、Android 缺失的转封装失败回退。

## 内容

- `TranscodeBridge.kt`：
  - 抽出 `execute(...)`：每次 session 独立日志尾缓冲与完成回调；
  - `runTsToMp4WithFallback(...)`：`-c copy` 失败且非取消时，删半截输出、
    进度推回 0，再跑 `-c:v copy -c:a aac -b:a 192k -movflags +faststart`；
  - 新增 `cancelRequested`：补上两次 session 切换间 `activeSessionId` 为 null 的
    取消窗口；
  - 回退成功回包带 `strategy=audioReencoded`；两次都失败拼两段中文结论。
- `transcode_engine.dart`：识别 `strategy` 记一条日志，不改变 done 的语义，
  UI 不为兼容性回退增加状态。
- `native_transcode_engine_test.dart`：补 `done + audioReencoded` 用例。

## 结果

- `:app:compileReleaseKotlin`（`JAVA_HOME=D:/Android Studio/jbr`）成功；
  `flutter analyze` 干净；`native_transcode_engine_test.dart` 9 例全过。
- 真机待验：找一段 AC-3 / MPEG-2 音频的 TS，确认回退触发且音频可播。
