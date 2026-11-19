> 记录路径：.agents/logs/reviews/20261111/mobile-unavailable-entries.md

# 移动端入口收口复核

- 日期：2026-11-11
- 任务：复核本轮改动是否贴合范围、是否引入回归。
- 内容：
  - 逐行核对 git diff：改动均可对应「用户连续三次撞到不可用 / 未实现入口」或此前已点名的前置缺陷，无周边重构、无格式排版改动。
  - 检索 `AsyncValue` / `ffmpeg_kit_flutter_new` / `@ohos/ffmpeg-kit` / `阶段 5`，`lib/` 与 `pubspec.yaml` 零残留。
  - 入口判定复核：`canExport` 与 `_availableKinds` 都走 `PlatformInfo.isDesktop`；`onSelected` 中 `case 'export'` 与 `transcode:*` 分支保留（移动端不可达但无害，不删既有代码）。
  - 桌面端行为未变，W1 依赖的转码 / 导出链路不受影响；Android 上 DASH 自动合并仍会因 `availability()` 为 false 失败，已在 8.0 异常行为表记录，不属本轮范围。
  - 遗留（非本轮产生）：`gradle-wrapper.properties` 指向本地 zip、`android/build/` 未被忽略、`MainActivity.kt` 空壳、main manifest 无 cleartext 配置、A1~A6 待设备验证。
- 结果：通过。待办：用户重新 F5 后确认 Android 菜单不再出现「保存到相册 / 转为 MP3」；回收 A2 的 `sniffer.onLoadResource` 与 `sniffer.shouldIntercept` 数字。
