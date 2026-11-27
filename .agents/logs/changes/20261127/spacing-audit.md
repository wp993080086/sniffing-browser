# 间距规范审计与修正

- 日期：2026-11-27
- 任务：用户指出首页顶部栏间距未按规范、要求全量检查；并将「卡片内边距 14~16px」改为固定 16px
- 内容：
  - standard.html：卡片内边距改「16px（固定）」；补充状态栏左右内边距 16px
  - base.css：状态栏 padding 22px→16px；AppBar padding 8/16/14→9/16/9（总高恰为 56px）；page-body.pad 顶部 14→16px
  - browser.html：工具栏水平内边距 12→16px；url-pill 38→40px（行高 40）；engine-chip 32→36px（行高 36）；下拉 top 38→40；快捷入口 margin 22→24（sp-6）
  - 卡片内边距统一 16px：tabs.html tab-card、transcode job-card、storage usage-card、rules rule-card、logs channel-card、parse rc-head/rc-actions、settings dialog 22→24（sp-6）
  - 列表行统一 14px 上下：sniff res-item、downloads file-item、misc entry、storage usage-row
  - 非刻度值归位：settings 分组间 18→20（sp-5）×4、transcode 区块 14/18→16/20、storage 清理组 6→8（sp-2）、parse 解析行/提示条、downloads 搜索区
- 结果：全部页面间距均落在 sp-1~8 刻度或 09 节结构尺寸上

## 首页工具栏溢出修复（浏览器实测）

- 用户反馈刷新按钮贴边；起本地服务用浏览器 DOM 实测确认：第一行溢出 8px，刷新按钮右缘=手机框右缘（0px），第二行正常（24px inset）
- 根因：.url-pill 未设 min-width:0，内部 <input> 默认固有宽度（size≈20）撑破 flex 行
- 修复：.url-pill 加 min-width:0；复测刷新/设置按钮右缘均=665（框架右缘 689 − 8 border − 16 padding），scrollWidth=offsetWidth 无溢出，PASS

## sniff.html 抽屉页重整（浏览器实测诊断）

- 用户反馈样式全乱；起服务截图诊断出 4 处缺陷并修复：
  1. 空态覆盖抽屉头：base 的 .empty 是 absolute inset:0，抽屉内改为 .empty.empty-drawer{position:static;flex:1}
  2. 列表底部 96px 死白：页面级 FAB 预留误入抽屉，改 sp-6 24px
  3. chips 溢出截断：去掉 0 计数（视频/音频/其他），一行放下
  4. 状态栏：渐变紫浮在白色网页示意上且被遮罩压暗 → 改 light 白色变体 + z-index:6 浮于遮罩(z4)之上；web-demo top:44px 避开状态栏、白底
- 验证：首轮复测因浏览器缓存读到旧版结论无效（curl 确认服务端已是新版）；带 ?v=2 强刷复测 4 项全 PASS（空态间距 50px、列表底部仅 8px、状态栏清晰）

## sniff.html 三处修正（用户反馈）

- 空态：去掉「全部 0」chip；空态图标 i-scan → i-radar（嗅探），并从 browser.html 同步 radar 定义
- 渐变下载按钮：原为「推荐资源」强调演示，违反列表操作统一/同屏渐变 ≤2 规则，删除 .dl-btn.primary 定义与使用
- 遮罩底衬：移除网页示意（hero/线条），改纯白 .web-demo
- 清理孤儿定义：i-globe、i-scan（本页无引用后删除；i-scan 保留在 standard 图标库）
- 验证：grep 无残留引用（i-globe/i-scan/web-hero/primary 零匹配）
