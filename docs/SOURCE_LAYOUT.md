# 源码目录与归属规范

本页记录 2026-10-15 目录规整、第二轮前九批及后续专项修复、第三轮六批后的当前维护入口。应用继续使用单一 Xcode 应用 Target、SwiftUI 和 Observation。首轮完成目录和固定路径调整；第二轮归位公共模型、独立视图及 `QuotaViewModel` 各组方法，后续专项处理收尾审计问题；第三轮第一、二批归位 Monitor 与工作区 Provider，第三批纠正 CPA 公共能力归属，第四批纠正共享账号、授权及模式／导航边界，第五批解耦模型目录读取与配置写入并归位 Pi 路径契约，第六批纠正存储维护的应用装配归属。类型名称、配置键、数据库格式和历史兼容入口保留；结构拆分不转移状态或 Task 所有权，功能修复的实际范围以各专项记录为准。

## 总体结构

```text
Quotio/
├── App/                         # 应用装配、导航、菜单栏和首次使用
│   ├── Configuration/           # Info、entitlements、桥接头及常量
│   ├── Composition/             # 跨业务应用装配，含存储维护协调与目的地
│   ├── Navigation/
│   ├── MenuBar/
│   ├── Onboarding/
│   └── State/
├── BusinessModules/             # 以侧边栏业务为主要归属
│   ├── Dashboard/               # 仪表盘；Routing 为内部业务子目录
│   ├── Analytics/               # 统一统计入口
│   │   ├── CPAUsage/            # CPA 用量页面、筛选和报表展示
│   │   └── ClientCalls/         # 本地客户端 Token 与工具调用分析
│   ├── Accounts/                # 账号管理、额度展示与连接表单
│   ├── AgentConfiguration/      # Claude Code 等客户端配置页面
│   ├── Workspace/              # 会话、技能和存储管理
│   ├── APIKeys/
│   ├── Settings/                # 包含 Diagnostics 与 Storage
│   └── About/
├── Shared/                      # 多个业务共同使用的组件和业务能力
│   ├── Accounts/                # Models、Presentation 及账号公共能力
│   ├── AgentClients/            # 公共客户端配置模型，含 Models/Claude
│   ├── Analytics/               # 公共统计模型及唯一 CPA 账本
│   ├── AppSettings/             # 共享运行模式、外观、刷新、额度与菜单栏偏好
│   ├── Formatting/              # 隐私脱敏及数值格式化纯规则
│   ├── ModelManagement/
│   └── UI/                      # 主题、分段控件、图表等基础组件
├── Infrastructure/              # 外部协议及系统接入
│   ├── CPA/                     # API、配置文件与本地进程运行
│   ├── Providers/               # 各提供商认证、额度和 IDE 接入
│   ├── AgentClients/            # 客户端检测与配置文件读写
│   ├── Networking/
│   ├── Persistence/             # 共享数据库连接、缓存基础能力
│   ├── Process/                 # CLI、Shell 和终端启动
│   ├── Security/
│   ├── System/
│   ├── Telemetry/
│   ├── Tunnel/
│   └── Updates/
└── Resources/                   # Assets、本地化和第三方许可
```

业务目录按需要建立 `Views`、`ViewModels`、`Models`、`Services`，不为层级对称创建空文件夹。工作区内的 `Sessions`、`Skills`、`Storage`，以及路由中心的 `Routing`，代表同一业务的内部范围；目录层级不增加界面导航或内部 Tab。

## 主要维护入口

以下路径均相对于仓库根目录；目录归属以实际职责为准，不仅按历史文件名判断。

| 范围 | 主要入口 |
|---|---|
| 应用生命周期、实例装配与主窗口 | [App/QuotioApp.swift](../Quotio/App/QuotioApp.swift) |
| 存储维护应用装配 | [AnalyticsMaintenanceComposition.swift](../Quotio/App/Composition/AnalyticsMaintenanceComposition.swift)：原协调器与目的地同组；App 向设置导航注入延迟目的地，原服务及 Store 留设置业务 |
| 菜单栏装配与控件 | [StatusBarMenuBuilder.swift](../Quotio/App/MenuBar/StatusBarMenuBuilder.swift)、[MenuBar/Views](../Quotio/App/MenuBar/Views)；筛选控制器、HostingView 和回调入口在 `App/MenuBar` |
| 仪表盘 | [Dashboard/Views/DashboardScreen.swift](../Quotio/BusinessModules/Dashboard/Views/DashboardScreen.swift) |
| 路由中心、光流与执行记录 | [Dashboard/Routing](../Quotio/BusinessModules/Dashboard/Routing) |
| 账号管理与额度融合页 | [ProvidersScreen.swift](../Quotio/BusinessModules/Accounts/Views/ProvidersScreen.swift)、[AccountQuotaContent.swift](../Quotio/BusinessModules/Accounts/Views/AccountQuotaContent.swift)；原 `QuotaScreen` 仅保留旧导航兼容壳 |
| 公共账号状态、身份及刷新协调 | [QuotaViewModel.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel.swift) 持有原状态、任务、上下文、槽位、私有节流及预热调度／缓存；[ViewModels](../Quotio/Shared/Accounts/ViewModels) 下的同类型扩展承载只读展示、菜单投影、凭据传输、OAuth、IDE、账号变更与切换、取数、刷新、代理启动及预热执行 |
| 监控账号、凭据、快照及刷新协调 | [Accounts/Monitor](../Quotio/Shared/Accounts/Monitor)：原合集已按 16 个现有类型归位；入口为 [MonitorAccount](../Quotio/Shared/Accounts/Monitor/MonitorAccount.swift)、[MonitorCredentialVault](../Quotio/Shared/Accounts/Monitor/MonitorCredentialVault.swift)、[MonitorSnapshotStore](../Quotio/Shared/Accounts/Monitor/MonitorSnapshotStore.swift)、[MonitorRefreshCoordinator](../Quotio/Shared/Accounts/Monitor/MonitorRefreshCoordinator.swift) |
| 提供商、认证文件、额度及授权状态模型 | [Accounts/Models](../Quotio/Shared/Accounts/Models)，授权状态入口为 [OAuthState.swift](../Quotio/Shared/Accounts/Models/OAuthState.swift) |
| 额度百分比纯投影 | [QuotaPercentagePresentation.swift](../Quotio/Shared/Accounts/Presentation/QuotaPercentagePresentation.swift) |
| 账号身份与菜单候选解析 | [MenuBarAccountCatalog.swift](../Quotio/Shared/Accounts/Presentation/MenuBarAccountCatalog.swift)：原目录／别名／固定项和精确额度解析，状态提交仍归原宿主 |
| IDE 显式扫描契约与原状态宿主 | [IDEScanSettings.swift](../Quotio/Shared/Accounts/Services/IDEScanSettings.swift)：选项、结果、隐私提示与原 manager 同文件，扫描 Sheet 留 Accounts |
| CPA 授权协调与共享弹窗 | [CPAOAuthSessionCoordinator.swift](../Quotio/Shared/Accounts/Services/CPAOAuthSessionCoordinator.swift)、[OAuthSheet.swift](../Quotio/Shared/Accounts/Views/OAuthSheet.swift)：原协调器与两个紧密视图类型完整保留 |
| 共享运行模式与 App 导航 | [OperatingMode.swift](../Quotio/Shared/AppSettings/OperatingMode.swift) 保留模式、单例、偏好和私有 setter；[OperatingMode+Navigation.swift](../Quotio/App/Navigation/OperatingMode+Navigation.swift) 维护原两个只读导航成员 |
| 客户端枚举与配置模型 | [AgentClients/Models](../Quotio/Shared/AgentClients/Models) |
| Claude 菜单与模型显示规则 | [AgentClients/Models/Claude](../Quotio/Shared/AgentClients/Models/Claude) |
| 共享模型目录读取、候选筛选与连接探测 | [AgentModelCatalogService.swift](../Quotio/Shared/ModelManagement/Services/AgentModelCatalogService.swift) 保留三种结果语义；[DashboardModelCatalogLoader.swift](../Quotio/Shared/ModelManagement/Services/DashboardModelCatalogLoader.swift) 保留原凭据先行事务，状态仍归 QuotaViewModel |
| 外观、刷新、额度偏好与菜单栏设置 | [Shared/AppSettings](../Quotio/Shared/AppSettings) |
| 隐私脱敏与数值格式化 | [Shared/Formatting](../Quotio/Shared/Formatting) |
| 统计入口及导航状态 | [Analytics](../Quotio/BusinessModules/Analytics) |
| CPA 用量页面 | [Analytics/CPAUsage](../Quotio/BusinessModules/Analytics/CPAUsage) |
| 客户端用量和调用分析 | [Analytics/ClientCalls](../Quotio/BusinessModules/Analytics/ClientCalls) |
| 唯一 CPA 队列消费者、账本与事件模型 | [Shared/Analytics/CPA](../Quotio/Shared/Analytics/CPA) |
| Claude Code 等客户端配置界面 | [AgentConfiguration](../Quotio/BusinessModules/AgentConfiguration) |
| 工作区入口、会话、技能与存储 | [Workspace](../Quotio/BusinessModules/Workspace) |
| 工作区会话门面与客户端 Provider | [WorkspaceSessionService.swift](../Quotio/BusinessModules/Workspace/Sessions/Services/WorkspaceSessionService.swift) 保留原 actor 装配和分发；[Sessions/Services](../Quotio/BusinessModules/Workspace/Sessions/Services) 下协议、`SessionIOUtils` 及五个 Provider 按同名文件维护 |
| 设置导航、分区与诊断维护 | [SettingsScreen.swift](../Quotio/BusinessModules/Settings/Views/SettingsScreen.swift)、[Views/Sections](../Quotio/BusinessModules/Settings/Views/Sections)、[Views/Components](../Quotio/BusinessModules/Settings/Views/Components)；版本维护弹窗在 [ProxyVersionManagerSheet.swift](../Quotio/BusinessModules/Settings/Views/Sheets/ProxyVersionManagerSheet.swift) |
| 客户端访问密钥与分享 | [APIKeys](../Quotio/BusinessModules/APIKeys) |
| 关于及上游更新信息 | [About](../Quotio/BusinessModules/About) |
| CPA v8 管理 API | [Infrastructure/CPA/API](../Quotio/Infrastructure/CPA/API) |
| CPA 账号权重及兼容错误 | [CPAAccountRoutingRules.swift](../Quotio/Infrastructure/CPA/Configuration/CPAAccountRoutingRules.swift)：管理 API、共享提供商和账号编辑复用的接入规则，不持有页面草稿 |
| CPA 策略展示与数值输入 | [CPARoutingPolicy.swift](../Quotio/Shared/UI/CPA/CPARoutingPolicy.swift)、[CPASettingsNumberRow.swift](../Quotio/Shared/UI/Controls/CPASettingsNumberRow.swift)：实际跨 Settings／Dashboard 或 Accounts 复用，不主动保存配置 |
| CPA 路由查询结果 | [CPAUsageRoutingReport.swift](../Quotio/Shared/Analytics/CPA/Models/CPAUsageRoutingReport.swift)：共享账本与消费服务返回的原快照，动画活动仍在 Dashboard/Routing |
| OAuth 响应与代理运行状态 | [CPAOAuthResponses.swift](../Quotio/Infrastructure/CPA/API/Models/CPAOAuthResponses.swift)、[ProxyStatus.swift](../Quotio/Infrastructure/CPA/Models/ProxyStatus.swift) |
| CPA OAuth 传输契约与客户端适配 | [CPAOAuthSessionClient.swift](../Quotio/Infrastructure/CPA/API/CPAOAuthSessionClient.swift)：原四个异步 API 与 ManagementAPIClient 符合声明，不持有 UI 状态或轮询 Task |
| 代理 URL 校验 | [ProxyURLValidator.swift](../Quotio/Infrastructure/Networking/ProxyURLValidator.swift) |
| 模型目录请求传输 | [ModelCatalogClient.swift](../Quotio/Infrastructure/Networking/ModelCatalogClient.swift)：原端点、Bearer、十秒超时及代理工厂；不解析、筛选、缓存或重试 |
| 客户端配置文件与检测 | [Infrastructure/AgentClients](../Quotio/Infrastructure/AgentClients) |
| Pi 本地路径契约 | [PiSessionPaths.swift](../Quotio/Infrastructure/AgentClients/PiSessionPaths.swift)：原路径展开、环境覆盖与目录去重；timestamp 同名扩展留在 [PiClientUsageSource.swift](../Quotio/BusinessModules/Analytics/ClientCalls/Services/ClientUsage/PiClientUsageSource.swift) |
| 统一主题与分段控件 | [Shared/UI](../Quotio/Shared/UI) |
| 本地化字符串 | [Resources/Localizable.xcstrings](../Quotio/Resources/Localizable.xcstrings) |

`AgentManagementScreen` 是工作区入口，归 `Workspace`；`AgentSetupScreen` 才是客户端配置入口，归 `AgentConfiguration`。保留这些已有名称，避免目录整理连带改变导航和外部调用。

## 公共能力与基础设施边界

- 后续调整先按业务能力、共同变更原因、依赖关系及状态／任务所有权划定维护边界，再决定文件组织。代码行数只提供审计线索，不决定拆分或实施顺序；完整类型迁移也不意味着必须一类型一文件。强关联的小类型可放在一起，职责内聚的长文件可保留。详细规划要求见[架构标准中的业务职责组织规则](ARCHITECTURE_STANDARDS.md)。
- 页面专用的账号行、连接表单、路由卡片及配置模型槽留在对应业务。名称包含 `View`、`Card` 或 `Sheet`，不构成放入公共目录的理由。
- `Shared/UI` 保存主题、控件及跨页面图表；分段选择继续复用 `QuotioCapsuleSegmentedControl`。具有账号语义的 `ProviderIcon`、`QuotaProgressBar` 放在 `Shared/Accounts/Views`。
- 账号身份归一、刷新协调、公共模型目录、别名规则和统计口径属于 `Shared`。跨业务复用以已有调用为依据，不提前建立没有使用方的工具层。
- HTTP、CPA 进程、提供商协议、CLI 配置文件、Keychain、Shell 和系统通知属于 `Infrastructure`。本地运行时数据位置保持原样，源码目录迁移不迁移用户账号或缓存。
- `AnalyticsDatabase` 是 SQLite 基础能力，放在 `Infrastructure/Persistence`。客户端统计表与扫描索引留在 `Analytics/ClientCalls/Services`；工作区技能表留在 `Workspace/Skills/Services`；共享 CPA 事件表、账本及唯一消费者放在 `Shared/Analytics/CPA/Services`。使用 SQLite 不代表业务存储必须全部进入基础设施。
- CPA 网关统计、本地客户端 Token 和工具调用继续保持各自口径。目录聚合不合并数据，也不创建第二个队列消费者或后台扫描器。

这些文件夹目前仍属于同一应用 Target，不是新的 Swift Package 或独立模块。共享目录表示维护归属，不能据此推断已完成编译依赖隔离。

## 模型目录读取与客户端本地环境边界

2026-10-16 按用户最新授权改为[动态目录默认方案](features/dynamic-model-defaults-2026-10-16.md)：所有页面候选取消静态补型号，Codex 新配置待明确选择，只有 Claude 保留原生角色。请求世代、加载说明与表单继续归原 AgentSetupViewModel；服务层保留目录缺失时的旧配置模型，不将其包装为实时目录。以下第五批迁移描述中的“原页面兜底”是当时历史边界，已被本次功能调整取代。

第三轮第五批按仪表盘、客户端配置和 Pi 的实际使用抽出共享模型读取业务；共用传输只负责构造和发送请求。实时目录保留空结果、原顺序和重复项，候选继续用原模型投影与 Copilot 可用性证据筛选，连接探测仍以 HTTP 200 判断成功。原页面兜底、加载互斥和回填 Task 不下沉；旧 `AgentConfigurationService` 的三个读取签名保留兼容，配置读写、备份及私有状态仍由原 actor 持有。完整 Loader 与原测试整体归 `Shared/ModelManagement`，不把其两个闭包再拆成服务。

Pi 的路径展开、agent 目录和会话根整体归客户端本地环境契约；时间解释仍为 Analytics 同名扩展，显式 `nonisolated` 保留同步后台扫描边界。安装、配置、技能和统计继续使用原路径，不扩大工作区或统计扫描范围，不改变 Pi 双文件写入与回滚。新增读取能力无存储、缓存或 Task；同一 Target 内仍存在既有领域类型依赖，本批不代表独立编译模块化。详见[模型目录与 Pi 路径归位记录](features/model-catalog-business-boundary-2026-10-15.md)。

## 已完成的公共模型归位

第二轮第一批按完整声明或原有 MARK 区块拆分三个合集；只新增必要导入、文件头和中文职责说明，未重写声明体。原合集文件移除，空的 `Shared/Models` 不再作为当前入口。

| 原合集或位置 | 当前入口 |
|---|---|
| `Models.swift` 中的账号类型 | `Shared/Accounts/Models/AIProvider.swift`、`AuthFile.swift`、`QuotaModels.swift` |
| `Models.swift` 中的 CPA、诊断与导航类型 | `Infrastructure/CPA/Models/ProxyStatus.swift`、`Infrastructure/CPA/API/Models/CPAOAuthResponses.swift`、`BusinessModules/Settings/Diagnostics/Models/LogEntry.swift`、`App/Navigation/NavigationPage.swift` |
| `Models.swift` 中的纯扩展与校验 | `Shared/UI/Theme/Color+Hex.swift`、`Shared/Formatting/Int+CompactFormatting.swift`、`Infrastructure/Networking/ProxyURLValidator.swift` |
| `MenuBarSettings.swift` | `Shared/AppSettings/AppearanceSettings.swift`、`RefreshSettings.swift`、`QuotaDisplayPreferences.swift`、`MenuBarSettingsManager.swift`、`MenuBarSettingsManager+QuotaSummary.swift`；账号展示模型在 `Shared/Accounts/Models/MenuBarQuotaModels.swift`，脱敏扩展在 `Shared/Formatting/String+PrivacyMasking.swift` |
| `AgentModels.swift` | `Shared/AgentClients/Models/CLIAgent.swift`、`AgentConfigurationOptions.swift`、`CodexReasoningEffort.swift`、`AgentConfiguration.swift`、`AgentConfigurationResult.swift`；可用模型在 `Shared/ModelManagement/Models/AvailableModel.swift`，Shell 类型在 `Infrastructure/Process/ShellType.swift` |
| 两个 Claude 模型文件 | `Shared/AgentClients/Models/Claude/ClaudeModelPicker.swift`、`ClaudeModelPresentation.swift` |
| 取数器与额度页中的公共纯模型 | `ModelQuota`、`ProviderQuotaData` 归 `Shared/Accounts/Models/QuotaModels.swift`；`QuotaPercentagePresentation` 归 `Shared/Accounts/Presentation` |

菜单栏设置 manager 的原有类型、单例和持久化键保留；拆出的额度汇总扩展继续作用于原 manager。共享类型的迁移不增加任务、状态容器、数据转换或序列化层。完整实施范围与验证见[公共模型及纯规则拆分](features/public-model-split-2026-10-15.md)。

## 已完成的独立视图归位

第二轮第二批保留三个原入口，拆出 34 个文件；按完整类型搬迁，不把原有视图的存储属性、`body` 或异步函数拆到另一状态容器。

| 原入口 | 当前维护位置与边界 |
|---|---|
| `SettingsScreen.swift` | 根文件只保留设置导航与搜索定位状态；12 个设置分区文件在 `Settings/Views/Sections`，密钥行和登录启动控件在 `Views/Components`。`Views/Sheets/ProxyVersionManagerSheet.swift` 连同私有版本行共同维护，关于页继续调用原类型 |
| `QuotaScreen.swift` | 原文件保留旧导航兼容壳；额度内容宿主在 `Accounts/Views/AccountQuotaContent.swift`，徽标、Antigravity／通用布局、模型详情与显示辅助分别独立。页面展示快照在 `Accounts/Models/AccountQuotaPresentation.swift`；原视图保留弹窗绑定，预热与刷新继续读取同一 `QuotaViewModel` |
| `StatusBarMenuBuilder.swift` | 原文件保留原生菜单装配、客户端检测缓存与筛选控制器引用；筛选控制器、`MenuItemHostingView`、`MenuActionHandler` 分文件维护。账号卡片、额度布局、统计详情与趋势、网络信息、筛选控件和 Tooltip 在 `App/MenuBar/Views`，原类型名与调用方式不变 |

设置的私有版本辅助继续与弹窗同文件；额度和菜单栏仅为跨文件引用，将必要类型或扩展方法放宽到应用 Target 内部，桥接对象及其私有辅助不扩散。拆分没有创建新的应用状态、刷新任务、计时器或单例；完整映射与实际验证见[独立视图拆分记录](features/independent-view-split-2026-10-15.md)。

## 已完成的 QuotaViewModel 分文件维护

存储统计口径在第八批复核时核正：前批的“84”误计入了含 `!=` 的 Debug 计算属性 `isQuotaAutoRefreshScheduledForTesting`；主类实际为 83 个原存储声明（含静态常量及 Debug 存储），前后没有删除状态。当前索引使用核正口径，历史实施报告保留原样。

第二轮第三批只实施模型、菜单投影、凭据传输和 OAuth 四组，主类从 3,461 行缩减到 2,996 行。新文件仍是原 `QuotaViewModel` 的扩展或既有状态模型，没有新建协作者、状态容器或 Target；分文件维护不代表已经完成职责所有权或编译依赖隔离。

以下路径均位于 `Quotio/Shared/Accounts`：

| 文件 | 当前职责与保留边界 |
|---|---|
| [ViewModels/QuotaViewModel.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel.swift) | 唯一原状态宿主，保留 83 个存储属性及其顺序、初始化、4 个 Task 句柄、刷新世代、上下文、槽位、私有节流及同步写入入口，以及代理停止／自动刷新／恢复、预热调度／防重／缓存、模型目录与 API key；IDE、账号变更、取数、刷新、代理启动及预热执行在下述第四至八批扩展中维护 |
| [ViewModels/QuotaViewModel+Models.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel+Models.swift) | `OAuthLaunchMode`、`WarmupStatus`、`WarmupModelState` 仍嵌套在原类名下，完整类型名称不变 |
| [Models/OAuthState.swift](../Quotio/Shared/Accounts/Models/OAuthState.swift) | 原授权 UI 状态、设备流与回调字段，继续由原主类及协调器使用 |
| [ViewModels/QuotaViewModel+MenuBar.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel+MenuBar.swift) | 原账号身份归一、候选项、固定项裁剪与额度投影；复用主类 `menuBarSettings` getter 和同一账号状态，不创建菜单快照副本 |
| [ViewModels/QuotaViewModel+AuthFileTransfer.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel+AuthFileTransfer.swift) | 原凭据上传、导入、下载、导出及 Vertex 导入；传输来源上下文和全部私有辅助同文件维护，保留批次会话隔离 |
| [ViewModels/QuotaViewModel+OAuth.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel+OAuth.swift) | CPA、Monitor、Copilot、Kiro 的原授权入口、回调与取消；复用原协调器、获取器和任务，不转移会话所有权 |

原 250 个类成员各保留一份，32 个成员移入扩展，另将原顶层 `OAuthState` 归位。只有 10 项跨文件必需的 `private` 声明调整为应用 Target 内部可见；`private(set)`、传输私有辅助和任务持有边界保持原样。白名单与实际验证见[QuotaViewModel 分文件维护记录](features/quota-viewmodel-split-2026-10-15.md)。

## IDE 额度与账号变更分文件维护

第二轮第四批继续按原方法完整归位，主类从第三批结束时的 2,996 行缩减到 2,452 行；新增两个文件，分别包含 9 个和 13 个原方法。以下路径位于 `Quotio/Shared/Accounts/ViewModels`：

| 文件 | 当前职责与保留边界 |
|---|---|
| [QuotaViewModel+IDEQuotas.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel+IDEQuotas.swift) | Cursor／Trae 读取、已有账号刷新、用户同意扫描及 IDE 额度保存恢复；原 `nonisolated static` 合并方法只更新已导入账号，持久化键不变 |
| [QuotaViewModel+AccountMutations.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel+AccountMutations.swift) | 监控账号禁用删除、IDE 派生账号删除、密钥账号保存、CPA 账号删除提交与请求、自定义连接变更和禁用开关；原会话检查、身份范围与清理顺序保持不变 |

这两个扩展继续复用原状态、获取器、协调器和刷新入口，不新增 Service、Task 或状态存储。刷新上下文校验、槽位占用与统一收尾仍在主类；已有账号刷新不引入未扫描账号，删除继续清理内存、IDE 持久化镜像、监控快照和固定项，保留挂起后校验与删除后不复活边界。本批只将 20 项跨文件必需的只读依赖或方法调整为内部可见；全部可变私有存储、七个 `private(set)`、四个 Task 句柄和 Debug 钩子保持原样。白名单与实际验证见[IDE 额度与账号变更拆分记录](features/quota-viewmodel-ide-account-split-2026-10-15.md)。

## 提供商取数分文件维护

第二轮第五批继续完整迁移原方法，主类从 2,452 行缩减到 1,784 行，新增三个同类型扩展。以下路径位于 `Quotio/Shared/Accounts/ViewModels`：

| 文件 | 当前职责与保留边界 |
|---|---|
| [QuotaViewModel+LocalQuotaFetching.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel+LocalQuotaFetching.swift) | 12 个原本地／CLI／直连取数及辅助方法；保留 CPA 优先、原空结果与合并规则、Kiro 凭据映射、Antigravity 套餐及检测顺序，两个局部辅助保持私有 |
| [QuotaViewModel+CPAQuotaRefresh.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel+CPAQuotaRefresh.swift) | 原 CPA 接管方法；精确凭据与唯一旧邮箱映射、原 TaskGroup 并发、逐结果会话复核及失败保留不变，不消费用量队列 |
| [QuotaViewModel+MonitorQuotaRefresh.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel+MonitorQuotaRefresh.swift) | 3 个原监控批量／单提供商及 Copilot 合并方法；保留凭据存在性、Codex 分组、Copilot 合并后归一、原 async let 并发和不挂起的内存发布段 |

主类仍唯一持有全部获取器、状态、任务和 Debug 钩子；刷新上下文校验、槽位、错误恢复判定及统一收尾继续由主类原入口提供。仅将 13 个原只读获取器和 13 个必要方法开放为应用 Target 内部可见，不开放私有可变存储和七个私有 setter。16 个方法的完整正文与属性保持原样，先前六个扩展及原测试源码不变。白名单和实际验证见[提供商取数拆分记录](features/quota-viewmodel-provider-fetching-split-2026-10-15.md)。

## 刷新协调与目录读取分文件维护

第二轮第六批将原目录读取、手动刷新、各粒度刷新、账号发现及统一收尾归位到同类型扩展，主类从 1,784 行缩减到 1,376 行。以下路径相对于仓库根目录：

| 文件 | 当前职责与保留边界 |
|---|---|
| [QuotaViewModel+QuotaRefresh.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel+QuotaRefresh.swift) | 14 个原方法（13 个生产方法及一个 Debug 目录包装），保留原槽位申请／释放、来源与提交校验、并发、账号映射、失败回退和收尾顺序；目录事务与失败持久化辅助保持私有 |
| [QuotaViewModel.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel.swift) | 状态和任务继续由原类持有；私有节流仅通过新增同步方法判断到期或记录开始，槽位集合和私有 setter 不开放，原时间写入先后关系不变 |
| [QuotaRefreshCoordinationTests.swift](../QuotioTests/Shared/Accounts/QuotaRefreshCoordinationTests.swift) | 独立偏好、空目录、关闭后台服务，验证两条真实批量入口在槽位冲突或等待取消时不推进节流、不释放其他刷新持有的槽位 |

原 250 个成员均保留，其中 247 个成员正文与属性不变（除四个必要访问调整）；`refreshData` 的节流判断和两个批量入口的私有时间赋值只替换为原主类同步方法，不增加挂起点。主类新增两个方法后共 252 个成员，83 个存储、四个 Task 句柄、七个私有 setter、可变私有存储、Debug 钩子及前九个扩展保持不变。白名单与实际验证见[刷新协调拆分记录](features/quota-viewmodel-refresh-coordination-split-2026-10-15.md)。

## 代理生命周期分文件维护

第二轮第七批完整迁移七个原方法，主类从 1,376 行缩减到 1,253 行。以下路径位于 `Quotio/Shared/Accounts/ViewModels`：

| 文件 | 当前职责与保留边界 |
|---|---|
| [QuotaViewModel+ProxyLifecycle.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel+ProxyLifecycle.swift) | 启动／切换、完整模式初始化、禁用同步、升级检查、用量会话观察与获取器代理配置更新；完整保留原启动顺序、取消与会话检查、Observation 重订阅及原 Task 捕获，禁用同步和升级辅助仍私有 |
| [QuotaViewModel.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel.swift) | 原状态与任务宿主；停止事务、客户端替换、三种自动刷新循环、独立恢复、模式选择、监控初始化与回调注册留在主类，不开放可变私有存储或私有 setter |

本批原 252 个成员正文及属性保持一致，七个方法只调整维护位置。仅将原只读 `proxyStartFlow` 和七个实际跨文件方法开放为内部可见；83 个存储、四个 Task 句柄、七个私有 setter、全部可变私有存储、前十个扩展和 105 个测试源码保持原样。没有新增状态、任务或第二个队列消费者。白名单与实际验证见[代理生命周期拆分记录](features/quota-viewmodel-proxy-lifecycle-split-2026-10-15.md)。

## 预热流程分文件维护

第二轮第八批完整迁移八个原方法，主类从 1,253 行缩减到 1,127 行。以下路径相对于仓库根目录：

| 文件 | 当前职责与保留边界 |
|---|---|
| [QuotaViewModel+Warmup.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel+Warmup.swift) | 启用设置、每日时间计算、精确认证信息、目标与模型选择、逐模型执行；原串行、取消、进度和失败保留规则不变 |
| [QuotaViewModel.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel.swift) | 预热 Task、整轮及单账号防重、模型缓存与状态仍由原类维护；原单账号防重入口继续私有，缓存 TTL 与取消／会话规则不变 |
| [WarmupSettings.swift](../Quotio/Shared/Accounts/Models/WarmupSettings.swift) | 为离线测试允许注入临时偏好，默认仍为 `.standard`，原共享实例、全部键、解码、持久化和回调不变；ViewModel 默认仍注入 `.shared` |
| [QuotaWarmupTests.swift](../QuotioTests/Shared/Accounts/QuotaWarmupTests.swift) | 12 项隔离测试验证旧配置、设置、时间、停服计划、精确凭据、缓存及串行执行／取消；使用临时偏好与离线 HTTP 夹具 |

本批原 252 个成员均保留，原预热方法正文除必要权限外不变；仅原设置字段与初始化增加默认依赖注入。新增一个仅 Debug 的缓存样本方法后，逻辑成员为 253 个，不增加存储。83 个存储的名称、类型、顺序和所有权、四个 Task、七个私有 setter、全部可变私有存储、前十一个扩展和原 105 个测试源码保持原样。白名单与实际验证见[预热拆分记录](features/quota-viewmodel-warmup-split-2026-10-15.md)。

## 只读展示、账号切换及流程收尾

第二轮第九批完整迁移 14 个原成员，主类从 1,127 行缩减到 1,037 行。以下路径相对于仓库根目录：

| 文件 | 当前职责与保留边界 |
|---|---|
| [QuotaViewModel+Presentation.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel+Presentation.swift) | 九个即时只读计算：刷新进度与能力、监控状态及精确账号时间、认证目录分组和计数；不保存展示快照、修改状态或持有任务 |
| [QuotaViewModel+AccountMutations.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel+AccountMutations.swift) | 在原账号变更方法后归入五个 Antigravity 切换门面；仍使用同一个切换器，成功后按原顺序刷新额度，不增加账号世代或切换状态 |
| [QuotaViewModel.swift](../Quotio/Shared/Accounts/ViewModels/QuotaViewModel.swift) | 私有状态及懒加载相关读取、仪表盘／API Key／通知写入留在主类，保留原方法正文和受保护 setter |
| [QuotaFinalizationTests.swift](../QuotioTests/Shared/Accounts/QuotaFinalizationTests.swift) | 六个定向用例覆盖真实槽位与展示联动、监控状态优先级、切换确认／取消、密钥校验／失败／取消互斥；不执行真实 IDE 切换 |

253 个原成员正文、83 个存储、四个 Task、七个私有 setter 及全部可变私有存储保持一致；仅原 `refreshSettings` 的只读引用开放为内部可见。其余十一个既有扩展、账号变更扩展原十三个方法及原 106 个测试文件保持原样。收尾审计发现三项既有风险，本轮保留原流程并记录专项修复建议，详见[第九批实施与审计记录](features/quota-viewmodel-presentation-final-audit-2026-10-15.md)。

## 第九批后收尾专项修复

此前收尾审计记录的三项既有风险已完成[专项修复](features/quota-viewmodel-finalization-fixes-2026-10-15.md)。`QuotaViewModel` 继续持有 API Key 的请求令牌、来源校验、互斥及提交；`QuotaViewModel+QuotaRefresh.swift` 的后台列表读取也经过主类统一入口。`NotificationManager` 继续持有去重集合，用稳定提供商身份并兼容清理旧显示名键。仪表盘时间写入仍在主类，目录与用量两项均需当前会话的明确完成结果；`UsageStatisticsStore` 复用唯一消费者及等待屏障，新增私有本轮完成证据，不新增任务或转移状态所有权。

新增回归分别位于 `QuotioTests/Shared/Accounts/QuotaAPIKeyIsolationTests.swift`、`Infrastructure/System/NotificationIdentityTests.swift`、`BusinessModules/Dashboard/DashboardRefreshSessionTests.swift` 和 `Shared/Analytics/UsageDashboardRefreshTests.swift`。前述第三至九批的行数与成员计数是各批实施时的历史事实；当前修复按实际行为需要增加私有校验成员，保持原存储、Task 与 `private(set)` 的所有权。

## Monitor 运行类型按完整声明归位

第三轮第一批将原 1,110 行的 `MonitorRuntime.swift` 拆为同目录 16 个类型文件，旧合集已移除。以下路径均位于 `Quotio/Shared/Accounts/Monitor`，类型名称和原所有权不变：

| 职责 | 当前文件与边界 |
|---|---|
| 账号来源与值 | [MonitorAccountSource.swift](../Quotio/Shared/Accounts/Monitor/MonitorAccountSource.swift)、[MonitorAccount.swift](../Quotio/Shared/Accounts/Monitor/MonitorAccount.swift)：原身份、优先级、权限、禁用及显示回退规则 |
| 刷新模型与错误 | [MonitorRefreshIssue.swift](../Quotio/Shared/Accounts/Monitor/MonitorRefreshIssue.swift)、[MonitorRefreshBatch.swift](../Quotio/Shared/Accounts/Monitor/MonitorRefreshBatch.swift)、[MonitorCredentialAvailability.swift](../Quotio/Shared/Accounts/Monitor/MonitorCredentialAvailability.swift)、[MonitorRuntimeError.swift](../Quotio/Shared/Accounts/Monitor/MonitorRuntimeError.swift) |
| 凭据契约与保险库 | [MonitorCredentialStore.swift](../Quotio/Shared/Accounts/Monitor/MonitorCredentialStore.swift)、[MonitorOAuthCredential.swift](../Quotio/Shared/Accounts/Monitor/MonitorOAuthCredential.swift)、[MonitorCredentialVault.swift](../Quotio/Shared/Accounts/Monitor/MonitorCredentialVault.swift)：协议默认实现同文件，原 actor 同步 CAS、后端及读取世代完整保留 |
| 世代与存储 | [MonitorStateRevision.swift](../Quotio/Shared/Accounts/Monitor/MonitorStateRevision.swift)、[MonitorMetadataStore.swift](../Quotio/Shared/Accounts/Monitor/MonitorMetadataStore.swift)、[MonitorSnapshotStore.swift](../Quotio/Shared/Accounts/Monitor/MonitorSnapshotStore.swift)：原锁边界、路径、旧格式兼容与快照提交不变 |
| 发现与协调 | [MonitorAccountDiscovery.swift](../Quotio/Shared/Accounts/Monitor/MonitorAccountDiscovery.swift)、[MonitorRefreshCoordinator.swift](../Quotio/Shared/Accounts/Monitor/MonitorRefreshCoordinator.swift)：原依赖与挂起顺序、私有状态、嵌套 Flight、Task、共享等待及退避不变 |
| 原辅助类型 | [SecureAtomicFileWriter.swift](../Quotio/Shared/Accounts/Monitor/SecureAtomicFileWriter.swift)、[MonitorIdentity.swift](../Quotio/Shared/Accounts/Monitor/MonitorIdentity.swift)：原安全写入与身份规则；仅空白辅助从文件私有 String 扩展等价归入领域类型 |

16 个类型及一个协议默认扩展均保留；14 个声明正文逐字一致，另三个声明仅涉及约定的空白辅助等价适配。未开放任何原可变私有状态或 setter。原 111 个测试文件不改动，新增两项账号工厂回退测试；构建及 29 项定向回归通过。详见[第三轮第一批实施记录](features/monitor-runtime-type-split-2026-10-15.md)。

## 工作区会话按完整类型归位

第三轮第二批将原 1,542 行 `WorkspaceSessionService.swift` 拆为原 actor 门面与七个同名文件。全部文件仍位于 `Quotio/BusinessModules/Workspace/Sessions/Services`，没有新建服务层或改变运行时数据路径：

| 类型与当前文件 | 保留职责与边界 |
|---|---|
| [WorkspaceSessionService.swift](../Quotio/BusinessModules/Workspace/Sessions/Services/WorkspaceSessionService.swift) | 102 行，继续唯一持有原 `shared`、私有依赖和 Provider 字典，保留并发扫描汇总、排序、消息／删除分发与终端恢复 |
| [AgentSessionProviderProtocol.swift](../Quotio/BusinessModules/Workspace/Sessions/Services/AgentSessionProviderProtocol.swift) | 原 `Sendable`、`nonisolated` 与 `@concurrent` 契约完整保留 |
| [SessionIOUtils.swift](../Quotio/BusinessModules/Workspace/Sessions/Services/SessionIOUtils.swift) | 原 SQLite 列探测白名单、完整 UTF-8 行读取、日期与 UUID 辅助；仍为工作区内部类型 |
| [ClaudeSessionProvider.swift](../Quotio/BusinessModules/Workspace/Sessions/Services/ClaudeSessionProvider.swift) | 原主会话与子代理目录扫描、历史副本合并、消息与删除入口，私有方法随类型迁移 |
| [CodexSessionProvider.swift](../Quotio/BusinessModules/Workspace/Sessions/Services/CodexSessionProvider.swift) | 原当前数据库优先、rollout／archive／index 补全、关系合并及删除前重扫 |
| [OpenCodeSessionProvider.swift](../Quotio/BusinessModules/Workspace/Sessions/Services/OpenCodeSessionProvider.swift) | 原 SQLite 优先与旧 JSON 回退、消息排序、父子关系和删除分发 |
| [PiSessionProvider.swift](../Quotio/BusinessModules/Workspace/Sessions/Services/PiSessionProvider.swift) | 原双目录扫描、消息与会话父关系区分、路径归一和删除前重扫 |
| [AGYSessionProvider.swift](../Quotio/BusinessModules/Workspace/Sessions/Services/AGYSessionProvider.swift) | 原摘要库／JSON／brain／旧缓存合并、WAL 兼容及 transcript 回退；409 行，为本组最大文件 |

八个声明正文逐字一致，所有私有属性、嵌套类型、方法、隔离标注及任务所有权随原类型完整保留，无访问权限放宽。统一删除引擎、关系适配、模型、ViewModel 和存储服务均不改动；原 112 个测试文件不变。构建与定向验证范围见[第三轮第二批实施记录](features/workspace-session-provider-split-2026-10-15.md)，不重新拼回合集，也不为继续拆文件新建缓存或调度任务。

## CPA 公共业务能力归位

第三轮第三批处理已确认的实际依赖方向，不按代码行数继续拆文件：

- `CPAAccountWeight` 与 `CPASettingsValidationError` 在 CPA 配置接入层成组维护。保留旧名称、错误 case、本地化反馈和权重解析；底层管理客户端不再引用 Settings 内部规则。
- `CPARoutingStrategy` 的规范化、选项与展示映射整体归共享 CPA 展示能力。实际使用方为设置和路由，不增加额外规范值／展示转发层，也不改写磁盘策略。
- `CPARoutingSnapshot` 归共享 CPA 查询契约；`CPARoutingActivity`、`CPARoutingPresentation` 留在原路由业务，查询实现、有界候选、状态和光流时钟不变。
- `CPASettingsNumberRow` 归共享控件，原 Settings 文件移除；保留 Binding、标签、帮助及布局，不添加输入解析、保存或本地草稿。

`CPARequestSettings.swift` 继续维护设置专用 `CPAAdvancedSettingsDraft`。五个迁移声明、原草稿及路由余下两个类型正文逐字一致；未扩大权限、改变私有 setter 或迁移状态／任务所有权。构建及 27 项定向回归通过；详细范围见[CPA 公共业务归位记录](features/cpa-business-boundary-2026-10-15.md)。

## 账号共享能力与运行模式归位

第三轮第四批按实际使用方纠正边界：账号身份映射、IDE 显式扫描契约、授权协调及共享弹窗归 Shared/Accounts；共享运行偏好与 App 导航分别维护。IDE 选项、结果、隐私辅助和原 manager 继续成组，OAuthSheet 与私有 OAuthStatusView 继续同文件；不增加细碎转发层。

八个迁移声明正文原样，IDE 隐私扩展及管理 API 适配原样。OperatingMode 与原 manager 仅将 `visiblePages` 和 `isPageVisible` 完整移入 App 扩展，其他属性与方法不变；共享模式不再引用 NavigationPage。原 manager 的单例、private(set)、revision、偏好迁移以及原 QuotaViewModel 持有的扫描／授权依赖不变。

原 OAuth 协调器测试与运行模式测试分别归 `QuotioTests/Shared/Accounts`、`QuotioTests/Shared/AppSettings`，内容逐字不变。新增导航只读与共享弹窗生命周期回归，共三项；构建及总计 35 项定向回归通过。实际范围与隔离边界见[账号共享能力归位记录](features/account-business-boundary-2026-10-15.md)。

## 仍保留的状态与混合职责宿主

以下文件继续承担原状态所有权；第三至九批调整方法的维护位置、必要同步入口和默认依赖注入，未拆分应用状态、Task 或 manager 所有权。

| 文件 | 当前位置及保留原因 |
|---|---|
| `QuotaViewModel.swift` | `Shared/Accounts/ViewModels`：模型、只读展示、菜单投影、传输、OAuth、IDE、账号变更及切换、取数、刷新、代理启动及预热执行已分文件，主类仍为同一应用级状态、上下文、槽位、私有节流和任务宿主，保留停止／自动刷新／恢复、预热调度／防重／缓存、仪表盘／密钥／通知等受保护或私有写入；仍为单一 Target，未隔离编译依赖 |
| `ManualRefreshControls.swift` | `Shared/UI/Refresh`：含通用手动刷新状态和账号页菜单，避免仅为目录拆分状态来源 |
| `AnalyticsMaintenanceComposition.swift` | `App/Composition`：原 AnalyticsMaintenanceCoordinator 与 StorageDataDestination 成组，仍由 QuotioApp 唯一持有协调器，保留跨页面维护锁与原配置时机 |

## 存储维护的应用装配与设置业务

第三轮第六批将跨 ClientUsage、CallAnalytics、CPA 及缓存的应用维护编排整体归 `App/Composition`。协调器与目的地两个原声明正文不变，QuotioApp 的原 State 和环境注入不变。App 在普通设置与日志兼容入口向 SettingsScreen 注入延迟目的地；SettingsScreen 保持非泛型类型与原 NavigationPath、搜索和定位状态，只在原 storageData 导航分支调用注入入口，不反向读取 App 协调器或其他统计 VM。

服务仍在目的地原 task 时机幂等配置，不提前到应用启动或设置根页。设置业务内的 StorageMaintenanceService、StorageMaintenanceStore 与 StorageDataScreen 完整保留，页面只消费原服务，busy 与全部 private(set) 不开放；暂停采集、等待在途批次、同库原子清理、全部失效及恢复继续由原对象按原顺序执行。

原跨业务维护测试整体归 `QuotioTests/App/Composition/AnalyticsMaintenanceLifecycleTests.swift`，所有 115 个原测试文件内容保留，不为文件移动新增镜像测试。构建及 17 项相关定向回归通过；实际验证范围见[存储维护应用装配归位记录](features/storage-maintenance-composition-2026-10-15.md)。

## 监控授权会话专项修复

整理后专项修复仍在原 `Infrastructure/Providers/Monitor/MonitorOAuthCoordinator.swift` 维护监控授权，不再进行目录迁移。协调器通过原 MonitorStateRevision 同步锁保护 Claude 授权世代；保险库和元数据的受保护重载在实际写入前复核。原 activeTask 继续由原 actor 持有，只增加所属世代；VM 只注入默认 shared 的只读协调器引用，原 OAuthState 与 Task 所有权不变。旧请求不能保存取消后的凭据、清除新 pending 或回写新 UI；原保存接口、CAS、配置与类型保留。详见[监控 Claude 授权隔离修复](features/monitor-claude-oauth-session-isolation-2026-10-15.md)。

## CPA 启动首轮额度同步

`Shared/Accounts/ViewModels/QuotaViewModel+ProxyLifecycle.swift` 在两次目录读取和禁用同步之后，明确等待一次原批量额度刷新，避免本地首次读取记录的轮询节流阻断 CPA 首轮取数。两次目录读取不再隐式派生额度任务；后续预热顺序、状态与任务所有权、账号精确映射及菜单通知入口不变。后续启动流程调整须保留此来源切换边界，不能重新依赖账号页手动刷新。构建及 14 项离线定向回归通过，详见[CPA 启动菜单栏额度同步修复](features/cpa-startup-menubar-quota-sync-2026-10-15.md)。

## 菜单栏原位更新与统一明细

`App/MenuBar/StatusBarManager.swift` 只在打开时重新装配原生菜单，跟踪期间由 `StatusBarMenuBuilder` 的 body 读取更新原 SwiftUI 承载内容，账号增删和排序留到下次打开。`Views/MenuAccountDetailView.swift` 是所有提供商的只读额度明细，内部限高滚动，Codex 分析保留嵌套入口。原三种额度样式、配置、精确身份、刷新入口及 IDE 切换保留；不得通过恢复跟踪期间整份重建来补内容更新，也不新增第二份额度状态。详见[菜单栏第一批升级记录](features/menubar-upgrade-phase-one-2026-10-15.md)。

账号额度历史位于 `Shared/Accounts/QuotaHistory`，按观测契约、周期纯规则、SQLite 存取和查询展示组织；菜单和设置共同使用。`AppBootstrap` 持有唯一服务并注入菜单、历史窗口、设置环境和维护装配，不新增业务单例或向 `QuotaViewModel` 添加存储属性。发布者只同步传递已提交的模式及新旧快照；历史读写不启动额外额度轮询。原菜单项稳定性、模式与精确账号隔离、清理水位和原维护屏障须保留。详见[菜单栏第二批额度历史与消耗参考](features/menubar-quota-history-phase-two-2026-10-15.md)。

Copilot 主机路由及原生配置解析集中于 `Infrastructure/Providers/Copilot`，由原 OAuth、额度与账号目录共用；企业主机随凭据保存，不存为全局默认。Claude 原生 NFC／钥匙串服务名归 `Infrastructure/Providers/QuotaFetchers/ClaudeQuotaCredential.swift`，取数与发现共享规则，不修改公共路径展开或其他客户端目录。原授权与刷新任务宿主、API 账号索引及文件安全边界保留。详见[Copilot GHE.com 与 Claude NFC 适配记录](features/copilot-ghe-and-claude-nfc-2026-10-15.md)。

## 测试目录与共享夹具

布局重入与近期同步改动的[专项复审记录](features/appkit-layout-reentry-and-followup-audit-2026-10-15.md)说明了弹窗尺寸、Copilot 主机／占位身份、历史重键和期限、CLI 渠道与终端参数的边界。`Infrastructure/Process/ShellCommand.swift` 由终端和 CLI 渠道复用，不持有运行状态；历史 Timeline 只驱动可见 UI，不增加取数或采集任务。

Antigravity 全模型弹窗仍由 `BusinessModules/Accounts/Views/AccountQuotaContent.swift` 的原状态呈现，弹窗及私有卡片保留在同目录 `AntigravityModelsDetailSheet.swift`。展示模式与隐私以值从调用方注入；加载／空数据不能卸载 presenter。定向原生布局测试归 `QuotioTests/BusinessModules/Accounts/AntigravityModelsDetailSheetTests.swift`，见[PR #558 适配与布局回归](features/antigravity-models-sheet-layout-2026-10-15.md)。

`QuotioTests` 同步分为 `App`、`BusinessModules`、`Shared`、`Infrastructure` 和 `Support`。测试就近映射主要验证对象，不因文件迁移删除行为覆盖或重命名测试类。

`Support/Networking/LifecycleHTTPFixture.swift` 保存跨测试类使用的离线 HTTP 夹具，避免账号、管理客户端、日志生命周期与额度测试依赖另一个业务测试文件的声明。临时账号、偏好、数据库和网络响应继续隔离，不能借测试访问真实授权或启停 CPA。

Xcode Scheme 仍为 `QuotioPlus`，测试 Target 仍为 `QuotioPlusTests`。目录改变不改变 `-only-testing` 的类名选择，按改动选择必要用例：

```bash
xcodebuild test -project Quotio.xcodeproj -scheme QuotioPlus \
  -destination 'platform=macOS' \
  -only-testing:QuotioPlusTests/AnalyticsNavigationTests
```

禁止运行不带 `-only-testing` 的全量测试。目录迁移首先核对文件完整性、工程路径和资源包含关系，再完成构建及少量跨层定向验证；构建结果以实际日志为准。

## 后续放置规则

新增功能先确认业务归属，再根据真实复用关系选择 `Shared`。业务内部的专用服务与模型跟随业务；外部系统接入跟随 `Infrastructure`。不要恢复顶层集中式 `Views / ViewModels / Models / Services`，也不要新增一个无职责边界的 `Common` 或 `Utils` 目录。

新增、移动文件后同步更新本页、[项目索引](PROJECT.md)、[二次开发维护入口](SECONDARY_DEVELOPMENT.md)及受影响的本地文档链接。历史审计的日期、上游提交、原始 GitHub URL 和原始验证事实保留；已经移除的历史文件名称不伪装为当前入口。
