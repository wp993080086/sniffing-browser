> 记录路径：.agents/logs/reviews/20261111/rules-cleanup.md

# 复核重写后的项目规则

- 日期：2026-11-11
- 任务：核对 6 份规则与代码事实是否一致
- 内容：
  - 路径核对：16 个引用文件全部存在
  - 关键词残留：像素工坊 / PRD / ARB / AppLogger / image 包 / .gitattributes / app_platform_impl_native 均无
  - 计数器名（`cdp.responseReceived`、`sniffer.shouldIntercept`、`sniffer.captured`）与异常类名均与 lib 一致
  - 自查修正 2 处：01 的 DASH 边界改为「不做 MPD 重组，只处理完整 `.m4s`」；04 的分层约定改为「仅 browser 有 `providers/`，全局单例在 `lib/app/providers.dart`」
- 结果：通过。遗留待确认：`docs/tech-design.md` 草案与实现不一致处未改（不属本次范围）；未新增 `.gitattributes`，规则中不再声称已锁定换行符
