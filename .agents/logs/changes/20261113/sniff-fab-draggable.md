> 记录路径：.agents/logs/changes/20261113/sniff-fab-draggable.md

# 嗅探入口改回右下角悬浮按钮（小号 + 可拖动）

- 日期：2026-11-13
- 任务：上一轮把嗅探入口塞进了顶栏第二层，用户要求改回右下角悬浮按钮，
  但要比原来的 `FloatingActionButton.extended` 小，可拖动，位置在本次运行内记住，
  杀掉应用回默认右下角。
- 内容：
  - `sniffer/presentation/sniff_fab.dart`（新）：44dp 圆角方块（FAB 是 56），
    雷达图标 21 + 数量角标（`> 0` 才显示，白描边保证压在图标上不糊）。
    挂在网页区域的 `Stack` 里，所以只能盖内容、盖不到顶栏。
  - `sniffer/presentation/fab_position.dart`（新）：`SniffFabPosition`
    （`ChangeNotifier`）+ `sniffFabPositionProvider`。**只存内存、不落盘** ——
    「杀掉应用就回默认右下角」是明确要求，所以没有走 `DownloadStore` 那套持久化。
  - 拖动用 `onPanUpdate` 累加 `details.delta` 并逐帧夹住边界（`clampOffset`），
    拖出边界不会留下越界坐标；旋转/缩放后同样夹回可见范围。
  - `sniff_fab.dart` 暴露 `buttonKey` 给测试定位按钮本体（外层是铺满的 `Positioned.fill`）。
  - `browser_header.dart` 移除 `_SnifferButton` 及两个多余 import；第二层变成
    左「搜索引擎」+ 右「下载 / 诊断」。
  - `browser_page.dart` 的内容 `Stack` 追加 `SniffFab()`（最后一项，盖在首页覆盖层之上）。
- 结果：`flutter analyze` No issues；`flutter test` 103 通过 / 8 跳过
  （新增 `sniff_fab_test.dart` 5 条：默认右下角、拖动后位置保留、越界夹住、
  reset 回默认、点击打开资源面板；`browser_header_test.dart` 同步去掉嗅探断言）；
  `flutter build apk --debug` EXIT=0（15.7s）。
- 取舍：
  - 不做松手吸附左右边缘 —— 用户只要求「记住位置」，吸附反而会让想停在中间的人别扭；
  - 不做长按收起/透明 —— 44dp 已经够小，再加手势会和拖动打架；
  - 角标不显示「12 个资源」文字，只显示数字，避免又变成 extended FAB 的体积。
