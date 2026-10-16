# 内置模型候选与新配置默认值清理

> 后续变更：用户随后明确选择[动态目录方案](dynamic-model-defaults-2026-10-16.md)。本记录保留当时静态清理的事实与验证；当前 `allModels` 与 Codex 固定型号默认已移除，以下内置表不再是维护入口。

核对日期：2026-10-16。范围为 `AvailableModel.allModels` 与 Codex 新建／空值默认模型；沿用现有业务归属，不拆文件，不修改界面或任务生命周期。

## 官方目录核对与清理规则

`allModels` 是非 Pi 配置页在候选目录为空或读取失败时使用的内置兜底，并非当前 CPA 账号的实时支持清单。本轮将原来的 21 项精简为 10 项，保留当前用于文本和工具调用的模型；真实可用性仍以当前代理和账号为准。

| 提供商 | 保留的当前候选 | 官方来源 |
|---|---|---|
| Anthropic | `claude-fable-5-1`、`claude-opus-5-5`、`claude-sonnet-5-5`、`claude-haiku-5-5` | [当前模型目录](https://platform.claude.com/docs/en/models/overview)、[生命周期](https://platform.claude.com/docs/en/about-claude/model-deprecations) |
| Google | `gemini-4-argon`、`gemini-3.8-flash`、`gemini-3.5-flash-lite` | [当前目录](https://ai.google.dev/gemini-api/docs/models)、[Argon](https://ai.google.dev/gemini-api/docs/models/gemini-4-argon)、[Flash](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash)、[Flash-Lite](https://ai.google.dev/gemini-api/docs/models/gemini-3.5-flash-lite) |
| OpenAI | `gpt-6-astra`、`gpt-6.1-sol`、`gpt-6-luna` | [当前模型目录](https://developers.openai.com/api/docs/models)、[Sol 模型页](https://developers.openai.com/api/docs/models/gpt-6.1-sol) |

清理理由分开记录，不能把所有删除项都称为“已经退役”：

- **已经下线**：Google 公告列出的 `gemini-3-pro-preview`、`gemini-3-pro-image-preview`、`gemini-2.5-computer-use-preview-10-2025` 已过下线日期，移出内置候选。见 [Google 下线记录](https://ai.google.dev/gemini-api/docs/deprecations)。
- **旧 Codex 默认失效**：`gpt-5-codex`、`gpt-5.1-codex`、`gpt-5.1-codex-max`、`gpt-5.1-codex-mini`、`gpt-5.2-codex` 已于 2026-07-23 从 OpenAI API 下线。见 [OpenAI 下线记录](https://developers.openai.com/api/docs/deprecations)。
- **旧代候选不再内置**：其他旧 GPT/Codex 与 Gemini 条目移出这份精简兜底，不等同于全部停用。例如 Google 明确说明 2.5 Flash 系列尚未退役，但访问面向既有使用者；当前默认候选优先采用新系列。
- **代理别名不猜测**：`gemini-claude-*`、`gpt-oss-120b-medium` 等只可能在特定代理中存在的名称，不作为通用内置 ID；不推断它们在用户自建服务上失效。
- **用途适配**：不再向通用 CLI 模型候选中预填图像生成、音频及嵌入专用端点；实时代理仍可返回这些 ID，原读取与展示语义不变。

## 新默认与兼容边界

Codex 的 `AgentConfiguration.defaultCodexModel` 从已下线的 `gpt-5-codex` 更新为 `gpt-6.1-sol`。原生成器使用 `wire_api = "responses"`，符合当前 Sol 工具调用要求；不改协议、推理设置或 TOML 合并规则。

这个值只用于新建及明确空值，不扫描或迁移已有配置。用户已保存的旧 ID、自定义别名、菜单目录和当前选择，继续通过原初始化、解码和回填流程保留。即使 ID 已从内置表移除，只要用户明确保存或代理实时返回，仍原样处理。

Claude 的 `AvailableModel.defaultModels` 完整保留 `fable`、`opus`、`sonnet`、`haiku` 原生角色引用，不改成固定版本 ID。非 Pi 候选兜底继续存在；Pi 仍只接受实时目录，仪表盘实时目录保持空列表／失败／过期的区分，连接测试不改成严格目录查证。

生产修改仅两个现有共享模型文件。没有新增服务、存储、网络请求、任务、配置键或持久化迁移。先前菜单栏及 Antigravity 修复不回退。

## 必要验证

复用并增强既有测试，验证退役条目不再由空目录兜底生成、实时旧名／自定义 ID 仍保留、Pi 不补静态候选、实时空目录不伪装成有数据、新 Codex 默认与保存配置 Codable 往返，以及 Claude 原生角色和旧编码兼容。只选择直接相关方法，不跑全量测试。

最终定向验证 **9 项通过，0 失败、0 跳过、无运行时警告**：

- `ModelCatalogTests` 的 4 个方法：非 Pi 静态兜底／实时原名保留、实时空目录、响应顺序和重复、空响应解析。
- `CodexModelConfigTests` 的 3 个方法：新默认、明确旧值与自定义值的初始化／Codable 往返、用户菜单目录和 CLI 当前选择回填。
- `ClaudeCodeConfigTests` 的 2 个方法：空槽默认与实际输出一致、旧编码仍使用原生 Opus 角色。

独立 Debug 构建为 `BUILD SUCCEEDED`；没有安装或替换正在运行的应用，没有写入用户的 CLI 配置。`git diff --check` 通过。

验证记录：

- `/tmp/quotio-built-in-models-targeted-20261016.log`
- `/tmp/quotio-built-in-models-targeted-20261016.xcresult`
- `/tmp/quotio-built-in-models-targeted-summary-20261016.json`
- `/tmp/quotio-built-in-models-build-20261016.log`

官方目录核对证明这些是当前厂商模型 ID，不代表已对用户各个 CPA 账号完成在线推理验收。本轮不增加付费探测请求；账号授权范围与代理支持仍由原实时目录和连接流程判定。
