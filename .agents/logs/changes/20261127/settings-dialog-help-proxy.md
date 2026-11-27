> 记录路径：.agents/logs/changes/20261127/settings-dialog-help-proxy.md

# settings.html 弹窗/问号说明/代理文本域三项调整

- 日期：2026-11-27
- 任务：设置页三处改版：弹窗标题居中加关闭、长文案栏目加问号 icon、代理改两行文本域
- 内容：
  - 弹窗：`.dialog h3` 居中 + 右侧关闭按钮（新增 `i-close` symbol）
  - 问号说明：站点规则 / 登录态管理 / 分片并发 / 重启后自动续传 四个换行栏目，标题后加 `i-help` 圆圈问号，长文案移入 `.tip` 气泡，row-desc 缩为一句话；脚本点击 q-btn 切换 tip 展开
  - 代理：`.proxy-card` 由单行 input 改为 rows=2 的 textarea，保存按钮绝对定位在卡内右下角
  - 追加：分片并发文案精简为「HLS 任务同时下载分片数」；问号点击由展开块改为浮动 Tooltip（深色气泡+箭头，`.group` 放开 overflow 让气泡可越界）；删除代理卡下方 note 及其样式；问号 icon 缩至 14px（图形 12px）
  - 再调：问号 icon 放大为 20px（图形 16px）；Tooltip 改为锚定在问号正下方、箭头对准问号中心（新增 q-wrap 包裹）；新增第三帧「问号 Tooltip」展示展开态设计稿（分片并发 tip 常开）
- 结果：浏览器打开 design/mobile/settings.html 核对弹窗布局、点击问号展开、代理文本域布局
