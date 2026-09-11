# 智能体管理：功能修复与私有技能库迁移

日期：2026-09-11。范围：智能体管理中的会话、技能、存储以及本机技能库迁移。按照用户要求保留已定稿的 UI 样式；界面仅调整操作接线、加载与禁用状态、层级数据及路径文案。

## 技能库与客户端独立开关

完整技能统一存放在 `~/.quotio/skills/<directory>`。`~/.agents/skills` 是 Codex 的原生发现目录，不能同时充当私有库存，否则删掉另一个客户端的分发链接后，技能仍可能被兼容扫描发现。

各客户端通过逐技能软链接获取内容。Codex 同步发现路径、私有真实路径和旧 `.codex/skills` 路径对应的原生 `skills.config` 开关；OpenCode 使用精确的 `permission.skill` 权限，避免扫描 Claude/Codex 目录时绕过独立开关。编辑器保留其他模型、提供商、MCP 配置和 JSONC 注释；无法安全合并的 TOML 内联表拒绝写入。

技能读取和服务构造不再迁移、删除用户目录或自动清理断链。显式 `prepareStorage()` 只初始化 Quotio 自有目录和数据库，使用一次性迁移标记导入已有来源信息，不把用户删掉的仓库重新加回来。

安装与更新下载固定 Git 提交下的完整技能子目录，保留脚本、引用文件和可执行权限；仓库来源包含真实相对路径，支持嵌套目录。下载完成并校验后才替换正式目录；同一技能在网络等待期间禁止交错修改。备份使用独立 UUID 路径，失败会中止操作。纳管同名内容时保护双方版本和原有来源元数据；卸载只处理指向该技能的受管链接，不删除客户端独立目录。

## 会话与存储

- Claude 恢复使用 `claude --resume`；客户端名和会话参数分别进行 shell 转义，工作目录缺失时进入实际 home。终端启动失败会上报。
- Pi 按真实 session header 和内嵌 message 读取，不把消息父节点误当父会话。
- 会话树支持全部后代、缺失父记录和循环保护；搜索子任务时保留祖先路径，同名项目按真实路径区分。
- 删除前校验客户端根目录、每一级路径和 SQLite 定位符，拒绝越界及 home 内软链接。数据库写入使用事务；正文先隔离，数据库失败后恢复。
- 存储统计与清理共用逻辑会话和附件计划，包含数据库记录及 Antigravity 正文；同一附件只计一次。预览后的新会话、活跃后代或来源变化使整棵候选树退出清理。清理专用约束传入删除事务，在取得数据库写锁后再次核对后代和活动时间；文件只按冻结快照处理，隔离后提交前再次核验，不递归扩大目录范围。
- 缓存清理避开锁文件、在线状态和 Codex 临时执行目录，保留扫描后新增的文件。容量按实际文件减少量报告，不把 SQLite 行删除当成整个数据库空间已释放。
- 部分失败保留失败项目并显示原因，不再无条件显示全部成功。

## 状态与封装

ViewModel 注入会话、技能、存储协议，测试使用临时 home 或内存替身。会话扫描、正文加载、仓库发现和本地技能读取具有独立请求身份。删除旧客户端会话不会废弃新客户端扫描；仓库增删与刷新使用数据版本保护，首次加载期间新增仓库也以最新持久化列表为基准。

## 验证记录

智能体管理最终集成测试：76 项通过，0 失败，0 跳过。

结果包：`build/ClaudeDefaultRowDerivedData/Logs/Test/Test-Quotio-2026.09.11_09-51-06-+0800.xcresult`。

范围包含 `WorkspaceTests`、`WorkspaceSkillSafetyTests`、`WorkspaceSessionSafetyTests`、`WorkspaceStorageSafetyTests`、`WorkspaceViewModelSafetyTests`。覆盖目录冲突、备份及更新失败、原生技能权限、递归删除、SQL 故障回滚、路径和软链接保护、清理预览一致性，以及受控异步返回顺序。

关联回归：100 项通过，0 失败，0 跳过，覆盖 OpenCode 配置编辑器、Claude/Codex 模型配置、仪表盘以及输入／输出／缓存趋势。

结果包：`build/ClaudeDefaultRowDerivedData/Logs/Test/Test-Quotio-2026.09.11_09-37-46-+0800.xcresult`。

Python 迁移工具 12 项测试通过，包含默认只读、目标冲突、权限和符号链接、各阶段故障回滚、外部并发写入保留，以及 `/var` 和 `/private/var` 系统别名。Codex 配置另经独立 Swift 输出与 Python `tomllib` 解析验证 5 个场景。

## 本机迁移结果

2026-09-11 09:52:49 已执行用户授权的本机迁移。迁移前退出旧构建，迁移后调用新构建中的实际技能服务完成建库和读取，并启动新构建。

- 私有库：`/Users/liqunmacmini/.quotio/skills`。
- 完整技能：49 个，312 个文件，5,127,790 字节；文件 SHA-256、字节数和权限与备份逐项一致。
- 原始备份：`/Users/liqunmacmini/.quotio/skill_backups/migration-20260911-095249-e144fc773dbb467bb1279bcfe4d86732`，权限 `0700`。包含 `original-skills`、原客户端配置、SQLite 一致性副本和 `manifest.json`。
- 原生发现目录 `~/.agents/skills` 保留 47 个逐技能链接；111 个既有客户端链接改向私有库，OpenCode 增加 23 个专属链接以保持原有实际可用集合。
- Codex 原来关闭的 `grok-image-to-video` 和 `minimax-image-to-video` 保持关闭。原 Codex 配置完整保留并追加必要的禁用路径身份；其他客户端配置及 `.agents/.skill-lock.json` 保持原字节。
- 数据库 `quick_check` 通过；原有技能元数据保留，私有库 schema 准备完成。

实际服务读取结果：49 个已安装、0 个未纳管。

| 客户端 | 迁移后启用数量 |
| --- | ---: |
| Claude Code | 29 |
| Codex | 47 |
| OpenCode | 49 |
| Antigravity | 29 |
| Pi | 0 |

本轮未执行真实会话删除或缓存清理。已打开的客户端会话应重新启动以重新载入技能目录和原生权限。

新版运行包：`/Users/liqunmacmini/Desktop/quotio/build/ClaudeDefaultRowDerivedData/Build/Products/Debug/Quotio.app`。

可复用迁移工具：`scripts/migrate_workspace_skills.py`。默认仅预检，实际执行需显式提供 `--apply --home`；已迁移目录再次执行会拒绝将发现链接作为待迁移的真实技能。
