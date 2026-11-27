> 记录路径：.agents/logs/changes/20261126/design-system.md

# 设计稿文件新增

- 日期：2026-11-26
- 任务：新增项目设计稿（HTML 格式），移动端优先
- 内容：
  - 新增 `design/standard.html`（设计标准 Token 页）
  - 新增 `design/index.html`（导航入口）
  - 新增 `design/mobile/home.html`（浏览/嗅探页）
  - 新增 `design/mobile/download.html`（下载管理页）
  - 新增 `design/mobile/transcode.html`（转换任务页）
  - 新增 `design/mobile/settings.html`（设置页）
  - 约定：主题渐变 to top #b224ef → #7579ff；图标全部内联 SVG（24px / stroke 1.8 / 圆角端点），禁用 emoji；按压态 scale(.96~.98) + brightness(.93)，开关滑块用弹性曲线
- 结果：文件均为自包含 HTML，浏览器直接打开即可查看；桌面端设计稿待后续产出

## 第二轮：按真实截屏重做移动端布局

- 日期：2026-11-26
- 任务：用户反馈首轮 4 页布局脱离真实结构，提供 15 张真机截屏（design/screenshot/），要求「布局结构照抄、样式重设计」
- 分析结论：真实 App 是浏览器形态（无底部 Tab）：双行工具栏 + 引擎切换 + 嗅探 FAB；资源/页签走底部抽屉；二级页 = AppBar + 分组/空态；设置页蓝色小节分组；日志页等宽字体流
- 内容：
  - 新增 `design/mobile/base.css`：共享 Token 与手机外壳/AppBar/设置行/开关/输入框/FAB/空态/chips 等通用组件
  - 重做/新增 12 页：browser（首页+引擎下拉）、sniff（资源抽屉 有值/空态）、tabs（页签抽屉）、downloads（下载库 空态/有值）、parse（视频解析 引导/结果）、transcode（转换 空态/队列）、settings（设置+下载完成后弹窗）、storage（存储管理）、sessions（登录态管理）、rules（站点规则 空态/有值）、logs（运行日志）、misc（历史/收藏 空态/有值）
  - 有值列表、解析结果、转换队列等截屏未覆盖的状态按真实交互逻辑合理推断补充
  - 删除废弃旧稿 `home.html`、`download.html`（已被 browser/downloads 取代）
  - 更新 `design/index.html` 导航
- 结果：布局 1:1 对应截屏结构；样式全部套 standard.html Token（渐变主题、SVG 图标、按压态、光影）

## 第三轮：首页与标准修订

- 日期：2026-11-26
- 任务：按用户反馈修 4 点：① 首页去掉渐变状态栏「肩膀」改纯白 ② 嗅探 FAB 改雷达图标 + 毛玻璃 ③ 工具栏间距对齐、去掉「下载」文案 ④ standard.html 补间距/阴影标准
- 内容：
  - `standard.html`：新增 --sp-1~8 间距刻度、--glass-* 毛玻璃 Token、--shadow-drawer / --shadow-glass；新增「09 布局间距与悬浮规范」章节（刻度表、页面结构尺寸、阴影场景表、毛玻璃使用规则）
  - `mobile/base.css`：同步 Token；新增 .statusbar.light 白色变体；FAB 重写为毛玻璃样式（glass-bg + backdrop-filter + glass 边框 + shadow-glass）
  - `mobile/browser.html`：状态栏切 light；新增 i-radar 雷达图标（起始页 logo 与嗅探 FAB 共用）；删除「下载」文案；工具栏 padding/gap 统一用 --sp 刻度
- 结果：毛玻璃 FAB 经 base.css 同步作用于全部页面；其余页面视觉不变
