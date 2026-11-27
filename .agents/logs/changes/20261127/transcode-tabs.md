> 记录路径：.agents/logs/changes/20261127/transcode-tabs.md

# transcode.html 任务队列拆分为三个 tabs

- 日期：2026-11-27
- 任务：转换页不再把 进行中/排队中/已完成 三区堆在一屏，改为三个 tab 各占一帧
- 内容：
  - 复用 base.css 现有 `.chips/.chip` 筛选样式（与 sniff.html 一致），不做新组件
  - 「任务队列」单帧拆为 进行中 / 排队中 / 已完成 三个手机框，每帧 chips 高亮对应 tab，仅展示该类任务卡
  - 移除三个 `sec-label` 分区标题，空态帧保持不变
  - 追加：排队中卡片去掉圆环只留时钟 icon；已完成卡片去掉圆环只留 52px 对勾 icon
- 结果：浏览器打开 design/mobile/transcode.html 核对四个帧布局正常
