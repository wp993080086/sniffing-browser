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

## tabs.html 页签抽屉修正（用户反馈）

- 遮罩底衬改纯白；状态栏改 light 并提至遮罩之上（对齐 sniff.html 抽屉模式）
- 抽屉高度改 80%（原内容自适应偏矮），tab-grid flex:1 撑满 + overflow-y:auto
- 删除底部「新建页签」卡片（顶部已有新建按钮），同步删 .tab-card.add 样式
- 第一张卡改为主页固定卡：无关闭按钮，home 图标 + 「主页」居中，新增 .tab-card.fixed 样式
- 新图标 i-home 入标准库（defs + 展示区），tabs.html 同步；清理孤儿定义 i-globe、i-scan
- 验证：grep 无残留引用（i-globe/i-scan/web-hero/tab-card.add 零匹配）

## tabs.html 关闭按钮放大（用户反馈）

- 页签卡右上角 X：命中区 24→32px（top/right 8→2px），图标 14→18px

## 全局白色顶栏统一（用户确认方案）

- 用户确认二级页顶栏改「全白」：base.css 状态栏默认改白底深字 + 1px 分割线，删除 .statusbar.light 变体；AppBar 渐变改白底（去 shadow-brand/inset/::after 高光），h1 深字，icon-btn 透明底深字、按压 fill-2
- 清理 browser/sniff/tabs 三页已失效的 light 类
- 卡片间距对齐「卡片间 12px」：transcode job-card、rules rule-card 与说明间距、parse 结果卡/提示条、logs 通道卡与列表顶距（10px → var(--sp-3)）
- standard.html 09 节文案同步：「顶部栏（状态栏 + AppBar）白底深字、1px 底分割线」
- 验证：settings.html?v=3 浏览器实测 PASS（状态栏/AppBar 均 rgb(255,255,255) 白底、深字、1px 分割线、background-image: none 渐变全消除）

## AppBar 返回键图标统一（用户反馈）

- 17 处返回键 i-back（箭头）→ i-chev-left（chevron）；9 个页面 defs 同步替换/新增，browser/sniff 两页无引用的 i-back 定义删除
- 验证：grep i-back 全局零匹配

## 类型图标与背景融合优化（用户截图反馈）

- 问题：.ri/.f-icon 8% 淡色底压在浅灰页面底上无轮廓
- 方案对比后选「1px 同色系边框」：color-mix(currentColor 22%) 自动按图标色取色，零新增 Token；不用阴影（小元素显脏）
- 改动：base.css .row .ri、downloads.html .f-icon 各加 1px 边框（覆盖设置/存储/登录态/下载等所有行图标）

## parse.html 输入区重做（用户反馈）

- 去掉输入框右侧剪贴板图标；输入框改 2 行文本域（.paste-box，72px），右侧竖排双按钮：解析（渐变主按钮）+ 清空（btn-outline，i-trash）
- 空态文案：删「解析用的是页面自己的接口响应，不需要额外的账号或 key」；上句拆为两行
- defs：删 i-clipboard（孤儿）、加 i-trash；修正 frame2 替换时遗留的多余 </div>
- 验证：div 开闭 42/42 平衡；grep i-clipboard/i-back 零残留

## parse.html 按钮高度修复（浏览器实测）

- 实测按钮 46px 而非 34px：旧规则 .parse-row .btn{height:46px} 在样式表靠后位置覆盖新规则（同特异性后者胜）
- 删除旧规则与孤儿 .parse-row .field；按钮 34+34+4=72px 与文本域 72px 对齐

## parse.html 布局重构（用户反馈）

- 解析按钮移到文本域下方全宽（parse-row 改 column）；清空按钮不再独立占位，改为有内容时悬浮在文本域右下角（.clear-fab，28px 圆钮，rgba(23,24,43,.75) 实色底不透出文字）
- 两帧分工表达状态：空态帧无清空钮、结果帧有内容显示清空钮；defs i-trash → i-close
- 验证：div 42/42 平衡，i-trash/parse-actions 零残留

## parse.html 清空钮美化 + 删提取音频（用户反馈）

- 清空钮 rgba(23,24,43,.75) 深底 → 白色实底 + text-2 图标 + 细边框柔投影，按压 fill-2
- 查证 lib/transcoder：项目有「转为 MP3」但仅在下载列表 ⋮ 菜单触发，解析页无此入口 → 删结果卡「提取音频」按钮；rc-actions 单按钮改 flex:1；i-music 定义保留（第二张卡类型图标在用）
