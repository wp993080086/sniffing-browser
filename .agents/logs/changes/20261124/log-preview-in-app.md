# 变更：顶栏去重日志入口 + 导出后应用内预览（2026-11-24）

## 改了什么

| 文件 | 改动 |
| --- | --- |
| `lib/features/browser/presentation/browser_header.dart` | 删掉 `_DiagnosticsButton` 与 `DiagnosticsPage` import；第二层只剩「引擎 / 页签 / 下载 / 设置」 |
| `lib/features/diagnostics/data/log_exporter.dart` | `_exportFiles` 提升为公开的 `list()`（倒序）；新增 `labelOf()` 把文件名时间戳转成 `2026-11-24 16:30:05` |
| `lib/features/diagnostics/presentation/log_view_page.dart` | 新增：单份导出日志的应用内预览，等宽折行、可跨行选中、复制全文、分享 / 系统打开；超过 20000 行截断并在顶部说明 |
| `lib/features/diagnostics/presentation/log_exports_page.dart` | 新增：导出记录列表（时间标签 + 文件名 + 大小），点开进预览页 |
| `lib/features/diagnostics/presentation/diagnostics_page.dart` | 导出后改为 push 预览页；「更多」菜单新增「导出记录」 |
| `test/browser_header_test.dart` | 断言不再有虫形图标，改为断言设置入口 |
| `test/log_exporter_test.dart` | 补 `list()` / `labelOf()` 用例 |
| `test/log_view_page_test.dart` / `log_exports_page_test.dart` | 新增页面用例 |
| `test/diagnostics_page_test.dart` | 补「导出后进预览」「更多菜单有导出记录」两个用例 |

## 为什么这么改

- **同一个页面不该有两个入口**：虫形图标和「设置 → 排查 → 运行日志」指向同一个
  `DiagnosticsPage`，顶栏那个还占着挤了五项的工具栏位置，让人猜哪个才是正路。
- **导出后看不到内容**：原来手机上导出只调 `MediaExporter.shareFile` 弹分享面板，
  而分享面板只负责把文件送出去，不提供预览。用户把唯一的现场发出去了，自己却读不到。
  改成先摊在应用内，看完再决定发不发。
- **不能整篇一个 `SelectableText`**：导出文件是 `app.log.1` + `app.log` + 尾巴，
  上限约 4MB。一次性排版会把主线程卡住，所以按行丢进 `ListView.builder`，外层套
  `SelectionArea` 保证跨行连续选中。截断只影响看，复制和分享始终是完整文件。
- **导出记录**：重导出来的已经不是当时那份了，留一个回看点比重新导更有意义。

## 没做

- 预览页不做搜索 / 级别过滤：那是日志页（内存实时视图）的职责，预览页面对的是
  一份静态文件，加过滤等于再实现一遍。
- 导出记录不做重命名 / 删除：保留 3 份的上限已经把空间问题解决了。

## 验证

- `flutter analyze` 零 issue。
- 全量 `flutter test -j 1` → **311 通过 / 9 跳过 / 0 失败**。
- 未做真机验证：Android 的分享面板、桌面端「用系统程序打开」各需要在真机 / 桌面上点一次。
