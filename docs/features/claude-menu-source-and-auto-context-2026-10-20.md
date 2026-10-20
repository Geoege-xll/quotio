# Claude 追加菜单来源与自动上下文统一

日期：2026-10-20。

后续跨文件与 CLI 保存边界已由[生命周期复审与修复](claude-menu-lifecycle-audit-2026-10-20.md)补齐；本页保留首轮实施和当时验证记录，跨保存的自动名称／上下文来源规则以复审记录为准。

## 业务目标与边界

当前服务目录确认哪些模型可请求，CPA 凭据注册信息补充这些模型的展示名称和来源。此前新目录行只生成 `model`，导致 CLI 左右两侧均回退为原始 ID；旧 Magpie 行却保留另一套名称和账号格式。

本次让固定角色、追加菜单、应用内预览和配置输出使用同一份纯计划。模型读取仍归共享模型管理，客户端展示和上下文语义仍归共享 Claude 配置模型，表单状态、请求世代和任务继续由原 `AgentSetupViewModel` 持有；磁盘合并、备份、回滚和提交继续由原 `AgentConfigurationService` actor 负责。

保留类型名称、配置键、未知字段、私有 setter 和已有事务边界。按用户最后确认，沿用现有备份策略；本次不改备份入口、保留期限或清理规则。

## 菜单名称和来源

| 条目 | 左侧 | 右侧 |
|---|---|---|
| 固定角色 | 原角色名或存量自定义名称 | 平台/最终请求模型，含有效 `[1m]` |
| 单一已确认来源的追加项 | 后端展示名称，缺失时用实际 ID | 平台 · 账号 |
| 多个凭据共同提供的追加项 | 同一名称规则 | 平台 · 账号池 |
| 只有目录归属 | 同一名称规则 | 目录明确返回的平台 |
| 无来源证据 | 同一名称规则 | 来源未标明 |

- 模型可用集合仍由客户端认证的 `/v1/models` 决定，不能根据管理侧注册信息向其中添加型号。
- 只有确认配置使用当前 CPA 时，才复用注入的 v8 管理客户端读取 `/v8/management/credentials` 及 `/credentials/models?name=...`。不会把管理密钥用于客户端目录，也不会向外部服务发送管理密钥。
- 排除禁用、不可用凭据，按原始模型 ID 精确匹配；每批至多四个结构化读取，不增加后台轮询、缓存或状态宿主。
- 完整注册集合只有一个凭据身份和一个明确账号时显示账号。即使邮箱相同，不同凭据身份仍算账号池。账号池不声称具体请求固定绑定某账号，也不改变 CPA 路由策略。
- 来源查询部分失败时仅使用原目录归属；不会把剩余一个成功响应错误标为固定账号。整个来源补充失败不抹去已经成功读取的模型目录。
- 来源和目录处于同一个请求世代，提交复核原页面、客户端、连接及认证；管理客户端替换后迟到响应不能提交。
- 已有自定义标题及菜单未知扩展保留；自动标题和来源采用当前目录证据，来源缺失不再左右重复模型 ID。

## Magpie 旧行

只移除说明明确等于 `via magpie` 或以 ` · via magpie` 结尾的旧行，不凭 `codex/` 等前缀猜测删除。

当前后端仍提供的模型可按当前目录重新生成；合法前缀继续作为模型身份保留。原文件仍由已有备份事务逐字节保存，未被删除的行及根、菜单层未知字段继续保留。移除旧行单独计数，不将其误报为型号退役。

## 自动 1M 与历史兼容

- 保留原有末尾 `[1m]`／`[1M]` 的明确声明，输出规范为单个小写后缀。
- 可选目录元数据接受 `max_input_tokens` 与 `context_length`，仅使用明确的正整数；同时提供时采用较小值。缺失或格式无效只表示容量未知，不让合法目录失败。
- 同一精确 ID 的容量证据一致且至少为 1,000,000 时，纯计划自动生成 1M。不会通过型号、平台、名称中包含的 `1m` 或相似型号猜测容量。
- 旧前缀先完成当前目录解析，再用实际 ID 确认容量，避免角色和追加菜单分叉。
- 既有逐槽 true/false 和显式后缀继续兼容，多个槽指向同一 ID 时不互相覆盖。主动重新选择普通 ID 后去除该槽旧声明，恢复目录自动规则。
- 目录推导的结果只进入纯计划，不回写草稿为固定选择；目录迟到或容量更新后仍能跟随。Default 切换先解析输入再修改配置，避免 Swift optional 修改访问内重新读取同一配置，也避免 setter 拆分后缀后把显式 1M 吞掉。
- 表单保留原三列，1M 开关替换为只读 `1M`／`自动` 标识；“自动”表示未显式指定 1M，交给 Claude Code，不表示固定 200K。高级自定义窗口、子代理和独立菜单预览保持原入口。

## 维护入口

- `Shared/ModelManagement/Services/AgentModelSourceCatalog.swift`：凭据注册读取与来源值投影。
- `Shared/ModelManagement/Models/ModelCatalog.swift`、`AvailableModel.swift`：可选目录名称、来源和容量元数据，兼容旧编码。
- `Shared/AgentClients/Models/Claude/ClaudeModelPresentation.swift`：统一标题、来源及旧 Magpie 标记识别。
- `ClaudeModelReference.swift`、`AgentConfiguration.withClaudeCatalogContext`、`ClaudeConfigurationPlan.swift`：后缀、目录容量和兼容解析后的统一计划。
- `BusinessModules/AgentConfiguration/ViewModels/AgentSetupViewModel.swift`：原会话内读取与账号变更后的同步。
- `BusinessModules/AgentConfiguration/Views/ClaudeModelMappingView.swift`：只读上下文展示。

## 定向验证

仅验证本次涉及的菜单、目录、配置兼容和交互；未运行全量测试。

- `AgentModelSourceCatalogTests`：单账号、账号池、同邮箱不同凭据、缺失与部分失败、v8 认证边界、禁用过滤、旧编码及管理客户端替换后的迟到响应。
- `ClaudeMenuSourceTests`：新增行与预览／JSON 一致、自定义标题和未知字段、原始备份、明确 Magpie 行清理、合法前缀、目录容量迟到与回落、显式 Default 后缀、实际配置输出。
- `ClaudeCatalogMigrationTests`：旧引用、目录和角色链、事务回滚、原字节备份、未知字段以及账号联动提交屏障。
- `AgentConfigurationSessionTests`：关闭重开、快速切换、连续刷新和取消的原会话边界。
- `AgentConfigurationApplyInteractionTests` 定向用例：真实 SwiftUI 宿主中只读上下文、同型号不同历史声明、无意外写盘及原保存入口。
- `ClaudeCLIRequestCompatibilityTests` 与 `ClaudeConfigurationWorkflowTests`：7 项真实 CLI 定向回归通过，本地假网关校验实际模型、后缀、子代理请求及交互式 `/model` 保存回读、账号目录同步。网络仅限测试本地网关，配置和备份均在临时目录。

结果：Debug 构建通过；本轮共 102 个不同的相关定向用例最终通过，未运行全量测试。其中菜单／来源／迁移／会话／只读交互共 40 项（R4 中 39 项通过，1 项输出夹具补齐明确的菜单写入意图后在 R6 通过）；已有模型目录及引用 16 项、Claude 配置 39 项、真实 CLI 7 项均通过。中途回归暴露的 Default 互斥访问和显式后缀问题已修复并覆盖；独立只读复审未留下生产阻断项。

构建日志：`/tmp/quotio-claude-menu-source-build-20261020.log`。定向结果分别位于 `/tmp/quotio-claude-menu-source-{r1,r2,r3,cli,r4,r5,r6}-20261020.xcresult`；其中中间失败结果保留用于追溯，以最后一次对应方法通过为准，不把重跑次数计为不同用例。

构建过程中已知的公共胶囊控件 actor 警告属于其他既有改动，本次不扩展修改该控件。原生测试宿主的系统 Intents 服务日志也不作为菜单功能成功或失败的判据。本次完成源码及构建验证，未替换本机安装应用。
