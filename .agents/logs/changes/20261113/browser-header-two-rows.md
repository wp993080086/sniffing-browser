> 记录路径：.agents/logs/changes/20261113/browser-header-two-rows.md

# 顶栏拆成两层

- 日期：2026-11-13
- 任务：用户反馈布局太丑，要求顶栏分两层 —— 第一层前进后退 / 地址栏 / 刷新，
  第二层搜索引擎 / 下载 / 嗅探等功能区。
- 内容：
  - 新增 `browser_header.dart`：`BrowserHeader` = SafeArea + 两层 + 进度条 + 1px 分隔线。
    不再用 AppBar（`toolbarHeight: 52` 放不下导航 + 输入 + 功能入口）。
  - `address_bar.dart` 收敛成第一层：后退 / 前进 / 地址栏 / 刷新，其余全部移出。
    地址栏 36 高、18 圆角，左侧按 `https` 显示锁图标。
  - 第二层：左 `_EngineButton`（搜索引擎下拉，`surfaceContainerHighest` 填充胶囊，
    不再是裸文字 + 箭头），右 `_SnifferButton` / `_DownloadButton` / `_DiagnosticsButton`，
    统一 `_BarButton` 样式（图标 17 + 12px 文字 + 数量胶囊，>0 时转主题色）。
  - 去掉右下角「嗅探」FAB：入口移到第二层，不再浮在网页内容上。
  - `browser_page.dart` 改为 `Scaffold(body: Column[BrowserHeader, Expanded(Stack[WebView, HomePage])])`，
    WebView 仍常驻、首页仍是覆盖层。
  - `BrowserController.stopLoading()`：刷新按钮在加载中显示叉号，之前点了却是 `reload()`，
    图标与行为不一致，顺手补齐。
  - `_BarButton` 自绘而非 `IconButton`：后者的 48px 最小点按区会让第二层比第一层还高。
  - 状态栏图标明暗：没有 AppBar 后没人声明 `SystemUiOverlayStyle`，用
    `AnnotatedRegion` 按主题亮度补上，否则深色主题下状态栏图标看不见。
- 结果：`flutter analyze` No issues；`flutter test` 98 通过 / 8 跳过
  （新增 `browser_header_test.dart` 2 条：两层结构与相对位置、320 宽不溢出）；
  `flutter build apk --debug` EXIT=0（35.5s）。
- 验证方式：临时写了个离屏渲染用例把顶栏截成 PNG 看了一版（Ahem 字体，只能看几何），
  确认两层高度约 82px、行内对齐、无溢出后删掉了该用例与产物，没有进仓库。
- 取舍：没有做地址栏聚焦时全选、没有做收起滚动工具栏、没有做点击放大 ——
  这轮只解决「两层」这一件事，样式再细调等有设计稿之后。
