> 记录路径：.agents/logs/reviews/20261127/misc-review.md

# misc.html 规范符合性检查

- 日期：2026-11-27
- 任务：对照 base.css 规范（4px 间距刻度、token 写法、分隔线对齐）检查历史记录/收藏夹页
- 结论：3 处不一致已修复
  - `.entry-list` padding `6px 16px 90px` → `var(--sp-2) var(--sp-4) 90px`
  - `.date-label` padding-top 10px → 8px（与上一条合计落差不变，视觉无差异）
  - `.entry` 分隔线 left 44px → 46px（对齐图标 34px + gap 12px 的文字起点）
- 符合项：空态复用 base `.empty`、appbar/statusbar 结构、`.entry` 14px 上下内边距与 base `.row` 惯例一致
- 追加：星标 on 色 accent-5 → brand-6，对齐全局 on 态统一用 brand 色系的惯例（chip.on / engine-item.on / tab-card.on）；off 态 text-3 原本已一致
