# 第三轮后续优化：业务边界审计与历史任务纠偏

日期：2026-10-15。状态：**六批已完成，后置候选未自动实施**。本页保留原静态审计事实和整体排期；第三至六批的实际范围与验证分别见[CPA 公共业务归位记录](cpa-business-boundary-2026-10-15.md)、[账号共享能力归位记录](account-business-boundary-2026-10-15.md)、[模型目录与 Pi 路径归位记录](model-catalog-business-boundary-2026-10-15.md)、[存储维护应用装配归位记录](storage-maintenance-composition-2026-10-15.md)。审计问题描述与行号对应审计时版本，已归位类型的链接指向当前维护位置。

承接用户确认的业务分类原则：按业务能力、共同变更原因、实际使用方及状态／任务所有权决定边界。行数只是审计线索，不作为拆分目标、排期或验收指标。此前完整类型迁移是对应批次的实施方式，不作为后续一类型一文件的要求。

## 1. 审计范围和结论边界

本次检查账号与监控、菜单栏、客户端配置、CPA 接入与运行时、设置、统计与路由、工作区及存储维护，交叉核对历史目录整理、公共模型归位、独立视图及 QuotaViewModel 扩展拆分。采用源码调用方检索、关键流程阅读和三路只读审计；引用扫描只用于寻找候选，不将词法命中数量当作已确认问题数量。

结论是：**下一步优先纠正已确认的业务契约归属和实际复用入口，保留现有事务与状态宿主。** 这次没有证明存在新的线上功能故障，也不代表穷尽所有运行时、性能或兼容性问题。没有修改生产源码或测试，没有执行构建、全量或定向测试；后文测试均为未来实施时的必要验证候选。

不变约束：保留现有功能、配置键与路径、类型名称、private(set)、状态和 Task 所有权；受保护写入仍由原宿主执行。未来编写或优化代码补充详细中文注释。本方案不包含拆成 Swift Package、迁移用户数据、重建单例或替换统计口径。

## 2. 已确认的高价值问题

### 2.1 CPA 公共规则混在 Settings 表单文件，事实查询契约混在路由展示文件

- [CPARequestSettings.swift](../../Quotio/BusinessModules/Settings/Models/CPARequestSettings.swift) 第 5、42、53、69 行依次定义共享路由策略、账号权重、校验错误和设置草稿。同文件的前几种类型已经服务多个业务，草稿则专属于设置表单。
- [ManagementAPIClient.swift](../../Quotio/Infrastructure/CPA/API/ManagementAPIClient.swift) 第 534 行、[CustomProviderModels.swift](../../Quotio/Shared/Accounts/CustomProviders/Models/CustomProviderModels.swift) 第 219 行及 [CustomProviderService.swift](../../Quotio/Shared/Accounts/CustomProviders/Services/CustomProviderService.swift) 第 464 行调用 Settings 内的权重规则，形成实际的反向引用。
- [RoutingStageView.swift](../../Quotio/BusinessModules/Dashboard/Routing/Views/RoutingStageView.swift) 第 339 行使用审计时位于 Settings 的路由策略；账号权重 Sheet 和连接权重区域复用原 Settings 的 [CPASettingsNumberRow.swift](../../Quotio/Shared/UI/Controls/CPASettingsNumberRow.swift)。这些共同规则和绑定控件已有真实跨业务使用方，第三批已归位共享能力。
- [CPARoutingPresentation.swift](../../Quotio/BusinessModules/Dashboard/Routing/Models/CPARoutingPresentation.swift) 第 5 行的 `CPARoutingSnapshot` 只含事件、计数和时间边界，却被 Shared 的 [CPAUsageEventStore.swift](../../Quotio/Shared/Analytics/CPA/Services/CPAUsageEventStore.swift) 第 371 行、[UsageLedger.swift](../../Quotio/Shared/Analytics/CPA/Services/UsageLedger.swift) 第 75 行和 [UsageStatisticsStore.swift](../../Quotio/Shared/Analytics/CPA/Services/UsageStatisticsStore.swift) 第 263 行作为查询结果返回。它是共享事实契约，不属于 Dashboard 私有展示。

纠正方向：协议数值约束与兼容错误按 CPA 接入契约维护；共享策略展示和通用输入组件按实际复用归位；设置草稿、基线、保存锁留 Settings；查询快照归 Shared/Analytics/CPA，动画活动与账号展示留 Dashboard。

### 2.2 共享账号能力仍依赖 App 或页面内部类型

- [QuotaViewModel+MenuBar.swift](../../Quotio/Shared/Accounts/ViewModels/QuotaViewModel+MenuBar.swift) 第 16、39、89 行调用审计时位于 App 的 [MenuBarAccountCatalog.swift](../../Quotio/Shared/Accounts/Presentation/MenuBarAccountCatalog.swift)。其中 aliases 参与额度与订阅缓存的身份归一，并非仅菜单 UI 格式化。第四批已按共享账号身份能力归位。
- [QuotaViewModel.swift](../../Quotio/Shared/Accounts/ViewModels/QuotaViewModel.swift) 第 170 行持有审计时位于 Accounts 页面目录的 `IDEScanSettingsManager`；其选项、结果和 manager 现成组归位于 [IDEScanSettings.swift](../../Quotio/Shared/Accounts/Services/IDEScanSettings.swift)。共享扫描契约与显式同意状态由原类型保持，扫描表单继续留账号页面。
- [DashboardScreen.swift](../../Quotio/BusinessModules/Dashboard/Views/DashboardScreen.swift) 第 88 行与账号页都使用 [ProvidersScreen.swift](../../Quotio/BusinessModules/Accounts/Views/ProvidersScreen.swift) 第 891 行的 `OAuthSheet`。共享授权 Sheet 与私有 `OAuthStatusView` 是同一 UI 能力，应同组归共享账号视图，保留原状态和取消逻辑。
- [CPAOAuthSessionCoordinator.swift](../../Quotio/Shared/Accounts/Services/CPAOAuthSessionCoordinator.swift) 审计时位于 API 目录，第 17—24 行持有授权世代、任务、远端 state、展示 `OAuthState` 和回调；实际由原 QuotaViewModel 唯一持有。第四批已按账号授权会话编排归位，未按端点拆成新服务。

审计时运行模式同时混有共享偏好与 App 导航：[OperatingMode.swift](../../Quotio/Shared/AppSettings/OperatingMode.swift) 原第 16 行的模式与第 113 行的 manager 被共享业务使用，原第 79、134 行又引用 `NavigationPage`。第四批已保留同一模式／manager，并将两个原导航成员完整归 App 扩展；共享模式不再保留导航类型引用。

### 2.3 模型目录读取穿过不相关的客户端配置服务，存在真实请求重复

- [DashboardModelCatalogLoader.swift](../../Quotio/Shared/ModelManagement/Services/DashboardModelCatalogLoader.swift) 审计时第 22、36—37 行为只读目录创建配置服务并构造 `.claudeCode` 配置；[PiAgentConfigurationService.swift](../../Quotio/Infrastructure/AgentClients/PiAgentConfigurationService.swift) 审计时第 104—107 行也回调创建 `AgentConfigurationService`。第五批已改为直接使用共享读取业务，链接指向归位后的 Loader。
- [AgentConfigurationService.swift](../../Quotio/Infrastructure/AgentClients/AgentConfigurationService.swift) 第 1950 行承担目录请求，第 1971 行承担候选模型及 Copilot 筛选，第 1988 行的连接测试又构造相同端点、认证和超时的请求。重复的是传输构造和发送，三种结果语义并不相同。
- 原 Loader 的使用事务通过 QuotaViewModel 同时服务仪表盘和 [AgentSetupScreen.swift](../../Quotio/BusinessModules/AgentConfiguration/Views/AgentSetupScreen.swift) 第 47 行，已具备跨业务复用依据，适合整体归 Shared/ModelManagement。

必须保留：live catalog 不替换或过滤空结果；配置候选保留 Copilot 筛选和原页面兜底；连接测试允许 HTTP 200 但没有可解析模型列表时仍判定连接成功。不得用一个严格解析入口抹平三种语义。

第五批已将三种读取业务成组归 `AgentModelCatalogService`，共用请求传输归 `ModelCatalogClient`；旧配置服务签名保留兼容，配置写入与全部状态仍在原宿主。详细实施与验证见第五批记录，不以此扩展原审计结论。

### 2.4 Pi 本地路径契约埋在 Analytics 来源实现，底层反向引用业务

[PiClientUsageSource.swift](../../Quotio/BusinessModules/Analytics/ClientCalls/Services/ClientUsage/PiClientUsageSource.swift) 第 6 行的 `PiSessionPaths` 同时包含路径展开、agent 目录、会话根和依赖业务时钟的 timestamp。底层 [PiAgentInstallation.swift](../../Quotio/Infrastructure/AgentClients/PiAgentInstallation.swift) 第 32、108 行及配置服务第 11 行调用其中路径方法。

纠正方向：路径规则归客户端本地环境契约；timestamp 留 Analytics 业务支持，保留同名类型／方法和实际语义。不能整块下移后继续依赖 `CallAnalyticsClock`，也不能借此改变任何客户端的扫描范围。

第五批已将三个原路径方法整体归 [PiSessionPaths.swift](../../Quotio/Infrastructure/AgentClients/PiSessionPaths.swift)，timestamp 保留在 Analytics 同名扩展并显式保持 `nonisolated`。安装、配置、统计扫描及双文件回滚规则不变。

### 2.5 应用级存储维护装配放在 Settings 视图文件

[AnalyticsMaintenanceComposition.swift](../../Quotio/App/Composition/AnalyticsMaintenanceComposition.swift) 中的 `AnalyticsMaintenanceCoordinator` 审计时位于 StorageDataDestination.swift 第 6 行，装配两个 Analytics VM、CPA 消费器及缓存清理；实际实例由 [QuotioApp.swift](../../Quotio/App/QuotioApp.swift) 第 184 行唯一持有。

这属于 App 装配。纠正时要连同目的地装配壳一起考虑：只搬 coordinator 会让 Settings 的 `@Environment` 继续反向依赖 App。原 `StorageMaintenanceService` 只接收闭包、持有原状态，可以留在设置维护业务；Store 保留用户选定的三个统计范围、同库原子删除和迁移墓碑，不因使用 SQL 下沉为通用设施。

第六批已将协调器与目的地完整成组归 App，并由 App 向设置导航注入延迟目的地；原服务、Store、私有 setter、幂等配置时机及维护顺序不变。原跨业务维护测试整体归 App/Composition，实际范围与验证见第六批记录。

## 3. 重复逻辑的判断：哪些可以处理，哪些保持独立

| 观察 | 本次判断与计划 |
|---|---|
| 模型目录和连接测试重复请求构造 | 已确认，可统一无状态传输；解析、筛选、兜底和错误呈现仍按调用语义保留 |
| 额度显示方向、未知值及颜色计算分散 | [QuotaDisplayPreferences.swift](../../Quotio/Shared/AppSettings/QuotaDisplayPreferences.swift)、[QuotaPercentagePresentation.swift](../../Quotio/Shared/Accounts/Presentation/QuotaPercentagePresentation.swift)、[QuotaDisplayHelper.swift](../../Quotio/BusinessModules/Accounts/Views/QuotaDisplayHelper.swift)、菜单布局有相近规则，但非有限值守卫与展示策略存在差异；先建立行为对照，再决定共用纯计算，不直接列为已可实施的统一算法 |
| Token 与工具调用都扫描客户端日志／SQLite | 不合并。OpenCode 前者读取 message 使用量，后者读取 part 工具事件；字段和事实口径不同 |
| 两种客户端统计都有历史归档和日汇总 | 不合并。工具调用保留高水位并固定首次时区；Codex Token 支持迟到父／前驱重投影，合法结果可下降，页面可按当前日历分桶 |
| Claude 路径逻辑近似 | 现有 Token 单目录与工具调用多目录／兜底策略不同，统一扫描覆盖属于功能决策，另议，不能夹带在去重中 |
| Codex 配置和技能配置都有 TOML 扫描 | 不合并。前者维护模型与 provider，后者只编辑 `[[skills.config]]`，目标键、拒绝条件及写后验证不同 |
| OpenCode JSONC 编辑器内部辅助较多 | 已被客户端配置和工作区技能两处实际复用，保留语法树、定位、编辑及回读验证的内聚性 |
| 多处 SQLite prepare／bind／execute | 已有 `AnalyticsDatabase` 共用底座；CPA 的部分辅助是兼容转发，不再抽第二个 SQL 框架 |
| Pi 与其他配置服务都有短备份辅助 | 暂不专门抽公共工具。Pi 双文件回滚与配置写入构成事务，不能简化为通用逐文件写入 |

统计差异证据：[OpenCodeClientUsageSource.swift](../../Quotio/BusinessModules/Analytics/ClientCalls/Services/ClientUsage/OpenCodeClientUsageSource.swift) 第 148、225、243 行；[OpenCodeCallEventSource.swift](../../Quotio/BusinessModules/Analytics/ClientCalls/Services/CallAnalytics/OpenCodeCallEventSource.swift) 第 76、208 行；[CallAnalyticsArchiveStore.swift](../../Quotio/BusinessModules/Analytics/ClientCalls/Services/CallAnalytics/CallAnalyticsArchiveStore.swift) 第 32、120 行；[ClientUsageSQLiteLedger.swift](../../Quotio/BusinessModules/Analytics/ClientCalls/Services/ClientUsage/ClientUsageSQLiteLedger.swift) 第 158 行。以上保留是业务口径决定，不以相似代码片段作为充分去重理由。

## 4. 历史拆分任务的同步纠偏

以下表格记录审计时拟定的纠正方案。第三批涉及的 CPA 公共规则、查询契约和输入组件，第四批涉及的共享账号、授权与模式／导航，第五批涉及的模型读取与 Pi 路径，以及第六批涉及的存储维护应用装配现已归位；其余条件候选没有自动实施。历史实施记录保留当时事实，新方案取代后续按行数或声明数量排期的方式；不把表格中其他拟议迁移视为已经完成。

| 历史组织或后续拆分思路 | 新决定 |
|---|---|
| QuotaViewModel 的授权、凭据传输、刷新、代理生命周期、预热和展示扩展 | 保留按职责定位；纠正“已完成业务隔离”的理解。仍为同一状态宿主的方法分文件维护，不再安排继续搬剩余方法的默认批次 |
| MenuBarAccountCatalog 位于 App、IDE 扫描契约位于 Accounts 页面、共享 OAuth UI 留 ProvidersScreen | 需要纠正到实际共享账号能力，作为第四批范围；状态和会话所有者不变 |
| DashboardModelCatalogLoader 位于 Dashboard | 真实跨页使用，整体归共享模型目录业务；不再把其两个闭包各拆一个服务 |
| CPA 权重／策略共用规则位于 Settings、查询快照位于 Dashboard | 需要纠正，作为第三批优先范围；页面草稿和动画模型留原业务 |
| CPAOAuthSessionCoordinator 被视为 API 底层接入 | 纠正为账号授权会话编排；保留完整协调器与唯一实例，HTTP 调用实现留基础设施 |
| Monitor 的 Vault、Revision、Metadata、Snapshot、Discovery、Coordinator | 保留。边界对应不同锁、持久化、actor 与任务职责，有明确依据 |
| Monitor 小型值契约已经各占一文件 | 允许随同一业务变更合理合组，但目前没有足够痛点支持专门回合并。取消继续一类型一文件的任务，不重新拼回 MonitorRuntime 合集 |
| 五个会话 Provider 按客户端独立，门面保留装配 | 保留。外部磁盘协议与兼容来源不同，是明确适配边界；不继续按解析／消息／删除方法机械拆开每个 Provider |
| 工作区安全、事务和删除辅助包含多个类型 | 保留类型组。预检、暂存、数据库修改、提交与回滚共同构成安全事务，不能为文件变短拆成异步服务链 |
| 工作区 WorkspaceModels 同时放导航、会话、技能和存储模型 | 将来随对应业务调整时按能力成组归位，角色与消息、仓库与技能、容量与报告可以分别同文件维护；不安排逐类型拆分，也不因此拆开 WorkspaceViewModel 的状态 |
| Shared 中的客户端身份／配置模型包含 UI 信息 | 类型名称与 rawValue 保留；后续将颜色等展示与身份／路径契约区分。CLIAgent 文件“工作区共同使用”的注释与实际调用不符，列入修正；工作区实际使用 WorkspaceAgent，不统一两种枚举 |
| 共享图表整文件都被当作公共或私有 | 按实际使用方维护。AdaptiveGrid、Summary 确有复用；少数单业务控件可随该 UI 维护归位，不启动全图表回搬任务 |
| 设置分区、版本弹窗与专属辅助按完整组迁移 | 保留；不继续拆 PathLabel、NetworkAccessSection 或私有版本行，也不因短文件数量再逆向合并 |

## 5. 调整后的第三轮实施顺序

六批已经完成，第三至六批按下列业务范围验收。其他项目保留为条件候选，不预先凑满拆分批次，不回退既有功能。

| 批次 | 业务目标 | 先做原因及前置关系 |
|---|---|---|
| 第三批 | CPA 路由与账号调度公共契约归位 | 明确的 Infra／Shared → Settings、Shared → Dashboard 反向引用，范围可控；为后续账号边界提供共同规则 |
| 第四批 | 共享账号身份、扫描及授权能力归位 | 清除共享刷新对 App 菜单及页面内部类型的依赖；以第三批公共契约为基础，先理清共享运行模式与导航扩展 |
| 第五批 | 客户端接入的模型目录与本地环境边界 | 解决已有真实重复请求、Dashboard／Pi 绕行配置服务、Infra → Analytics 的 Pi 路径依赖；两个子范围在同一客户端接入业务内分别验收 |
| 第六批 | 存储维护应用装配归位 | 纠正跨 Analytics／CPA／缓存的 App 编排放置，完整保护维护屏障；与前几批运行时无强依赖，按独立范围完成 |

### 第三批工作包

- **拥有范围**：CPARequestSettings 中公共规则与必要错误契约、Routing Presentation 中 Snapshot、CPASettingsNumberRow，以及已有使用方和对应维护索引。所有目标仍属于原单一 Target。
- **边界**：CPA 权重与兼容错误按 `Infrastructure/CPA/Configuration` 接入契约成组维护；策略规范值与展示映射按实际依赖区分，底层不引入 View／Binding；数值输入控件归 `Shared/UI`；Snapshot 归 `Shared/Analytics/CPA/Models`。具体同文件组合以规则内聚为准，不要求一类型一文件。
- **必须保留**：设置草稿、scope 基线、保存锁与读取抑制在原视图；权重 nil／非正数／上限与旧错误行为；策略别名与未知值回退；路由事件有界读取、慢请求候选、固定账号顺序和光流；消费者与账本原实例、Task 和事务不动。
- **必要验证候选**：CPARequestSettingsTests、CPASettingsInteractionTests、CPA8ProviderPatchTests、CPA8ManagementAPIContractTests；只选涉及的权重、策略和 PATCH 方法。Snapshot 搬迁使用 CPARoutingTests 的相关方法；只有触及活动使用入口时补 RoutingAccountPositionTests／RoutingFlowAnimationTests，不扩展为全部统计测试。
- **完成标准**：上述公共规则调用不再引用 Settings 私有类型，Shared 查询不再使用定义于 Dashboard 的契约；无规则副本、无新增状态／消费者，原值和错误兼容不变。

### 第四批工作包

- **拥有范围**：MenuBarAccountCatalog、IDEScanSettings、OAuthSheet 与私有 OAuthStatusView、CPAOAuthSessionCoordinator 的业务归属，以及 OperatingMode／Manager 的共享运行偏好和 App 导航扩展。必要调用与测试路径同步调整，账号专用行模型和表单留 Accounts。
- **前置**：第三批；模式与 manager 的共享归位先于依赖它的身份规则。`visiblePages`、`isPageVisible` 按导航责任留 App 扩展，不能让共享模式继续依赖 NavigationPage。
- **必须保留**：同一个 manager、模式 revision 与历史偏好迁移；所有私有 setter；账号精确身份、歧义拒绝和固定项排序；IDE 扫描显式同意；OAuth coordinator 的 Task／generation／期限／回调会话及原 Sheet 的 @State、自动关闭、取消归属。
- **必要验证候选**：OperatingModeTests、AuthFileIdentityTests、MenuBarAccountSyncTests、IDEQuotaRefreshTests 中相关方法、CPAOAuthSessionCoordinatorTests 中设备流／取消／迟到回调相关方法；移动共享 Sheet 后按已有页面渲染用例检查两个使用方。
- **完成标准**：已确认的共享账号 → App 菜单／Accounts 扫描类型、Dashboard → Accounts 授权 UI 引用消除；不复制状态或授权会话，不新增另一个账号协调器。不把整个 QuotaViewModel 搬到 Accounts。

### 第五批工作包

- **拥有范围 A（共享模型目录）**：AgentConfigurationService 的目录传输、PiAgentConfigurationService 的目录调用、完整 DashboardModelCatalogLoader、必要调用点及 ModelCatalog 测试。Loader 整体归 `Shared/ModelManagement/Services`；无状态的传输接入接收显式端点和客户端密钥，原配置服务接口按兼容需要保留，不增加转发层级。
- **拥有范围 B（客户端本地环境）**：PiSessionPaths 的路径契约及安装／配置／统计调用点；颜色等客户端展示扩展按使用方归位。timestamp 留 Analytics，不将 CallAnalyticsClock 下沉；不扩展任何扫描目录。
- **必须保留**：管理密钥与客户端 key 分工，先读本轮 key 再查模型；原 QuotaViewModel 的 requestID／sessionID、private(set) 提交与缓存所有权；配置 VM 回填 Task 与兜底；Pi 原安装、备份、写后重读和双文件失败恢复；三种目录／连接语义分别保留。配置格式编辑和所有多文件提交事务继续由原服务执行。
- **必要验证候选**：ModelCatalogTests、DashboardModelCatalogLoaderTests、DashboardRefreshSessionTests 的相关方法；离线传输样本覆盖空目录、筛选、HTTP 200 非目录、错误与取消。PiCompatibilityTests 选路径、安装和自动保存目录校验方法；只有路径使用方受影响时补 ClientUsageIncrementalScanTests／CallAnalyticsLifecycleTests 对应 Pi 用例。
- **完成标准**：Dashboard 读目录无需构造配置写入服务或虚构客户端配置；Pi 不再反向创建另一份配置服务；共用请求构造只保留一处，调用语义仍独立；底层 Pi 路径不再依赖 Analytics 声明。这里改善的是维护和依赖方向，不宣称已隔离编译模块。

### 第六批工作包

- **拥有范围**：StorageDataDestination 中应用 coordinator 与目的地装配壳、QuotioApp 环境装配及 Settings 的 service 注入连接。原 StorageMaintenanceService／Store 类型与业务职责保留。
- **前置**：独立于前三个业务包，但避免与 App／Settings 同文件编辑交错；没有增加运行时依赖。
- **必须保留**：QuotioApp 持有同一 coordinator；原 service 的 private(set)、busy 互斥和配置时机；暂停采集 → 等在途 → 原子删除 → 全部失效 → 恢复的顺序；关闭或重建目的地仍使用同一维护锁。三个账本、CPA 唯一消费者、扫描世代和任务仍归原宿主。
- **必要验证候选**：AnalyticsMaintenanceLifecycleTests、StorageMaintenanceTests 中重入、暂停／恢复、删除后读取失败及墓碑相关方法。
- **完成标准**：Settings 不再直接装配其他业务 VM，也不反向读取 App coordinator 类型；目的地只消费注入的原服务，删除完成后失败和迟到结果不能复活旧状态。

## 6. 后置候选和明确停止的拆分任务

### 条件候选

1. **额度呈现规则**：先对未知、负值、非有限值、已用／剩余方向、颜色和重置时间建立调用方行为矩阵。只有证明规则相同才共用纯计算；不同展示政策显式保留。不是下一批自动实施项。
2. **工作区业务模型**：以后修改会话、技能或容量功能时，成组归位对应模型并将导航／颜色留展示层；WorkspaceViewModel 的修订号、删除进度、两个任务、列表缓存及统一结果呈现仍留原类。当前扫描／关系／删除链路已经内聚，不另排继续拆 Provider 或 Safety 的任务。
3. **技能仓库发现与安装**：远端读取、YAML 描述、来源元数据与安装编排确实共处 WorkspaceSkillService，但发现、更新、导入都复用原方法，尚无证据要求新建通用技能框架。若后续有独立业务变更，可先隔离纯规则；busySkills、repositoryTrees、网络等待后的变更校验与磁盘／SQLite提交仍留原 actor，固定 SHA 目录树和资源下载保持同一快照。
4. **应用身份归属**：AppIdentity 的 Bundle／兼容身份被 Logger、LanguageManager、Keychain 和更新等基础设施实际使用，可在基础接入维护时整体纠正位置，保留原身份值和钥匙串迁移。无需为每个调用方引入协议或复制读取逻辑。

### 需要另行设计的现有耦合

- QuotaViewModel 仍持有 NavigationPage 和懒创建的 AgentSetupViewModel；这是实际应用协调债务。当前保留状态所有权，不能靠把这些属性搬进新 manager、复制 VM 或把整个 QuotaViewModel 移入 Accounts 来解决。先保留并明确记录，不宣称第三／四批会清除所有反向依赖。
- CLIProxyManager 直接读取 CustomProviderService 并确认同步；启动后的 v8 补丁、迁移备份和条件恢复形成完整事务。未来如要解耦，先设计冻结输入及成功确认出口。进程、会话 UUID、启动／停止等待者、串行同步和恢复任务仍归原 manager；本轮取消按 MARK、端点或方法组拆扩展的默认任务。
- ManagementAPIClient 返回的 UsageQueueBatch 连带 UsageRecord／CPAUsageContext 的解析与脱敏链，基础设施和共享领域存在真实依赖。单搬一个批次类型无法解决，需按外部响应契约与内部事实分清边界后再议。本次不批量迁移所有 DTO。
- 架构标准的依赖目标不能当作现状已经满足；“一页面一 VM”“严禁增加任何状态属性”等规则也不应用来迫使复制状态或把必要会话保护放到错误宿主。实施时同步纠正相关维护说明，以业务边界和已有所有权约束为准；本方案不授权状态所有权迁移。

### 停止安排

- 按剩余文件行数排名，依次把每个大文件拆短。
- 把完整类型归位固定为所有场景的一类型一文件。
- 继续分拆 QuotaViewModel 的受保护写入、Monitor CAS／Flight／共享等待、CPA 消费器批次提交、会话删除事务。
- 将 Token 与工具调用合成一套扫描器／高水位／SQL 账本，或将客户端配置与技能 TOML 编辑强行合并。
- 为已经有 AnalyticsDatabase 的代码再建 SQL 框架，为短备份辅助建立通用工具目录。

## 7. 实施验收与本次材料

未来每批先锁定上述业务范围及实际调用方，再修改代码；只构建并执行实际受影响的方法级定向验证。完整类型移动先做声明／权限完整性核对；涉及请求复用或纯规则调整时增加能区分旧语义的样本验证。测试按被验证的业务场景归属，不以新增一个源文件就配一个镜像测试为目标。

验收以具体引用方向得到纠正、重复规则只有一个权威入口、不同语义仍分别保留为准；同时核对类型名、配置、原始值、私有 setter、实例／任务所有者和事务顺序。目录只是维护边界，本项目仍是单一应用 Target。

本次静态材料：`/tmp/quotio-business-audit-before-20261015.json` 保存审计前文件哈希；`/tmp/quotio-business-boundary-reference-candidates-20261015.json` 是词法候选引用清单，须结合本报告确认结果阅读；`/tmp/quotio-business-boundary-audit-verification-20261015.json` 记录本任务文档范围、链接和现有测试类核对。审计材料不包含真实凭据和用户会话数据。

并发工作区边界：审计期间检测到 `ProxySettingsSection.swift` 和 `docs/standards/DESIGN_COMPONENTS.md` 另有变化，本任务未编辑或回退这些文件。因此不将工作区全部差异归为本次审计，也不声称全部源码哈希未变；涉及设置的后续实施先重新读取当时最新版本，再按本方案锁定范围。
