# 会话浏览的身份与关系适配

核验日期：2026-09-14。适用范围：智能体管理中的 Codex、Claude Code、AGY 会话发现、主列表筛选及已知后代的删除。界面沿用现有布局。

## 统一约束

`WorkspaceSessionRelationship` 区分主会话、子代理、内部旁支和未知四种身份。左侧入口仅接受 `main`。父记录不存在、无父 ID、损坏的循环关系均不能把子代理或内部旁支提升为主会话。全量记录仍在扫描结果中，存储核查与清理不受浏览过滤影响。

`WorkspaceSessionTree.roots` 只是保证完整遍历的图入口，包含孤立节点和环入口，不代表产品意义的主会话。项目分组只按主会话归组，不使用 `agent_workflow`、guardian、标题或正文等关键词判断身份。

不同来源通过 `WorkspaceSessionAccumulator` 按客户端与 ID 去重。先到的来源保留展示字段；后续来源继续补充关系。明确的子代理或内部旁支证据不能被缺省主身份覆盖。父 ID 冲突时保留优先来源，不把同一记录挂入两棵树。

## 官方依据与实现边界

### Codex

- [官方 App Server 文档](https://learn.chatgpt.com/docs/app-server) 区分交互线程来源、多种 `subAgent` 来源、直接子线程与后代查询；普通 fork 的来源关系和执行子线程关系分开定义。文档还说明默认会结合 rollout 修复数据库元数据。
- 本机官方 Codex **0.153.4** 执行 `codex app-server generate-json-schema --out <临时目录>` 导出的 `SessionSource` 包含 `cli/vscode/exec/appServer/unknown`、`custom` 和 `subAgent`；`SubAgentSource` 包含 review、compact、memory_consolidation、thread_spawn、other。该命令只导出协议，不发起模型调用。
- 本机 SQLite 与 rollout 使用 `subagent`，API schema 使用 `subAgent`；两种拼写均由适配器识别。`other: guardian` 没有父 ID，仍明确属于子代理来源。
- 执行父关系只读取边表或 `source.subagent.thread_spawn.parent_thread_id`（兼容 API 大写 A）。`forkedFromId`、消息链 parent、任意嵌套同名字段及带多个 UUID 的文件名均不作为执行父关系。
- 数据库列按需探测；缺少 nickname、role 或边表不能让整个数据库扫描失败。未知 source 保留为 unknown。

### Claude Code

- [官方 Subagents 文档](https://code.claude.com/docs/en/subagents) 规定子代理记录位置为 `~/.claude/projects/{project}/{sessionId}/subagents/agent-{agentId}.jsonl`，并允许使用自定义 agent 作为主线程。
- [官方 Agent SDK session storage](https://code.claude.com/docs/en/agent-sdk/session-storage) 使用主 session key 与子路径区分记录；会话 fork 会重写会话与消息身份，不能笼统把 fork 或消息 parentUuid 当执行父关系。
- [官方 Python SDK 的会话枚举源码](https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/_internal/sessions.py) 在会话列表中排除 `isSidechain=true` 记录。
- 本机核验版本为 **2.1.236**。路径中的所属 session 目录给出父 ID；头部 sidechain 给出子身份。平铺 sidechain 可能与主会话共享 sessionId，使用 agent 文件身份防止重复 ID，但不猜共享 sessionId 就是父 ID。
- `agentName/agentId` 单独存在不作为子代理证据。空字典或未识别的元数据保留 unknown。

### AGY

- [官方 CLI Subagents 文档](https://antigravity.google/docs/cli/subagents/) 允许 custom agent 直接作为 primary；[官方 Agents 命令](https://antigravity.google/docs/cli/commands/agents/) 说明在现有会话切换主 agent 会 fork。因此自定义名称和普通 fork 均不能等同 subagent。
- [官方 Subagents 说明](https://antigravity.google/docs/subagents) 描述子代理嵌套层级；公开文档未承诺 SQLite 列和 JSON 缓存格式是稳定外部接口。
- [官方 CLI 1.1.4 更新记录](https://github.com/google-antigravity/antigravity-cli/blob/main/CHANGELOG.md#114) 明确修复 `/btw` 侧问以重复条目泄漏到普通会话列表的问题。
- 本机官方 **1.2.2** 二进制核验：SHA-256 `cabadc15a61944372bede1fdff186701c17467dd9d718e97dc79283055d3c101`。符号 `backend.isInternalTrajectory` 在 `0x10218eb10`，判断 SubagentSpec、ParentConversationId、IsBattleModeFork 以及 SIDE_QUESTION=22。`loadSummaryFromFile` 与缓存写入调用链将结果写入 `cachedConversation.IsInternal`，JSON 标签为 `is_internal`。
- 这属于指定版本官方程序实现证据，**不冒充公开存储协议**。`is_internal=true` 只判内部会话，不能反推具体子类型或父 ID。`nesting_depth>0` 提供子代理层级证据；只有 parent 时保留内部旁支身份与原生父关系。
- 摘要库、已识别的旧 JSON 摘要、缓存 summary 提供展示信息。缓存只补仍存在实体记录的会话，避免已删除记录复活。缓存 `is_internal=false` 支持主身份；任意可解码 JSON、空 summary、裸 `.db` 或只有 brain 正文不等于已知主会话。
- brain 正文不承担关系推断。优先完整 transcript 的读取行为保留；缺失缓存与未知格式的记录保留 unknown，等待有效元数据。

## 删除与验证

普通删除与受约束清理都采用合并后的已知关系。事务内数据库关系优先于扫描快照，文件补充数据库缺失的后代；无法确定父关系的辅助记录不参与猜测性级联。原有路径白名单、冻结清理约束、事务重查和回滚保护继续生效。

`WorkspaceSessionRelationshipTests` 覆盖原生 source、sidechain、AGY internal、未知结构、可选列缺失、多来源覆盖与去重、普通 fork 不误判、数据库主记录与文件子记录的实际级联删除，并把扫描结果送入 ViewModel 核验主列表和项目分组。测试数据全部写入独立临时 home。

2026-09-14 最终验证：macOS Debug 构建成功，五组 Workspace 回归测试共 **69 项通过、0 失败**，`git diff --check` 通过。独立复核另用已编译模块重跑空 AGY 摘要、Codex 缺正文路径列、Claude 平铺与标准目录同 ID 三组反例，均确认修复。

实际 Provider 的本机扫描核对结果如下。Codex、Claude 只读扫描原始记录；AGY 使用摘要库（含 WAL）、缓存和文件存在性的隔离副本验证，brain 仅使用占位内容。此检查不执行删除，不输出真实会话标题或正文。

| 客户端 | 记录总数 | 主入口 | 子代理 | 内部旁支 | 重复 ID |
| --- | ---: | ---: | ---: | ---: | ---: |
| Codex | 1199 | 30 | 1169 | 0 | 0 |
| Claude | 84 | 16 | 68 | 0 | 0 |
| AGY 元数据副本 | 72 | 34 | 0 | 38 | 0 |

Codex 的 `agent_workflow` 项目共 169 条记录，保留 **12 条主会话**，157 条子代理不再作为主入口。全量 Codex 记录中，原来直接采用图根入口的方式会将 651 条非主记录纳入入口集合；新列表按统一身份筛选。数字为本次核验快照，客户端继续运行后会变化。
