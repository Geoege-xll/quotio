# Claude Code 子代理配置修复

## 业务归属与保留边界

子代理模型是客户端配置能力，不属于账号路由、模型目录或菜单展示。`Shared/AgentClients/Models/Claude/ClaudeSubagentSettings.swift` 集中管理默认值、原生 `inherit`、布尔强制开关与 JSON/Shell 冲突规则，页面和配置服务共用；不为文件行数拆分，也不新增任务或单例。

`AgentConfiguration` 继续保存原草稿，新增可选原始字符串 `claudeSubagentModelForce`。`AgentSetupViewModel` 继续持有页面、回填、请求世代和保存任务，`AgentConfigurationService` 继续持有最新磁盘读取、备份与合并事务。已有 `private(set)`、模式切换和保存后状态提交顺序不变。新增折叠状态只归现有高级视图，原账号布局、模型目录及其他 agent 的修改不回退。

## 修复内容

1. **仅 Shell 保存冲突**：配置服务在读取最新磁盘后、备份或写文件前，检查 JSON 中已有子代理模型、强制开关和所引用角色的映射。新目标无法覆盖旧 JSON 时明确要求 JSON 或 JSON＋Shell，不再返回配置成功。没有冲突或行为等价时继续支持仅 Shell。页面提前使用原保存基线提示，最终以服务层最新读取为准。
2. **手动输出**：仅 Shell 冲突同样拦截；同时提供 JSON/Shell 的手动预览保留两份内容，但明确提示 Shell 需要配合 JSON，不再声称可以独立二选一。
3. **强制开关兼容**：回读、Codable、保存、Shell 和恢复官方连接均覆盖 `CLAUDE_CODE_SUBAGENT_MODEL_FORCE`。普通保存保留已有字符串，包括只配置 FORCE 的合法形式。开启状态显示提示，编辑入口放在默认收起的“子代理高级选项”；新增开启操作对已知低于 2.1.257 的 CLI 提示升级，已有值不因客户端降级而阻止无关保存。
4. **继承与文案**：分段为“使用默认规则／指定默认模型”。原生 `inherit` 按默认规则回显，原值继续保存。用户明确从指定模型恢复默认时，写入 `inherit` 和空 FORCE，避免仅保存 JSON 后又继承旧 Shell 的覆盖值；代理自身及单次调用仍遵循 CLI 的优先级。

## 官方语义与实际校验

[官方子代理模型文档](https://code.claude.com/docs/en/sub-agents#choose-a-model)说明默认模型优先级，以及[强制覆盖](https://code.claude.com/docs/en/sub-agents#run-every-subagent-on-one-model)的版本要求和例外。普通默认值不会覆盖子代理自身声明；Explore、Plan、会话分叉及继承模型的技能按 CLI 规则执行。

本机 CLI 2.1.292 对布尔环境变量还有统一解析层：`1/true/yes/on` 为开启，忽略大小写及首尾空白；`0/false` 不开启。初次回归发现仅按使用处的字符串真值判断不准确，已修正并以真实请求覆盖该边界。兼容回显解析布尔值，持久化保留原始字符串，不把旧关闭值错误改成开启。

## 定向验证

- Debug 构建通过；仅运行相关 `-only-testing:QuotioPlusTests/...`，未执行全量测试。
- 20 项相关用例零失败，包含保存失败不改文件／不生成备份、最新磁盘冲突、角色映射、旧草稿解码、未知字段保留、版本校验及现有兼容性回归。
- `ClaudeCLIRequestCompatibilityTests` 使用生产生成器、真实 CLI 和仅监听 `127.0.0.1` 的假网关，验证 11 组真实子代理调用：默认值尊重定义、强制角色和 1M、`inherit` 压住旧 Shell、关闭后尊重定义、旧 `0/false/YES`、仅 Shell 新配置、冲突切换到 JSON＋Shell、合法前缀及独立 1M、只开启 FORCE。
- 每组确认实际启动并完成一个子代理，捕获主会话→子请求→主会话收尾。复用夹具同时验证原默认模型／角色／菜单的 5 组主会话请求。所有请求使用假密钥，不转发到真实服务。
- 560pt 浅色、760pt 深色的真实 SwiftUI 宿主截图确认默认折叠和强制状态提示；展示前后草稿不变。
- 测试结果：`/tmp/quotio-claude-subagent-targeted-final-20261019.xcresult`；脱敏请求与截图：`/tmp/quotio-claude-subagent-evidence-final-20261019`。最后的业务归位与手动提示补充回归 10 项零失败：`/tmp/quotio-claude-subagent-followup-20261019.xcresult`。

本轮不发布安装包，不替换本机应用，不修改用户真实 Claude 配置。修复将在用户通过配置页保存时生效。
