# 变更：设置页日志入口 + 导出 txt（2026-11-24）

## 改了什么

| 文件 | 改动 |
| --- | --- |
| `lib/core/logging/app_log.dart` | 待写队列改存 `LogEntry`；`_append` 成功后推进 `_flushedUntil` 水位；新增 `exportBundle()`（磁盘历史 + 内存尾巴）、`exportHeader()`、`banner()`、`resetForTesting()`；`LogEntry.stamp` 统一时间写法 |
| `lib/core/constants/app_constants.dart` | 新增 `version`，导出头部带版本 |
| `lib/features/diagnostics/data/log_exporter.dart` | 新增：写 `logs/log-<时间戳>.txt`，同秒不覆盖，只留最近 3 份 |
| `lib/features/diagnostics/presentation/diagnostics_page.dart` | 重写：关键字搜索、级别过滤（全部 / 警告以上 / 仅错误）、跨天补日期、导出 txt、复制、清空；环境卡片可展开计数器 |
| `lib/features/settings/presentation/settings_page.dart` | 新增「排查 → 运行日志」入口；重复的「网络」分区标题改为「代理」 |
| `lib/main.dart` | 启动时写会话分隔线 |
| `test/*` | 新增 `app_version_test` / `log_export_test` / `log_exporter_test` / `diagnostics_page_test` / `settings_page_test` |

## 为什么这么改

- **导出要覆盖崩溃场景**：内存只留 800 条且随进程消失，真正要排的「闪退 / 白屏后重开」
  只剩磁盘文件里的现场。导出改为 `app.log.1` + `app.log` + 未落盘尾巴。
- **不能重复**：flush 是异步的，导出前先 `flushNow()`，再用 `_flushedUntil` 水位判断
  哪些行已经在文件里，避免同一行出现两次。
- **截断文件也要能读**：进程被杀时最后一行可能是半个汉字，按字节读 + `allowMalformed`
  解码，否则整份现场因为一行解不出来而丢失。
- **800 条要能收敛**：加搜索与级别过滤。排 403 时搜域名比翻列表快得多。

## 没做

- 不做按 tag 的 chips 过滤、不做日志上传。理由见计划文件。

## 验证

- `flutter analyze` 零 issue。
- 新增 16 个用例；全量 `flutter test -j 1` → **298 通过 / 9 跳过 / 0 失败**。
- 未做真机验证：移动端的系统分享面板、桌面端 txt 用记事本打开需要在两个端各点一次。
