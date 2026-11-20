> 记录路径：.agents/logs/changes/20261120/package-id-rename.md

# 包名改为 com.wp.sniffing_browser

- 日期：2026-11-20
- 任务：把 Android 包名从 `com.sniffing.sniffing_browser` 整体替换为 `com.wp.sniffing_browser`（applicationId + namespace + Kotlin 包路径），用户确认旧数据可直接丢弃。
- 内容：
  - `android/app/build.gradle.kts`：`namespace` / `applicationId` 同步改。
  - `android/app/src/main/kotlin/com/sniffing/sniffing_browser/` → `kotlin/com/wp/sniffing_browser/`（git mv 保留历史），4 个 Kotlin 文件的 `package` 声明同步改。
  - 无需改动：Manifest 的 `.MainActivity` 相对命名（按 namespace 解析）、FileProvider 的 `${applicationId}.fileprovider` 占位符、MethodChannel 名 `sniffing_browser/xxx`（Dart 与原生两侧都用同一字面量，与包名无关）。
  - `README.md` 日志路径、`windows/runner/Runner.rc` 的 CompanyName / LegalCopyright 一并跟进为 `com.wp`。
- 结果：`flutter build apk --release` 通过；aapt2 badging 校验包名与中文应用名。旧包名应用需手动卸载，数据不迁移（用户已确认无需保留）。
