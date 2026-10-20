# Claude Code 配置兼容性与真实请求验证

## 问题与参考契约

旧 Magpie 菜单使用 `provider/model` 作为其网关内部选择器。将 Claude 的连接改为 CPA 后，角色槽可能已经使用 CPA 的裸 ID，追加菜单、后台模型及能力关联键却继续保留 Magpie 选择器，选择后返回 `unknown provider for model codex/...`。此前菜单展示回归只打开了 `/model`，没有选择模型并发送请求，不能证明旧选择器在 CPA 可用。

固定版本核对所得契约：

- [Magpie 模型选择器与解析](https://github.com/yetone/magpie/blob/94919109cb3b9d4241bb957c9e571c6f4c236d2f/internal/provider/models.go#L2384)：选择器带提供商前缀，由 Magpie 自己的 Resolve 解释；展示名称、说明与请求身份分别维护。
- [CC Switch 路由栈](https://github.com/farion1231/cc-switch/blob/77c6dc793d4fbc13bc96163d55d747b02f887a8b/src-tauri/src/mode/stack.rs#L204)：客户端选择器与上游 ID 分开；自家代理负责解析，不能直接复制其编码到另一个后端。
- [CPA 模型注册查询](https://github.com/router-for-me/CLIProxyAPI/blob/2422c6b0f5fe16495320fa29456493874c1977a0/internal/util/provider.go#L29)：按注册 ID 查询，不自动剥离所有提供商前缀。[显式前缀注册](https://github.com/router-for-me/CLIProxyAPI/blob/2422c6b0f5fe16495320fa29456493874c1977a0/sdk/cliproxy/service_models.go#L702)仍是合法能力，不能把带斜杠的 ID 一律改成裸 ID。

菜单中的平台和账号仍只是既有说明，不表示固定由该账号执行；本轮不改变 CPA 路由策略。

## 业务归属与统一规则

`Shared/AgentClients/Models/Claude/ClaudeConfigurationPlan.swift` 是无服务、无任务的纯值计划。原配置 ViewModel 继续持有目录、会话与请求世代；原配置 actor 继续负责读取最新文件、备份及写入。没有迁移状态或 Task 所有权。

角色槽、Default、独立子代理、追加菜单、`ANTHROPIC_SMALL_FAST_MODEL`、`CLAUDE_CODE_MODEL_CAPABILITIES` 及 `modelSettings` 的键共用以下规则：

1. 当前后端目录中存在完整 ID 时原样保留，包含合法 `prefix/model`。
2. 仅对已知旧 Magpie 命名 `codex/`、`antigravity/`、`zhipu/`，且完整 ID 不存在、后半段精确存在当前目录时，适配为当前 ID。不会根据名称、归属、大小写或相近型号猜测。
3. 末尾 `[1m]` 独立匹配并保留，原生角色继续交给 Claude CLI 解析。
4. 目录为空、读取失败、缺失型号或未知前缀均保留原值。缺失的已知旧选择器会提示用户，不删除菜单、不推测替代版本，也不把目录缺失等同于官方退役。
5. 模型关联键存在目标冲突时保留两份，不能静默覆盖当前设置；能力正文和不识别片段透传。

`AgentModelCatalogService.Selection` 从**同一次 HTTP 请求**返回完整注册目录与原筛选候选。UI 保留 Copilot 可用性筛选；兼容判断使用未筛选的目录，防止本机账号筛选隐藏合法完整 ID。目录仍通过客户端 `/v1/models` 和客户端 key 读取；CPA 管理接口仍是 `/v8/management`，无管理密钥回退。

原 `AgentSetupViewModel` 校验成功目录的弹窗身份、客户端、URL 和 key；快速切换、关闭重开、连续刷新、改变连接及迟到响应继续受原世代规则保护。没有新增请求、后台轮询或目录状态宿主。

## 预览、保存与数据保留

- `/model` 预览、子代理目标、JSON 和 Shell 输出都消费同一计划。保留 Default、既有布局和高级选项收起行为，没有新增精选卡片或名称输入框。
- 保存时在原 actor 同步事务内重读磁盘。未编辑的菜单采用磁盘最新对象，只局部合并模型引用和已识别的展示元数据；保留顺序、重复账号行、未知字段及大整数，不接管整张菜单。
- 保留未知根字段和 env 扩展值；一个非字符串 env 扩展不能导致其他有效键被清空。
- 无法读取或非空且不是有效 JSON 对象的原文件会在写入前失败，避免把原文件当首次配置覆盖。空文件仍支持首次配置。
- 沿用原备份和恢复路径；重复保存保持结果稳定，未运行用户真实配置迁移。
- 需要改动既有 JSON 引用时，自动保存为 Shell-only 会提示改用 JSON／同时保存。手动模式仍可预览完整 JSON 与 Shell。

名称按迁移前的 ID 判断。只有“原自定义名称恰好等于迁移后 ID”的歧义场景，才保存 `quotioModelNameBindings` 的最小模型／名称绑定，供下次回读识别；CLI 实际名称仍使用原 `_NAME` 字段。绑定同时验证目标 ID 和磁盘当前名称，外部改名及换模型不会套用旧值。正常自定义名称不增加绑定；绑定字典中的未知扩展字段保留。角色 `[1m]` 的自动菜单标题也保留原有 ` · 1M` 标识。

## 本地假网关验证

`ClaudeCLIRequestCompatibilityTests` 调用生产配置生成服务，将结果写入临时 home，再运行本机 Claude CLI **2.1.292**。使用 `--bare --setting-sources '' --settings`、独立 `CLAUDE_CONFIG_DIR`、假密钥、无工具和无会话持久化；不覆盖 HOME，不读取用户真实凭据。假网关仅监听动态 loopback 端口，返回本地 Anthropic SSE，不转发真实推理。

| 选择来源 | 捕获的 `POST /v1/messages` 模型 | 结果 |
|---|---|---|
| 生成配置的默认模型 | `gpt-6.1-sol` | 旧 `codex/` 身份已适配 |
| 原生 `sonnet` 角色 | `gpt-6-astra` | 使用统一槽位映射 |
| 生成追加菜单的第一项 | `gpt-6-astra` | 不再把旧网关选择器直接发送 CPA |
| 生成追加菜单的合法前缀项 | `glm/glm-5.3` | 完整 ID 保留 |
| 生成追加菜单的 `[1m]` 项 | `gpt-6.1-sol` | 配置保留 `[1m]`，CLI 使用 `anthropic-beta: context-1m-2025-08-07` 表达长上下文 |

五个独立 CLI 进程均成功得到本地响应，模型和假认证断言通过；最终单独重跑也验证了带 `quotioModelNameBindings` 的真实生成配置能够被 CLI 正常读取。测试附件只保留模型、beta 和假密钥是否匹配，不保留请求全文或密钥。

本验证通过生成菜单的实际 `model` 值传给 CLI `--model` 来发请求，没有操作用户现有交互式会话；它证明选择器的传输，不证明某个真实提供商接受所有能力参数。独立子代理及 Fable 的配置联动由配置定向回归覆盖，本用例没有触发真实子代理任务。

## 验证与限制

- 应用 Debug 构建通过。
- 定向验证包含兼容计划、磁盘合并、名称重开保存、菜单与 Fable 展示、原配置规则、会话隔离、模型读取业务及真实 CLI 请求；严格按测试类选择，未运行全量测试。
- 主轮 8 个相关测试类共 105 项通过；最后补充 1M 标题用例后，重跑兼容／菜单／展示相关 46 项通过，合计覆盖 106 个不同用例，零失败。此前首次配置和目录失败重试的 3 项定向验证也通过。
- 只读复核提出的原始目录证据、名称碰撞及 1M 标题问题均已处理并补回归。
- 结果与脱敏附件：`/tmp/quotio-claude-compatibility-final-20261019.xcresult`、`/tmp/quotio-claude-wire-evidence-20261019`；最后 1M 标题补充回归：`/tmp/quotio-claude-compatibility-label-final-20261019.xcresult`；最终真实 CLI 复验：`/tmp/quotio-claude-wire-final-20261019.xcresult`。
- 本轮不发布安装包、不替换本机应用、不直接修改 `~/.claude/settings.json`。用户使用升级后的配置页保存时，才会按当时成功读取的目录执行适配。缺失的旧型号仍需用户明确选择或手动调整，不能宣称自动全部修复。
