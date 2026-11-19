> 记录路径：.agents/logs/reviews/20261111/agp9-proguard-optout.md

# AGP 9 proguard 开关复核

- 日期：2026-11-11
- 任务：复核修复方案的依据、副作用与遗留边界
- 内容：
  - 依据核对：AGP 9.0.1 release notes 明确列出 `android.r8.proguardAndroidTxt.disallowed` 默认值 `false → true`；上游 issue #2765 已于 2026-01-25 修复但 `flutter_inappwebview_android` 最新稳定版仍是 1.1.3（只有 1.2.0-beta.3），所以不能靠升级依赖解决
  - 方案对比：改 pub cache 会被 `pub cache repair` 还原；降 AGP 需连带降 Gradle wrapper 与 Kotlin；官方 opt-out 是唯一进版本控制且改动面最小的路径
  - 副作用核对：插件的 `proguard-rules.pro` 只有 `-dontwarn`，不含 `-dontoptimize`，不会触发 `android.r8.globalOptionsInConsumerRules.disallowed`。opt-out 会让 R8 少做优化，对本期 debug 自用无影响
  - 范围核对：`git diff --stat` 无 pubspec.yaml / pubspec.lock 变化；Windows 构建不读该文件
- 结果：通过。待办：插件发布含修复的稳定版后删除该行；release 构建（开启 minify）尚未验证；F5 装到模拟器并跑 A1~A6 仍待用户执行
