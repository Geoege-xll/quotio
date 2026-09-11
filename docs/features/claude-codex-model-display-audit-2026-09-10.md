# Claude Code 与 Codex CLI 模型显示检查

## 需求依据

历史开发约定将 Claude 模型槽分成「角色 → 实际请求模型 → 显示名称」：显示名称可以编辑，修改名称不改变请求目标。9 月 10 日的实现曾在留空时使用模型 ID；9 月 11 日根据会话内面板的实测，已改为留空保留角色名，详见 [会话内模型面板修复](claude-model-picker-roles-2026-09-11.md)。默认模型独立于三个槽。此处没有将 Claude 菜单强制限制为三项，也没有将任意显示名称当作 `/model` 的角色参数。

## Claude Code：网关目录混入兼容名称

本机核验版本为 Claude Code `2.1.236`、CLIProxyAPI `7.2.154`。旧生成器固定写入 `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1`。本机代理向 Anthropic 客户端返回的模型目录包含 `claude-fable-5-dd-` 前缀及反转 ID；CPA 程序具有对应的兼容 ID 生成和解析函数。这不是模型槽中自定义显示名称造成的。Claude 该版本对发现条目使用 `From gateway` 说明。

本轮修改：

- 增加「在 /model 中显示其他网关模型」开关。新配置默认关闭，已明确保存的开关按原值回填。关闭时显式输出 `0`，覆盖旧配置中的 `1`。
- 增加槽补全预览，共用真实配置生成算法，显示角色、名称和实际请求 ID；逐槽 1M 后缀也同步预览。
- 继续输出官方角色映射、`_NAME` 和 `_DESCRIPTION`，不改代理别名策略，不覆盖 `availableModels`。
- JSON 默认选择使用顶层 `model`，配合 `ANTHROPIC_DEFAULT_MODEL`，并清理旧 JSON 中的 `ANTHROPIC_MODEL`，使 `/model` 后续保存的选择优先生效。
- 自动同时保存 JSON 和 Shell 时，Shell 清除旧强制模型。独立 Shell 及可单独复制的手动 Shell 方案保留显式启动变量，避免已有 JSON 覆盖 Shell 新选择，也兼容 Haiku。

本机隔离实测中，三个名称正确显示为「主力推理」「日常编码」「快速任务」。开启发现时增加缓存网关条目，关闭后忽略这些条目；客户端自身的默认项及其他原生条目由 Claude 决定。选择 Sonnet 后，Claude 写入 `model=sonnet`，重启使用对应 `glm-5.3`。

仅保存 JSON 不会修改用户既有 Shell profile 中的强制变量。曾使用两种存储方式或仅 Shell 配置的用户，可选择同时保存两种配置并新开终端，完成受管 Shell 配置的迁移。

## 默认模型合并与独立 1M

后续按用户确认的方案，将「默认」作为模型用途表格第一行，与 Opus、Sonnet、Haiku 共用模型选择、名称与 1M 列，去掉原先单独的默认模型区域。默认行复用可搜索的选择器；名称只读展示所选模型或角色的名称，不创建无法被 Claude 原生 Default 标题识别的名称字段。

- 直接指定模型或代理别名时，默认行独立保存 `claudeDefaultModel1M`。与任意角色选择同一个 ID，也不会自动继承该角色的上下文设置。
- 明确选择跟随角色时，JSON 保存普通角色标识，如 `opus`；角色映射及其 1M 后缀由 Claude 解析。默认开关只读显示「继承」，重新打开配置仍保留角色关系。
- 外部 `opus[1m]` 等完整角色选择器保持显式语义，不改写 Opus 槽自身的开关。用户关闭额外覆盖时，回到普通角色继承。
- `[1M]` 等旧来源后缀兼容读取，输出规范化为单个小写 `[1m]`。默认行与角色共用规范化规则、请求预览及保存算法。
- 全局 `CLAUDE_CODE_MAX_CONTEXT_TOKENS` 保留用户普通窗口值。1M 由模型自己的后缀控制；不会因某一行开启就将其他普通模型的窗口提升到 1M。高级设置说明及提示同步覆盖默认行。

参考了 [cc-switch 的 Claude 表单默认 1M 控件](https://github.com/farion1231/cc-switch/blob/main/src/components/providers/forms/ClaudeFormFields.tsx#L1004) 与 [模型状态处理](https://github.com/farion1231/cc-switch/blob/main/src/components/providers/forms/hooks/useModelState.ts)。写入行为继续遵循本机 Claude 版本，保留上一轮修复的默认模型持久化机制。

Claude Code `2.1.236` 隔离实测：全局普通窗口均为 275,000，默认 `opus` 搭配槽 `custom/model[1m]` 时 `/context` 为 1M；默认 `opus[1m]` 搭配普通槽也为 1M；默认 `opus` 搭配普通槽则为 275K。完成原生迁移后重新启动，普通 `opus` 选择保持不变。原生迁移可能对旧配置额外写入 `opus[1m]`，因此回填保留这种显式选择。

本次默认行合并的最终 Debug 构建及 50 项相关回归测试通过，0 失败、0 跳过。结果包：`build/ClaudeDefaultRowDerivedData/Logs/Test/Test-Quotio-2026.09.10_13-22-21-+0800.xcresult`；日志：`/tmp/quotio-default-row-verified-tests.log`。已检查 `build/ClaudeDefaultRowReview/` 内独立配置、角色继承各自的浅色和深色预览。

## Codex CLI：启动选择与菜单目录分离

本机核验版本为 Codex CLI `0.153.4`。Quotio 为它保存 `model`、`model_provider` 和 `model_reasoning_effort`，没有写入 Claude 的角色映射、名称或网关发现环境变量。

使用独立配置目录、测试密钥和本机关闭端口验证：

1. 设置 `model="quotio-custom-model"` 后，启动栏显示该模型和 `high`，证明默认选择生效。
2. `/model` 面板仍列出 Codex 自身目录，如 `gpt-6-astra`、`gpt-5.6-sol` 等，没有自动加入该自定义 ID。面板提示可通过 `codex -m` 或 `config.toml` 指定其他模型。
3. 在面板选择 `gpt-5.6-sol / high` 后，顶层配置更新，代理仍为 `cliproxyapi`；重启保持新选择。

因此 Codex 没有复现 Claude 的兼容长名称或旧强制环境变量问题，但存在用户容易混淆的目录差异：保存默认模型或 CPA 别名不等于同步 `/model` 菜单。界面已补充说明，并为保留用户自定义 `model_catalog_json` 和回读 CLI 新选择增加回归测试。本轮没有自动创建或替换用户模型目录。

官方提供 `model_catalog_json` 作为启动时加载独立 JSON 模型目录的入口；它需要独立的目录集成，不能通过照搬 Claude 的 `_NAME` 环境变量实现。

## 验证与边界

所有 CLI 验证均在临时配置目录执行，没有发送模型推理请求，没有改写真实客户端登录态或代理配置。SwiftUI 模型槽已通过 AppKit 实际渲染检查浅色与深色布局。

相关测试覆盖模型槽名称与请求 ID、1M 后缀、网关开关保存回读、旧强制模型迁移、独立 Shell 和手动备选输出，以及 Codex 模型目录保留和模型回填。

上一轮网关显示优化的 Debug 构建及 84 项回归测试通过，0 失败、0 跳过，以 xcresult 结构化摘要为准。覆盖 Claude 配置、Codex 模型配置、Codex 思考强度、Codex 凭据保护与备份删除。结果包位于 `build/ClaudeModelDisplayDerivedData/Logs/Test/Test-Quotio-2026.09.10_12-07-36-+0800.xcresult`，日志为 `/tmp/quotio-claude-codex-model-tests-final.log`。独立增量审查通过。

回归过程中还修复了测试启动隔离缺口：Scene 在进入测试窗口分支之前就访问 `AppBootstrap.shared`，触发真实代理初始化和钥匙串读取。`setupBootstrapOpenWindow()` 现在复用现有单元测试判定，在访问单例前返回，普通应用启动逻辑不变。

## 参考

- [Claude 网关模型发现协议](https://code.claude.com/docs/en/llm-gateway-protocol#model-discovery)
- [Claude 模型配置](https://code.claude.com/docs/en/model-config#setting-your-model)
- [Codex 配置参考：model 与 model_catalog_json](https://learn.chatgpt.com/docs/config-file/config-reference)
