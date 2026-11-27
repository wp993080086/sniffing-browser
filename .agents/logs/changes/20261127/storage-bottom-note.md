> 记录路径：.agents/logs/changes/20261127/storage-bottom-note.md

# storage.html 底部文案溢出修复

- 日期：2026-11-27
- 任务：底部私有目录说明文案溢出容器，修复并按 4px 间距刻度核对内边距
- 内容：
  - 根因：`/storage/emulated/0/...` 长路径无空格不可断行，顶出右缘
  - `.bottom-note b` 加 `word-break:break-all` 允许路径折行
  - `.bottom-note` padding 14px → 12px（--sp-3，对齐 4px 刻度）
  - 追加：usage-row 由 align-items:baseline 改为 center，左侧单行文案相对右侧两行块垂直居中
  - 追加：占用行「其中断点缓存 .part」改为「断点缓存 .part」
  - 追加：临时分片小字去掉「其中可清理 1,022 项」，只留「1,284 项」
- 结果：浏览器打开 design/mobile/storage.html 核对底部文案不再溢出
