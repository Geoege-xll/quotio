# 技能来源与仓库分组

已安装技能按真实 GitHub `owner/repo` 归组。同一仓库下的多个技能可以折叠，分支、技能目录和启用状态仍分别保存。“地址”按钮打开仓库首页。来源不完整的技能保留在“本地 / 来源未记录”，不按名称前缀或用途推断仓库。

## 来源优先级

1. Quotio SQLite 中已有的来源字段优先，包括不完整或暂不支持解析的旧来源。
2. 来源完全缺失时，读取 skills CLI 的 GitHub 安装记录。已有同名私有技能时，必须确认共享目录指向私有技能，或两份完整内容相同。
3. 同一仓库、同一 Git ref 的外部记录可补缺失的仓库内路径；不同分支不能混用路径。
4. 历史安装没有任何记录时，保持来源未知。维护工具可根据明确指定的仓库历史文件证据补齐，不自动扫描网页或执行技能正文。

## skills.sh 安装适配

skills.sh 是发现和安装入口，分组身份仍使用对应的 GitHub 仓库。适配依据为 [skills CLI 全局 lock 源码](https://github.com/vercel-labs/skills/blob/main/src/skill-lock.ts)：

- 全局记录默认位于 `~/.agents/.skill-lock.json`；设置了绝对路径 `XDG_STATE_HOME` 时使用 `$XDG_STATE_HOME/skills/.skill-lock.json`。
- 使用 `sourceType=github`、`source` / `sourceUrl`、`ref`、`skillPath`、`installedAt`、`updatedAt`。
- `ref` 缺失时使用仓库默认引用 `HEAD`；兼容已有 `branch` 字段。
- `skillFolderHash` 是 Git tree SHA，不作为 Quotio 自己的目录内容哈希。
- 每次刷新读取最新全局记录。读取不写 SQLite、不更改外部 lock，也不恢复用户已经删除的发现仓库。
- 项目级 `skills-lock.json` 不混入全局统一库；项目内的同名技能不一定与全局技能同源。

## 修复缺少来源的历史安装

`scripts/repair_skill_sources.py` 接受已经准备好的 GitHub 仓库本地快照。先使用默认只读模式查看计划：

```sh
python3 scripts/repair_skill_sources.py --home /path/to/home \
  --checkout /tmp/verified-repository
```

核实计划后，同一命令加 `--apply` 执行补齐。脚本遍历已存在的 Git 历史树，要求同名目录的 `SKILL.md` 原始字节及执行位一致；记录其它文件差异、匹配提交和仓库路径。多个仓库或路径同时匹配时保持未知，不选择一个来源。仓库 remote 仅是指定来源的标识，调用者应先核实准备该快照的地址。

同一仓库迁移过目录时，只有当前 HEAD 中同名技能路径唯一，并且该现存路径也有匹配本机正文的历史版本，才使用现存路径。证据同时保留旧路径及当前提交；多个仓库或多个现存路径的歧义仍不自动解决。

写入前通过 SQLite backup API 保存包含已提交 WAL 的一致备份。事务只补缺失来源，保留技能内容、时间、内容哈希、名称、备注和客户端配置，不更改发现仓库列表。写入失败或核实后技能发生变化时回滚。再次运行时跳过已有来源，保证幂等。

备份与逐技能证据保存在 `~/.quotio/skill_backups/source-repair-*/`。证据状态 `pending_commit` 表示不能确认已提交，需要检查数据库；只有数据库提交成功后才改为 `complete`。

## 验证

- `WorkspaceSkillRepositoryGroupTests`：地址规范化、稳定仓库身份、不同 owner、搜索和未知来源。
- `WorkspaceSkillSourceTests`：后装记录、XDG 路径注入、只读行为、同名冲突、来源优先级和跨分支路径保护。
- `WorkspaceSkillSafetyTests`：完整目录安装、更新、纳管、卸载及客户端配置保护。
- `python3 -m unittest discover -s scripts/tests -p 'test_repair_skill_sources.py' -v`：历史来源比对、幂等、冲突保留、文件变更拒绝、SQL 写入/提交失败回滚及备份。
