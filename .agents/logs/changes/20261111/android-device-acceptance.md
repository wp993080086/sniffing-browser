> 记录路径：.agents/logs/changes/20261111/android-device-acceptance.md

# 补本期范围与验收口径

- 日期：2026-11-11
- 任务：按用户选定的方向（Android 真机最小验证 + 补一页验收口径）修改技术方案
- 内容：
  - `docs/tech-design.md` 第 8 章章首新增 `8.0 本期范围与验收口径`：本期目标、端优先级、不做清单、A1~A6 + W1 验收用例、真机前置、异常产品行为、交付与非功能约定。用 8.0 小节而非新增一级章节，避免章节号位移破坏 `.agents/rules/01` 对「第 9 节合规说明」的引用
  - 同章状态表「1 嗅探」由「完成」改为「代码完成，移动端待验收」，消除与 8.0 A2 的冲突
  - A6 收窄为「嗅探时缓存的 Referer / UA」，因为 `CookieManager` 未接入；W1 补 ffmpeg 与 `NO_PROXY` 前提
  - 未改 `pubspec.yaml`、`README.md`、`lib/`、`android/`
- 结果：章节 0~10 编号不变，代码块围栏 56 个成对；文中引用的计数器、类名、方法均在 `lib/` 中检索到；`git diff --stat` 仅 `docs/tech-design.md`
- 追加（同日，W1 回归）：执行 `dart run tools/verify_download.dart`（12/12）、`RUN_E2E=1` 的 `download_queue_e2e_test.dart`（3/3）与 `transcode_e2e_test.dart`（5/5），合计 20 项全绿；`flutter test` 自动跑了 pub get，`pubspec.lock` 无变化。8.0 补「W1 已执行」记录，真机前置补 Android 明文流量限制（main manifest 无 `usesCleartextTraffic`，A1/A4 需用 https 站点）。未改任何源码。
- 追加（同日，运行环境核实）：`android/local.properties` 指向 `C:\Users\Administrator\AppData\Local\Android\Sdk`，`platform-tools/adb.exe` 存在但未进 PATH，`emulator -list-avds` 返回 `Pixel_5_API_34` / `Pixel_6_API_35`，`adb devices` 为空（模拟器未启动）。8.0「真机前置（当前开发环境未满足）」改为「运行环境（本机已具备）」，补 AVD 可用与 A2 建议真机复验的说明。此前「adb 不在 PATH = 缺环境」的判断已更正。
