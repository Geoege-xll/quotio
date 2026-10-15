# 公共模型与纯规则拆分：第二轮第一批

日期：2026-10-15。本轮承接[首轮目录规整](source-directory-organization-2026-10-15.md)，在既有业务目录结构内拆分公共模型合集和纯规则。当前入口与后续归属见[源码目录与归属规范](../SOURCE_LAYOUT.md)。

## 实施范围

本批按完整顶层声明、原有 MARK 区块和已有模型文件归位，不重新实现业务逻辑。新增必要文件头、导入及中文职责说明；保留原有类型名、字段、默认值、编码键、访问级别和声明体。

| 来源 | 当前职责与位置 |
|---|---|
| `Shared/Models/Models.swift` | 账号与额度模型归 `Shared/Accounts/Models`；CPA 运行状态归 `Infrastructure/CPA/Models`；OAuth 响应归 `Infrastructure/CPA/API/Models`；日志条目归 `Settings/Diagnostics/Models`；导航枚举归 `App/Navigation`；颜色、格式化及 URL 校验归各自公共或基础设施目录 |
| `AntigravityQuotaFetcher.swift` 的 `ModelQuota`、`ProviderQuotaData` | 这两个类型为多个提供商共用，原样移入 `Shared/Accounts/Models/QuotaModels.swift`，取数器仍保留原有网络与刷新流程 |
| `QuotaScreen.swift` 的 `QuotaPercentagePresentation` | 仅抽出无状态的公共百分比规则，归 `Shared/Accounts/Presentation/QuotaPercentagePresentation.swift`；原有视图、兼容入口与交互保留 |
| `Shared/AppSettings/MenuBarSettings.swift` | 拆为外观、刷新、额度偏好、菜单栏 manager、额度汇总扩展、菜单栏额度模型和隐私字符串扩展七个文件 |
| `Shared/AgentClients/Models/AgentModels.swift` | 拆为客户端标识、配置选项、Codex 推理强度、可用模型、客户端配置、结果类型及 Shell 类型七个文件 |
| 业务目录中的两个 Claude 模型文件 | `ClaudeModelPicker.swift`、`ClaudeModelPresentation.swift` 原样迁入 `Shared/AgentClients/Models/Claude`，供公共客户端配置逻辑使用 |

原三个合集文件及两个原位置的 Claude 模型文件移除，共形成 27 个目标 Swift 文件。`Shared/Models` 清空后不再作为当前源码入口；没有保留重复声明或增加转发类型。具体拆分如下。

### 原通用模型合集及公共额度规则

- `Shared/Accounts/Models/AIProvider.swift`
- `Shared/Accounts/Models/AuthFile.swift`
- `Shared/Accounts/Models/QuotaModels.swift`
- `Infrastructure/CPA/Models/ProxyStatus.swift`
- `Infrastructure/CPA/API/Models/CPAOAuthResponses.swift`
- `BusinessModules/Settings/Diagnostics/Models/LogEntry.swift`
- `App/Navigation/NavigationPage.swift`
- `Shared/UI/Theme/Color+Hex.swift`
- `Shared/Formatting/Int+CompactFormatting.swift`
- `Infrastructure/Networking/ProxyURLValidator.swift`
- `Shared/Accounts/Presentation/QuotaPercentagePresentation.swift`

### 原菜单栏设置合集

- `Shared/AppSettings/AppearanceSettings.swift`
- `Shared/AppSettings/RefreshSettings.swift`
- `Shared/AppSettings/QuotaDisplayPreferences.swift`
- `Shared/AppSettings/MenuBarSettingsManager.swift`
- `Shared/AppSettings/MenuBarSettingsManager+QuotaSummary.swift`
- `Shared/Accounts/Models/MenuBarQuotaModels.swift`
- `Shared/Formatting/String+PrivacyMasking.swift`

菜单栏 manager 的额度汇总方法归扩展文件，仍作用于原来的 manager 实例。拆分不新增设置副本，不变更 `UserDefaults` 键及读写时机。

### 原客户端模型合集与 Claude 模型

- `Shared/AgentClients/Models/CLIAgent.swift`
- `Shared/AgentClients/Models/AgentConfigurationOptions.swift`
- `Shared/AgentClients/Models/CodexReasoningEffort.swift`
- `Shared/AgentClients/Models/AgentConfiguration.swift`
- `Shared/AgentClients/Models/AgentConfigurationResult.swift`
- `Shared/ModelManagement/Models/AvailableModel.swift`
- `Infrastructure/Process/ShellType.swift`
- `Shared/AgentClients/Models/Claude/ClaudeModelPicker.swift`
- `Shared/AgentClients/Models/Claude/ClaudeModelPresentation.swift`

配置选项、角色槽位及结果类型继续沿用原有声明。Claude 存量自定义菜单、显示名称、Fable 和子代理字段的读取与生成规则保持原样。

## 兼容与状态边界

- 保留所有现有类型名称、Codable 字段、默认值和既有配置；目录及文件名改变不构成配置迁移。
- `QuotaViewModel`、应用级状态、Task、单例及 manager 的创建与所有权保持原样，不新增第二份账号状态、刷新协调器或队列消费者。
- 只迁移模型与既有纯规则；不在本轮修改网络鉴权策略、刷新流程、启动流程或持久化时序。
- 仍使用单一应用 Target。原调用方按类型名编译，不因拆文件增加适配层或修改用户运行时路径。
- 首轮实施记录保留原日期和当时范围；本页与 `SOURCE_LAYOUT` 描述本批完成后的入口。外部来源 URL 和历史上游链接保留。

## 验证记录

- 原样声明校验：拆分清单分别记录原文件哈希、区块或声明映射；菜单栏设置的 14 个 MARK 区块各迁移一次，客户端模型的 14 个声明体及两个 Claude 文件内容保持一致。相关证据：`/tmp/quotio-menubar-settings-split-20261015.json`、`/tmp/quotio-p2-agent-models-split-validation-20261015.json`、`/tmp/quotio-model-split-p1-map-20261015.json`。
- 完整性复核：受影响来源文件的 88 个完整顶层声明（含留在原文件的声明）均原样保留且唯一，原代码行集合一致；其余 281 个生产 Swift 文件及全部 104 个测试文件与本批快照逐字节一致。独立复核对 27 份目标文件中的 38 个完整迁移区块逐字核对，未发现遗漏、重复、访问范围扩大或兼容性缺陷。证据：`/tmp/quotio-model-split-integrity-20261015.json`。
- 文档静态检查：检查当前维护入口、本地 Markdown 目标与外部 URL 保留情况；结果为 `/tmp/quotio-public-model-docs-static-20261015.json`，最终复核另见 `/tmp/quotio-model-split-final-docs-20261015.json`。
- 应用构建：Debug 构建通过，编译无 warning／error。日志：`/tmp/quotio-model-split-build-20261015.log`。
- 定向验证：15 个完整相关测试类及 4 个指定方法，共 **221 项通过，0 失败**；测试构建无 warning／error，未运行全量测试。结果：`/tmp/quotio-model-split-targeted-20261015.xcresult`；日志：`/tmp/quotio-model-split-targeted-20261015.log`。
- 测试执行范围及逐类数量：`/tmp/quotio-model-split-tests-20261015.json`；本批起始快照：`/tmp/quotio-model-split-before-20261015`。

### 本批定向执行清单

| 测试类 | 通过项数 | 范围 |
|---|---:|---|
| `AntigravityQuotaTests` | 13 | 完整相关类 |
| `AppearanceModeTests` | 3 | 完整相关类 |
| `AuthFileIdentityTests` | 16 | 完整相关类 |
| `CPA8ManagementAPIContractTests` | 2 | 仅授权响应及 active／ready 两个方法 |
| `CPAQuotaParityTests` | 15 | 完整相关类 |
| `ClaudeCodeConfigTests` | 37 | 完整相关类 |
| `ClaudeModelPickerConfigTests` | 19 | 完整相关类 |
| `ClaudeModelPresentationTests` | 14 | 完整相关类 |
| `CodexAuthConfigTests` | 15 | 完整相关类 |
| `CodexModelConfigTests` | 11 | 完整相关类 |
| `CodexReasoningEffortTests` | 26 | 完整相关类 |
| `LogsV8LifecycleTests` | 4 | 完整相关类 |
| `MenuBarAccountSyncTests` | 22 | 完整相关类 |
| `MenuBarQuotaPairTests` | 12 | 完整相关类 |
| `QuotaDisplayModeTests` | 6 | 完整相关类 |
| `QuotaPercentagePresentationTests` | 4 | 完整相关类 |
| `TerminalLauncherTests` | 1 | 仅客户端生命周期命令方法 |
| `UsageStatisticsTests` | 1 | 仅紧凑数字格式化方法 |
