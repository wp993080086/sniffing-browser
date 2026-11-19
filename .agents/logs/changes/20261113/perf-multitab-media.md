> 记录路径：.agents/logs/changes/20261113/perf-multitab-media.md

# 多页签与多播放器的性能调优

- 日期：2026-11-13
- 任务：多开页面时的开销评估，以及「一个页面里多个播放器会不会卡爆」的针对性调优。

## 结论（改之前）

三条真实开销，都不是猜测：

1. `_autoplayNudge` 把页面上**所有** `video[autoplay]` 逐个 `play()`。
   视频列表页一屏十张卡片就是十路同时解码，声音还叠在一起。
2. `IndexedStack` 只是不绘制。后台页签的**渲染、动画、视频解码、轮播**全都在跑，
   4 个存活页签就是 4 份开销叠加。
3. 资源列表出现几十个 mp4 时，缩略图抽帧并发 3 路。桌面每次抽帧起一个 ffmpeg
   进程，Android 每次都要打开媒体源读头，同时三个已经把 CPU 吃掉了。

## 做了什么

**1. 非活跃页签挂起**

- `WebViewHost` 新增 `active` 参数，`browser_page` 按 `tab.id == activeId` 传入；
- `didUpdateWidget` 检测变化 → `_applyActive`：
  - 转后台：`_pauseMedia()`（JS `__sbMediaGovernor.pauseAll()`）+ `controller.pause()`
    （Android `WebView.onPause` / Windows `TrySuspend`）；
  - 回前台：`controller.resume()`，**不自动续播**（等同于系统浏览器切后台）；
- `onWebViewCreated` 时若已非前台，补一次挂起（目前只在恢复页签且未激活时走到）；
- `onLoadStop` 时若非前台，`_nudgeAutoplay` 直接返回，并补一次 `_pauseMedia`
  —— 后台页签加载完成时，页面自己的 autoplay 可能已经起来了。

**2. 页面内媒体治理**

- 新增 `_mediaGovernor` 脚本（`onLoadStop` 注入，每次换页面重注）：
  - `play` 事件（capture 阶段）互斥：任一 `video`/`audio` 开始播，暂停其它全部；
  - 暴露 `window.__sbMediaGovernor.pauseAll()` 供 Dart 调用。
- `_autoplayNudge` 重写：页面里已有在播的就不插手；只处理**视口内**且宽高 ≥ 40px 的；
  **一次只启动一个**。

**3. 视频抽帧串行**

- 新增 `core/utils/serial_gate.dart`：`SerialGate.run()`，前后任务严格串行，
  且前一个抛错不会卡住后一个（错误只挂在它自己的 Future 上）。
- `ThumbnailService.videoFrame` 走闸门，`_videoFrameNow` 是原实现。
  图片路径不动，仍由 `ThumbnailCache` 并发 3。

**改的文件**

- `features/browser/presentation/webview_host.dart`（active / 三条脚本 / 挂起恢复）
- `features/browser/presentation/browser_page.dart`（传 active）
- `features/sniffer/data/thumbnail_service.dart`（抽帧串行）
- `core/utils/serial_gate.dart`（新）

## 明确没做 / 做不到的

- **`pause()` 不减内存**，只停绘制与合成。内存回收仍靠 `maxLive = 4` 的 LRU。
- **后台页签的 JS 定时器仍在跑**：Android 只有全局的 `pauseTimers()`，会把前台页签
  一起停掉，不能用。要彻底停只能销毁 WebView，等于放弃「切回来瞬开」。
- **没有降 `maxLive`**：4 是「切页签瞬开」和内存之间的折中，降成 3 收益有限、
  体验倒退明显。需要的话改 `TabManager(maxLive:)` 一个参数即可。
- **没有给 `SnifferService.items` 加缓存**：它每次调用会复制一遍列表（上限 800 条），
  但只在面板重建时调用（100ms 合并一次），实测不是瓶颈；而加缓存必须同步
  invalidate 所有 `copyWith` 更新点，漏一处会让下载拿到没有请求头的旧对象
  （→ 403），风险大于收益，故不动。

## 验证

- `flutter analyze`：No issues
- `flutter test`：**146 通过 / 8 个 e2e 跳过**（新增 `serial_gate_test` 4 条）
- `flutter build apk --debug`：EXIT=0，21.5s

## 真机待验

1. 开 3~4 个页签，其中一个是视频页，切来切去：是否只有一个页面出声、
   切走的页面声音是否立刻停；
2. 视频列表页（B 站首页 / YouTube 首页这类）：是否还会出现多个预览同时播放；
3. 切回页签后 WebView 是否正常显示（`pause()` / `resume()` 若在某个 ROM 上
   导致白屏，需要改成只用 JS 暂停、不调 `pause()`）；
4. 后台页签下载/加载完成的通知是否仍正常（挂起只停绘制，不影响加载逻辑）。
