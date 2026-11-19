# 嗅探悬浮按钮：56dp 毛玻璃底

- 日期：2026-11-13
- 触发：用户反馈「用力过猛了」，要求尺寸回 56、背景改高斯模糊半透明，
  并给出明确边距（边距最少 16；默认右侧 16、距底 60）。

## 改动

`lib/features/sniffer/presentation/sniff_fab.dart`

1. `size` 44 → **56**；圆角 14 → 18；图标 21 → 26。44 的方块配单图标偏小，
   在真机上点按容错低，回到 Material FAB 标准边长。
2. 新增 `_GlassSurface`：`ClipRRect` → `BackdropFilter(blur 14)` →
   `DecoratedBox(surface.withValues(alpha: 0.3) + 0.5 alpha 描边)`。
   阴影留在 `ClipRRect` 外层，避免被裁掉；`ClipRRect` 同时限制模糊扩散范围，
   否则四角会糊到按钮外面。
3. 边距常量重命名并调值：`_edge` 4 → `minEdge` **16**；`_defaultMargin` 14 拆成
   `defaultRight` **16** 与 `defaultBottom` **60**（让开底部手势条）。
   `clampOffset` 四边统一用 16 夹住，区域小于 56+32 时退化到 16 不抛错。
4. 角标位置 `-6/-6` → `2/2`：56 的方块里再向外挑角标容易被 Tooltip/SizedBox
   边界影响命中区，改为贴内角，视觉上仍压在图标右上。

## 已知限制

`BackdropFilter` 只能模糊 Flutter 自己绘制的层。Android / Windows 的 WebView 是
platform view（独立合成层），按钮浮在网页上方时读不到它的像素，模糊实际不生效，
观感退化为「0.3 半透明 + 描边」；盖在自绘首页这类 Flutter 内容上才有效果。
真机上如果觉得像纯色块，把 alpha 再降到 0.2 或去掉 border 会更通透。

## 验证

- `flutter analyze`：No issues
- `flutter test`：**103 通过 / 8 个 e2e 跳过**；`test/sniff_fab_test.dart` 5 条改为
  断言 `Size.square(56)`、`right == width-16`、`bottom == height-60`、
  拖到四角各留 16、reset 回默认。
- `flutter build apk --debug`：EXIT=0（12.1s）。

## 文档

`docs/tech-design.md` 顶栏小节「嗅探悬浮按钮」整段重写（含平台层模糊限制的
说明）；`README.md` 功能表补「毛玻璃」与尺寸。
