> 记录路径：.agents/logs/changes/20261112/a2-acceptance.md

# A2 验收结果回填

- 日期：2026-11-12
- 任务：把用户回报的 Android 模拟器计数器结果写成 8.0 真机验收记录。
- 内容：
  - `docs/tech-design.md` 8.0 新增「A2 已通过（2026-11-12，Android 模拟器）」段：`sniffer.onLoadResource = 85`、`sniffer.shouldIntercept = 83`；解释两数不等的原因（前者 url 非空才计数、后者请求发起时无条件计数，`webview_host.dart:278-303`），记录 `shouldInterceptRequest` 返回 null 放行未阻塞页面、Windows 同类坑在 Android 未复现。
  - W1 段末「A 用例仍需真机执行」删除（由 A2 记录段取代）；阶段状态表「1 嗅探」改为「代码完成，A2 已验收」。
  - 第 0 章标题日期改为 2026-11-12，Android 行改为「模拟器 A2 已验收、真机待复验」。
  - 未改验收用例表判定标准、未改「A 用例未全绿前不启动移动端原生能力」口径、未改任何源码。
- 结果：文档围栏 56 个成对、章节 0~10 编号不变；`git status` 无新增源码改动；A1 / A3~A6 与 A2 真机复验仍待用户执行。
