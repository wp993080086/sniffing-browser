# standard.html 图标库补全

- 日期：2026-11-27
- 任务：用户指出首页工具栏盾牌旁的「页签」图标未收录进 standard.html 图标库；排查后将移动端页面用到的全部图标补入标准
- 内容：
  - standard.html 新增 20 个 symbol：radar、tabs、history、star、star-fill、check、plus、minus、chev-down、back、forward、swap、file、key、clipboard、filter、upload、broom、rule、log
  - 图标展示区（07 图标规范）同步追加对应 icon-cell，库从 28 个增至 48 个
  - 命名遗留：标准库用 chevron-left/right，移动端页面用 chev-left/right（各页内嵌 defs 自洽，不影响使用；后续统一时再收敛命名）
- 结果：grep 校验 symbol 定义与展示区一一对应；i-scan 重打路径经核对与原定义一致

## 图标重绘：tabs / settings

- 用户反馈页签、设置图标不好看：页签改两方块叠放样式（lucide copy 造型），设置改标准圆形齿轮（Feather settings 造型）
- 同步替换 3 处定义：standard.html（库+展示区）、mobile/browser.html、mobile/sniff.html（其余页面未内嵌这两个 symbol）

## 图标修订：shield 尺寸对齐 + 激活态

- 用户反馈盾牌视觉上比齿轮小、缺激活态：盾牌从 15×18 放大到 17.5×20（占满 24 网格程度对齐齿轮）；新增 i-shield-fill 实心激活态（白色对勾）
- 同步 3 处 i-shield 定义（standard/browser/sniff），standard 展示区新增 shield-fill 单元；browser.html 隐私按钮切为激活态演示（hl 类 + shield-fill）
