> 记录路径：.agents/logs/changes/20261125/gitignore-vscode.md

# .gitignore 整理 .vscode 规则

- 日期：2026-11-25
- 任务：把 `.vscode` 的忽略规则收敛成一条，并去掉 Flutter 模板遗留的注释行。

## 改动

| 位置 | 改动 |
| --- | --- |
| 第 21–24 行 | 模板的 3 行英文注释 + 注释掉的 `#.vscode/` → `# VS Code：个人设置与调试配置不共享` + `.vscode/` |
| 文件末尾 | 删掉孤立的 `#` 与裸规则 `.vscode`（与上面重复）；补回文件尾换行 |

## 为什么这样收

原来有两处在管同一件事：模板留下的解释性注释（规则本身是注释掉的，不生效）和文件末尾手工加的裸
`.vscode`。裸规则没写斜杠也没有前导 `/`，任意层级都会命中——效果正确，但看的人容易以为没配。

`.vscode/settings.json` 里是 Peacock 插件的个人配色（`peacock.color: #a1ece3` 加一整套 workbench
颜色覆盖），入库会把别人的编辑器染成薄荷绿；`launch.json` 只是 `lib/main.dart` 的 debug 启动项，
单人项目没必要共享。所以整目录忽略。

## 验证

- `git check-ignore -v .vscode/launch.json .vscode/settings.json` → 两者都命中 `.gitignore:22:.vscode/`。
- `git ls-files .vscode/` 为空（从未被跟踪，不需要 `git rm --cached`）。
- `git status --short` 只有 `.gitignore` 一处修改。
