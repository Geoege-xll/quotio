# OpenAI 官方 Key 协议选择与迁移修复

## 账号页的官方 Key 入口

在本地代理模式打开「账号管理」，点击工具栏的「+」，选择顶部供应商网格中的「OpenAI」卡片。官方 API Key 表单预填 `OpenAI`，固定基址为 `https://api.openai.com/v1`，可在掩码输入框中填写一把上游 Key。点击「获取模型」，从当前 Key 的模型目录中选择至少一个模型，然后点击「添加提供商」。

保存前使用同一把 Key 重新读取官方目录。目录为空或有已选模型失效时，表单保留仍可用的选项并提示复核。关闭表单会取消在途请求。验证成功后走原自定义供应商保存与 CPA 同步流程，默认通过 Responses 生成。

## 问题与证据

2026-10-30 本机 CPA 8.0.47 的错误日志显示，Claude Code 的 `/v1/messages` 请求经通用 OpenAI 兼容执行器转到官方 `/v1/chat/completions`，请求仍携带 `max_tokens: 65536`。官方返回 HTTP 400，明确要求使用 `max_completion_tokens`。这是上游请求协议／字段不匹配，日志没有显示该请求因 Key 认证失败而被拒绝。

本轮核对了 CPA **v8.0.47** 的 `internal/runtime/executor/openai_compat_executor.go`、`codex_executor*.go` 及对应转换器。通用兼容通道使用 Chat Completions，现有 Codex 兼容通道可用 API Key 与自定义基址访问 Responses。官方参数契约见 [Chat Completions 文档](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)，CPA 配置见 [Codex 兼容提供商](https://help.router-for.me/cn/configuration/provider/codex-compatibility)。不在 Swift 应用中维护 CPA 的协议转换器副本。

## 业务归属与行为

- `Shared/Accounts/CustomProviders/Models/CustomProviderModels.swift`：协议意图与提供商配置成组保存。新增 `CustomProviderAPIProtocol`，旧配置缺少 `api-protocol` 时为自动模式；账号 UUID、模型／别名和密钥身份继续使用原字段。
- `Shared/Accounts/CustomProviders/Services/CustomProviderService.swift`：生成 CPA v8 的目标凭据族及跨族迁移，继续走原同步事务；不增加单例、Task 或状态宿主。
- `BusinessModules/Accounts/Views/Connections/CustomProviderSheet.swift`：原表单持有协议草稿。OpenAI 兼容提供商的高级协议选项默认收起，使用既有分段控件。

自动模式只对明确的官方 HTTPS 端点使用 Responses，CPA 凭据族为 `codex`。判断要求主机精确等于 `api.openai.com`、端口为默认或 443、路径为根或 `/v1`，且没有 URL 用户信息、查询或片段；不凭名称、模型 ID 或相似域名猜测。官方基址规范为 `https://api.openai.com/v1`。通用第三方仍使用 Chat Completions，部署前缀与自定义 URL 保持原值。用户可在高级选项明确选择 Chat Completions 或 Responses；官方旧型号需要 Chat 时可显式覆盖。

目录读取仍为轻量 `/v1/models`，管理接口仍为 `/v8/management`。协议选择只决定模型生成通道，不将管理密钥用于客户端模型访问，也不修改 Claude 角色槽或模型菜单。

## 同一 PATCH 内迁移与字段保留

迁移先按原 UUID 管理标记取得源组完整基线，再在**同一份 v8 PATCH** 内撤销旧族中本应用拥有的密钥并写入目标族。基线保留模型高级属性、头、组优先级、密钥权重及未知字段；原字段覆盖与同步基线规则继续生效。源组中的手工密钥保留在旧族，不复制到新通道。

未标记旧组只有取得 v7 专属区块归属证明，且名称和完整密钥集合唯一吻合时才允许迁移。源族归属证明不能用于接管目标族同密钥的手工组。重复标记、歧义或无效密钥结构会拒绝覆盖。停用／删除仍仅撤销有归属证明的密钥，未管理凭据保留。

## 本机当前连接

本机安装版尚未包含新自动协议选项，因此通过其现有账号编辑入口，将本次出错的官方连接改为“Codex 兼容”（该版本的 Responses 通道名称）。这仍使用原官方 API Key，不要求新增 OAuth 或订阅登录。

保存前，原配置与偏好已保存到 `~/Library/Application Support/Quotio/Backups/openai-protocol-20261030-092647/`，目录权限 700，备份文件权限 600。保存后比对确认：账号 UUID、密钥条目 UUID 和密钥、四个模型及别名原样保留；原 OpenAI 兼容族中的对应管理组已移除，Codex 族有且仅有对应的新组，其他提供商保持不变。运行中 CPA 的 `/v1/models` 返回 200，四个模型均已注册。本轮未替换应用安装包，也未向真实 OpenAI 发起付费模型生成请求。

## 定向验证与边界

2026-10-30 验证结果：

- `OpenAIProtocolRoutingTests`：6 项通过，覆盖严格端点识别、旧字段解码与编码往返、原子跨族迁移、手工组保护、协议往返幂等、停用与删除。
- 同时执行 `CPA8ProviderPatchTests`、`CustomProviderHeaderTests`，合计 **43 项通过、0 失败**；没有运行全量测试。
- `Support/CPA/openai_protocol_gateway.py` 使用生产 PATCH 驱动本机 CPA 8.0.47，假密钥、临时账号目录和 loopback 网络隔离。Messages 流式／非流式均返回 200，请求实际到达 `/v1/responses`，模型别名解析、工具与 `xhigh` 保留，未再携带旧 `max_tokens`。该夹具未跳过。
- 最终 `xcodebuild build` 成功。结果位于 `/tmp/quotio-openai-responses-r3-20261030.xcresult`，构建日志位于 `/tmp/quotio-openai-responses-build-20261030.log`，均是可清理的本机验证产物。
- 独立只读复核已关闭“跨族旧归属误接管目标手工组”问题，未发现新的高置信问题。

**已知上游边界**：本次使用的 CPA Messages→Responses 链路没有将客户端输出 Token 预算透传为 `max_output_tokens`，因此本轮不能宣称客户端 `max_tokens` 上限仍受上游保证。未通过猜测模型容量或写入固定预算掩盖此边界。真实官方模型权限、余额和后续响应仍以实际服务结果为准；本轮假网关验证证明的是路由与转换行为，不代替真实付费推理验证。

## 同日第二轮审计：应用层兼容收尾

用户本轮明确选择“仅修应用层，CPA 内核等待官方修复”。因此不修改／替换官方 CPA 二进制，不开启插件、不加入额外网络代理，也不写固定 Token 上限。以下修复仍使用原配置同步事务及原状态、任务所有者。

### 别名推理策略随协议迁移

首轮保留了模型／别名，但遗漏 `requests.payload.override` 中的协议和参数路径。例如旧 `openai` 的 `reasoning_effort` 在目标 `codex` 下不会执行。现在由现有 `CPAModelAliasService` 的纯静态规则投影，与凭据族一并写入原来的同一份 PATCH，支持双向转换；不调用其独立网络保存入口。

历史规则没有归属标记，不能证明全部规则由本应用创建。实现保留源规则，仅为最终仍注册的精确别名投影已知的纯 effort 契约，并遵守后写覆盖前写的顺序；等价目标规则不重复追加。源、目标两侧的 raw、filter、父 reasoning 对象、通配和条件策略无法安全解释时拒绝整轮迁移，保留原文件。

检查同时覆盖上游名称与客户端别名、密钥级模型覆盖、同输出协议的其它凭据族及显式 OAuth 别名，防止补全局规则时误影响其它来源。`protocol` 缺省、空字符串或纯空白均按 CPA 的“不限定协议”匹配规则检查，不能漏过冲突。候选与最终目标组取交集，同次删除或改名的旧别名不生成残留规则。配置未变化的其它 `requests`、payload 分支及未知字段继续通过局部 PATCH 保留。

### 反向权重及旧类型切换

原权重读取只在转入 Responses 时覆盖两个族。现在 OpenAI／Codex 兼容连接始终只读核对两个族，仍要求唯一 UUID／唯一旧组，避免代理停止期间反向切 Chat 后读不到原权重。旧界面直接切换为 Codex 兼容时也复用跨族完整基线，保留高级字段。

### 参数转换实际范围

本机官方 **v8.0.47** 是核对时的最新发行版。扩大后的假网关验证使用 Messages、Chat Completions、Responses 三种入口，每种均覆盖流式／非流式，共 6 次请求；工具定义、指定工具、禁止并行工具及 `xhigh` 读数均符合本轮契约。Messages 请求故意不传 effort，仅依靠实际生产 PATCH 迁入的别名规则，证明规则随协议生效。

6 次 Responses 通道请求的上游均未收到 `max_output_tokens`：不仅 Messages 的 `max_tokens`，Chat 的 `max_completion_tokens` 和原生 Responses 的 `max_output_tokens` 也被当前 Codex 转换器省略。官方 [Responses 参数文档](https://developers.openai.com/api/reference/python/resources/responses/methods/create)规定该字段是包含推理 Token 的输出上限；不能用“请求成功”代替“上限生效”。源码还显示现有转换器会清理部分采样参数，执行器会清理 `previous_response_id`；本轮没有宣称完整原生 Responses 参数透传。

第三方自动模式另用 4 次请求验证 Messages／Chat 的两种流式状态，实际到达 `/deployment/v1/chat/completions`，原部署前缀以及 65536／1234 两种请求输出预算保留。所有请求均使用假密钥、隔离临时目录和 loopback 网络，没有对真实账号发起付费推理。

最终验证入口仍为 `OpenAIProtocolRoutingTests`、`CPA8ProviderPatchTests`、`CustomProviderHeaderTests`。本轮 **52 项全部通过、0 失败**，最终独立构建成功；结果为 `/tmp/quotio-openai-audit-final-20261030.xcresult`，构建日志为 `/tmp/quotio-openai-audit-build-20261030.log`，没有运行全量测试。独立只读复核报告的问题均已关闭。本轮不改本机账号、偏好或 CPA 配置，首轮备份继续保留。
