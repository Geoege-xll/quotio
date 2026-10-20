# Quotio 二次开发与上游合并维护指南

本文用于说明本项目从哪里二开、当前改了什么，以及后续如何同步上游而保留本地功能。仓库状态核对日期：**2026-09-05**。文中命令是维护步骤，不代表已经执行远端配置、拉取、提交或合并。

**2026-09-08 首发整理**：QuotioPlus 使用 `1.0.0`（构建号 `73`）作为首个独立发行版，将首发前的 28 个本地开发提交及未提交源码合并成一个提交，父提交保留为上游基线 `13fd478c5b69f361d078e3b3bfc7ec041dde850d`。原作者历史继续保留，旧本地开发历史保存在 `codex/backup-before-v1.0.0-20260908` 备份分支；备份分支不随首发上传。以下第 2 节是二开初期的历史核对记录，首发内容以 [1.0.0 发行说明](releases/1.0.0.md) 为准。

**2026-09-17 选择性同步**：已配置原作者 `upstream`，从 `0.31.0` 基线对比到 `v0.32.0` 及 `73c383e`。按用户选择保留当前架构、移植适用修复；采用项、已覆盖项及暂缓项见[本次比对记录](upstream-sync/2026-09-17.md)。以下早期仓库状态是历史记录，不代表当前仍未配置上游。

## 1. 上游与参考项目分别是谁

2026-10-19 的[交叉修复](features/cross-agent-compatibility-fixes-2026-10-19.md)明确：目录 ID 不代表 1M 启用授权；OpenAI 兼容提供商需显式注册模型；Claude 角色链由统一计划展开为最终请求目标。账号变更的世代必须同时保护网络返回和已排队的文件提交，不能只在 MainActor 调用 actor 前后检查。冷却倒计时仅驱动可见展示，后续合并不可借此增加额度轮询。

2026-10-15 的[专项复审](features/appkit-layout-reentry-and-followup-audit-2026-10-15.md)补齐原生 Sheet 的显式 fitted 尺寸策略；同步时保留严格 Copilot 主机元数据、gh users 多账号、同主机占位收尾及历史发布的别名比较基线。CLI 渠道不能仅凭 Homebrew 前缀或 npm 发行名猜测；卸载不提前删配置，终端不能混合解释不同 Shell 的配置或覆盖用户 PATH。当时非 Pi 静态候选按用户明确要求恢复；随后用户于 2026-10-16 明确改为[动态目录方案](features/dynamic-model-defaults-2026-10-16.md)，当前所有配置候选均不再注入静态型号。实时目录、候选 Copilot 筛选和宽松连接探测继续保留不同语义。

2026-10-15 对 PR #558 的[全模型弹窗适配](features/antigravity-models-sheet-layout-2026-10-15.md)采用显式展示值注入：合并上游时不要恢复弹窗内部的隐式设置环境或 `.shared` 读取。原显示状态由账号卡片持有，Sheet 挂在稳定根节点，避免加载和空模型分支卸载宿主。上游 PR 核对时已关闭但未合并，具体 head 与本地定向范围见适配记录。

| 角色 | 仓库 | 在本项目中的作用 | 更新方式 |
|---|---|---|---|
| Quotio 原项目／主要代码上游 | [nguyenphutrong/quotio](https://github.com/nguyenphutrong/quotio) | 原生 macOS 应用主体，包含界面、代理管理、OAuth、配额和 CLI 配置 | 拉取到 `upstream`，通过 Git 三方合并整合应用代码 |
| 当前二开仓库 | [Geoege-xll/quotio](https://github.com/Geoege-xll/quotio) | 当前工作副本的 `origin`，用于保存和发布二开成果 | 在本仓库开发分支提交，经验证后推送到自己的仓库 |
| 运行时代理服务 | [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) | Quotio 下载、启动和管理的独立代理二进制 | 升级代理版本，并验证管理 API 协议；不将其整个源码合并进 Swift 工程 |
| 统计与界面参考 | [sylearn/AIUsage](https://github.com/sylearn/AIUsage) | 仪表盘部分布局、用量统计、调用分析和客户端统计规则 | 独立参考 checkout，对比已采用提交与新提交，按模块移植 |
| CLI 配置参考 | [farion1231/cc-switch](https://github.com/farion1231/cc-switch) | Claude 模型映射、默认模型、显示名，以及 Codex 配置分层读取思路 | 独立参考 checkout，核对协议与行为，适配为 Swift 实现 |

**Quotio 才是整仓 Git 合并的主要上游。AIUsage、cc-switch 和 CLIProxyAPI 不应作为无共同历史的整仓分支合并进来。** 当前没有把这些参考仓库作为 Git submodule 或 vendored 源码目录管理；它们的更新不会随 `git pull origin` 自动进入 Quotio。

证据入口：原项目地址见根目录 `README.md`、`README.zh.md`；运行时代理仓库常量见 `Quotio/Infrastructure/CPA/Runtime/CLIProxyManager.swift`；AIUsage 移植记录见[许可证与来源说明](licenses/AIUsage-attribution.md)。`origin` 地址来自当前本地 Git 配置；本文不依赖 GitHub 页面是否显示 Fork 标识。

## 2. 当前基线：哪些事实已经确定

| 项目 | 2026-09-05 核对结果 |
|---|---|
| 当前分支 | `master`，跟踪 `origin/master` |
| 已配置远端 | 只有 `origin = https://github.com/Geoege-xll/quotio.git`，尚未配置 `upstream` |
| 当前已提交 HEAD | `13fd478c5b69f361d078e3b3bfc7ec041dde850d` |
| HEAD 提交说明 | `chore: bump version to 0.31.0 [skip ci]` |
| HEAD 提交时间 | 2026-09-02 19:03:21 UTC |
| 二开状态 | 大量已修改文件和新增文件仍在工作区，尚未形成覆盖本轮成果的二开提交 |
| AIUsage 参考提交 | `bdb83bbe077879855c03e656cbc2fe5890bd27e9` |
| cc-switch 参考提交 | `db41d701879592b8eca938cbe5c5ac28dd732b9f` |
| CPA 兼容基线 | 最低 8.0.0；当前支持经验证的 8.x 管理契约，真实隔离核验版本为 8.0.28 |

这里的 Quotio HEAD 是**本地当前已提交基线**，不是“刚刚拉取并确认的最新上游”。本次文档编写没有执行 `git fetch`，也没有创建基线标签。当前 `HEAD` 上没有指向它的本地标签，不能只凭提交说明就假定本地存在 `v0.31.0` 标签。

开发期间的参考 checkout 在 `/tmp/quotio-aiusage-reference`、`/tmp/quotio-cc-switch-reference`。它们属于临时目录，可能被系统清理；可复现依据应是**仓库 URL + 完整提交 SHA**，不能依赖 `/tmp` 长期存在。

## 3. 本项目是怎样二开的

### 3.1 保留 Quotio 原生架构

本项目继续使用 Swift 6、SwiftUI、Observation 和现有 MVVM 分工，最低支持 macOS 15：

- `Quotio/App/` 负责应用生命周期、导航、菜单栏、首次使用与配置装配。
- `Quotio/BusinessModules/` 按业务聚合视图、状态、专用模型和服务；账号、仪表盘、统计、客户端配置及工作区分别维护。
- `Quotio/Shared/` 保存实际跨业务使用的公共 UI、账号协调、模型管理与统计规则；CPA 唯一队列消费者及账本位于 `Shared/Analytics/CPA/`。
- `Quotio/Infrastructure/` 接入 CPA v8、提供商、客户端配置文件、进程、网络、安全、系统和通用存储能力。
- `QuotioTests/` 按 `App / BusinessModules / Shared / Infrastructure` 映射测试，跨类离线夹具放在 `Support/`。
- `Quotio/Resources/Localizable.xcstrings` 统一维护 `en`、`fr`、`vi`、`zh-Hans`、`zh-Hant` 五种语言。

目录规范、主要入口、已归位的公共模型与独立视图、`QuotaViewModel` 扩展及原状态宿主见[源码目录与归属规范](SOURCE_LAYOUT.md)。新增统计能力放在对应业务或共享目录中，再通过 `QuotioApp`、`OperatingMode`、`QuotaViewModel` 等现有入口接入。原生工程由 `Quotio.xcodeproj` 管理，根目录不是 Swift Package；使用 Xcode 的 `QuotioPlus` scheme 构建，并只运行与改动相关的定向测试。

### 3.2 二开功能及冲突热点

下表用于上游合并时逐项核对，实际差异以当前 Git diff 和测试为准。

| 二开范围 | 主要文件／目录 | 合并后必须保留的行为 |
|---|---|---|
| Claude Code 模型映射与默认模型 | `Quotio/Shared/AgentClients/Models/AgentConfiguration.swift`、`Quotio/Shared/AgentClients/Models/CLIAgent.swift`、`Quotio/Infrastructure/AgentClients/AgentConfigurationService.swift`、`Quotio/BusinessModules/AgentConfiguration/ViewModels/AgentSetupViewModel.swift`、`Quotio/BusinessModules/AgentConfiguration/Views/ClaudeModelMappingView.swift`、`Quotio/BusinessModules/AgentConfiguration/Views/AgentDefaultModelPicker.swift`、`Quotio/BusinessModules/AgentConfiguration/Views/AgentConfigSheet.swift` | 保留角色到实际请求模型的映射、存量菜单与显示名兼容；默认启动模型独立配置；显示名不能覆盖实际模型 ID |
| Codex CLI 配置 | `Quotio/Infrastructure/AgentClients/AgentConfigurationService.swift`、`Quotio/Shared/AgentClients/Models/AgentConfiguration.swift`、`Quotio/Shared/AgentClients/Models/CLIAgent.swift`、`Quotio/BusinessModules/AgentConfiguration/ViewModels/AgentSetupViewModel.swift` | 顶层模型和 provider 的读取不能被 profiles／MCP 子表混淆；保留用户自有配置内容 |
| 备份管理 | `Quotio/Infrastructure/AgentClients/AgentConfigurationService.swift`、`Quotio/BusinessModules/AgentConfiguration/Views/AgentBackupSection.swift` | 备份不重名覆盖；删除目标经过验证，不能误删配置或越界路径 |
| Antigravity 配额 | `Quotio/Infrastructure/Providers/Antigravity/AntigravityQuotaFetcher.swift`、`Quotio/Infrastructure/Providers/Antigravity/AntigravityQuotaParser.swift`、`Quotio/Shared/Accounts/Models/AntigravityQuotaPresentation.swift`、`Quotio/App/MenuBar/Views/MenuQuotaLayouts.swift`、`Quotio/BusinessModules/Accounts/Views/AntigravityQuotaLayouts.swift`、`Quotio/BusinessModules/Accounts/Views/AccountQuotaContent.swift` | 剩余／已用方向正确；不同额度池不随意平均；窗口和菜单栏使用一致的额度、周期和重置时间 |
| 仪表盘与提供商布局 | `Quotio/BusinessModules/Dashboard/Views/DashboardScreen.swift`、`Quotio/BusinessModules/Accounts/Views/ProvidersScreen.swift`、`Quotio/BusinessModules/Dashboard/Views/ProxyRuntimeCard.swift`、`Quotio/BusinessModules/Accounts/Views/AccountProviderGroups.swift`、`Quotio/BusinessModules/Accounts/Views/AccountProviderFilter.swift`、`Quotio/BusinessModules/Dashboard/Views/AvailableModelsSection.swift` | 顶部 CPA 运行卡与路由中心；账号页复用统一筛选和账号分组；模型完整展示，展开入口在右下，无搜索 |
| 首次启动与共享模型目录 | `Quotio/Shared/ModelManagement/Services/DashboardModelCatalogLoader.swift`、`AgentModelCatalogService.swift`、`Quotio/Infrastructure/Networking/ModelCatalogClient.swift`、`Quotio/Shared/Accounts/ViewModels/QuotaViewModel.swift`、`Quotio/Shared/ModelManagement/Models/ModelCatalog.swift` | 同一次加载先取得当前客户端 API key，再请求本机模型目录；启动后自动加载，旧会话响应不能覆盖新会话；实时目录、候选筛选和连接测试各保留原语义 |
| CPA 仪表盘用量 | `Quotio/Shared/Analytics/CPA/`、`Quotio/BusinessModules/Analytics/CPAUsage/`、`Quotio/Infrastructure/CPA/API/ManagementAPIClient.swift`、`Quotio/Shared/Accounts/ViewModels/QuotaViewModel.swift` | 新队列唯一消费者，跟随应用／代理生命周期；保留历史累计数据、不请求旧累计接口，真实零与未知分开 |
| 本地客户端分析（用量与调用二合一） | `Quotio/BusinessModules/Analytics/ClientCalls/`、`Quotio/Shared/Analytics/Models/`、`Quotio/Shared/UI/Analytics/` | 综合／Claude Code／Codex／OpenCode／Pi；Token用量账本与工具/MCP/Skill调用合并为统一看板；各客户端本地数据不与 CPA 网关双计 |
| 共用外观与导航 | `Quotio/Shared/UI/Analytics/`、`Quotio/Shared/UI/Theme/QuotioTheme.swift`、`Quotio/App/Navigation/SidebarSquircleIcon.swift`、`Quotio/App/QuotioApp.swift`、`Quotio/Shared/AppSettings/OperatingMode.swift`、`Quotio/App/Navigation/OperatingMode+Navigation.swift` | 保留当前主题与导航；客户端统计在监控模式也可用；模式状态归原 manager，导航只读扩展不改偏好 |
| 工程与本地化 | `Quotio.xcodeproj/project.pbxproj`、`Quotio/Resources/Localizable.xcstrings` | 保留新增资源与实际构建设置；按文案键和语言合并，避免整文件覆盖 |

统计模块的详细计算与参考源码对照见[用量统计与调用分析](features/usage-statistics-and-call-analytics.md)。视图和统计规则并非对参考项目原文件的无差别覆盖：AIUsage 使用其自己的 Claude Gateway 归档，本项目使用 Claude Code 本地记录；参考项目的 Codex 代理／非代理轨道尚未在本项目实现。

2026-09-08 客户端统计已改为 SQL 日汇总展示、按变化文件与会话处理，不再让全历史账本和检查点常驻页面。新增「诊断与维护 → 维护入口 → 存储与数据」，区分缓存释放、数据库空间回收和按模块删除统计；合并时必须保留应用级维护屏障、CPA 已消费批次落盘以及多模块失败后缓存失效。详见 [统计内存优化与存储维护](features/analytics-memory-optimization-and-storage-maintenance-2026-09-08.md)。


第二轮第一批公共模型已按完整声明归位：客户端配置模型见 `Quotio/Shared/AgentClients/Models/`，Claude 菜单与显示规则见其 `Claude/` 子目录；账号模型见 `Quotio/Shared/Accounts/Models/`，额度百分比规则见 `Quotio/Shared/Accounts/Presentation/`。外观、刷新及菜单栏设置分别位于 `Quotio/Shared/AppSettings/`，格式化规则位于 `Quotio/Shared/Formatting/`。原 `Models.swift`、`MenuBarSettings.swift`、`AgentModels.swift` 已移除，不能再作为当前冲突定位入口；上游仍使用合集时，按类型与职责逐项对照，保留原有 Codable 字段、偏好键、单例与异步所有权。详见[公共模型及纯规则拆分](features/public-model-split-2026-10-15.md)。

第二轮第二批将独立视图按完整声明归位：`SettingsScreen.swift` 只保留设置导航状态，设置分区、独立控件与版本弹窗分别见 `Settings/Views/Sections`、`Components`、`Sheets`；关于页继续使用原 `ProxyVersionManagerSheet`。`QuotaScreen.swift` 保留旧导航兼容壳，额度内容展示入口为 `AccountQuotaContent.swift`，额度布局、徽标及模型详情在账号模块内分文件维护。`StatusBarMenuBuilder.swift` 继续负责原生菜单装配和缓存，控制器与回调对象位于 `App/MenuBar`，菜单视图位于其 `Views` 子目录。上游仍使用大文件时按类型名逐项比对；保留原视图的状态宿主、Task、单例、偏好键、布局和交互，不因文件移动复制状态或重新注册任务。详见[独立视图拆分记录](features/independent-view-split-2026-10-15.md)。

第二轮第三批仅将 `QuotaViewModel` 的模型、菜单投影、凭据传输和 OAuth 四组分文件维护。主类仍持有全部存储属性、初始化、任务句柄、刷新世代与生命周期；同目录的 `QuotaViewModel+Models.swift` 保留原嵌套模型全名，`+MenuBar.swift` 维护菜单投影，`+AuthFileTransfer.swift` 维护原批次来源检查，`+OAuth.swift` 维护授权入口和回调。原顶层授权状态位于 `Shared/Accounts/Models/OAuthState.swift`。上游大文件变更需同时比对主类和四个扩展；只允许既定跨文件访问白名单，不扩大 `private(set)`，不拆出第二份授权会话或账号状态。详见[QuotaViewModel 分文件维护记录](features/quota-viewmodel-split-2026-10-15.md)。

第二轮第四批新增 `Shared/Accounts/ViewModels/QuotaViewModel+IDEQuotas.swift` 与 `QuotaViewModel+AccountMutations.swift`，分别维护原 IDE 额度和账号变更方法。主类继续持有全部存储、Task、上下文校验、刷新槽位与统一收尾；不新增协调器或存储服务。比对上游时同步核对显式扫描同意、只刷新已导入账号、持久化键、禁用与删除清理范围、模式／管理客户端／运行会话检查，以及删除后不被旧响应恢复。只有 20 项必要跨文件访问调整，原可变私有属性、私有 setter 和上一批四个扩展保持原样。详见[IDE 额度与账号变更拆分记录](features/quota-viewmodel-ide-account-split-2026-10-15.md)。

第二轮第五批将 16 个原提供商取数方法完整迁入 `QuotaViewModel+LocalQuotaFetching.swift`、`QuotaViewModel+CPAQuotaRefresh.swift`、`QuotaViewModel+MonitorQuotaRefresh.swift`。主类继续唯一持有获取器、状态及任务，刷新协调和受保护的状态写入入口不迁移。比对上游时同时核对三个扩展：保留 CPA 接管失败不使用其他本机账号回退、精确凭据与唯一旧邮箱映射、Kiro 三阶段身份映射、Codex 凭据分组、Copilot 合并后别名归一、原并发及会话校验位置。仅开放 13 个只读获取器和 13 个必要方法，不扩大 `private(set)` 或可变私有存储；局部 Codex CLI 回退和本地测试读取辅助仍为私有。详见[提供商取数拆分记录](features/quota-viewmodel-provider-fetching-split-2026-10-15.md)。

第二轮第六批将 14 个原方法（含一个 Debug 目录读取包装）归位到 `QuotaViewModel+QuotaRefresh.swift`，维护本地／CPA 目录、手动操作、批量与单提供商／单账号刷新、账号发现、失败持久化和统一收尾。主类仍持有全部状态、任务句柄、上下文校验、槽位和私有节流，只新增两个同步方法读取到期状态及记录原开始时间。比对上游时保留槽位申请后的来源复核、原 `defer`、两条批量路径各自的时间写入顺序、原并发与失败回退、挂起后的客户端／账号／模式／运行会话检查，以及原发现／持久化／通知／菜单收尾顺序。仅四个既有方法开放为内部可见，不放宽可变私有存储或 `private(set)`；目录事务与失败持久化辅助继续私有。新增定向测试覆盖真实批量入口的槽位冲突和等待取消，原 104 个测试文件不变。详见[刷新协调拆分记录](features/quota-viewmodel-refresh-coordination-split-2026-10-15.md)。

第二轮第七批将七个原代理相关方法完整迁入 `QuotaViewModel+ProxyLifecycle.swift`，维护启动／切换、完整模式初始化、禁用同步、升级检查、唯一用量会话观察及获取器代理配置更新。主类继续持有全部原状态、启动协调器、客户端和任务句柄；停止事务、三种刷新循环、独立恢复、监控模式客户端切换及初始化注册不拆分或重排。比对上游时核对两次目录刷新与禁用同步、预热、升级 Task、隧道的原顺序，以及每次挂起后的取消／运行会话检查；观察继续弱引用同一实例并在 MainActor 重订阅。仅开放原只读 `proxyStartFlow` 及七个必要方法，私有客户端指针、可变私有存储和 `private(set)` 不变；禁用同步与升级辅助仍私有。详见[代理生命周期拆分记录](features/quota-viewmodel-proxy-lifecycle-split-2026-10-15.md)。

第二轮第八批将八个原预热方法完整迁入 `QuotaViewModel+Warmup.swift`，维护设置、时间计算、精确凭据与模型选择、逐模型执行。主类保留调度 Task、整轮防重、私有单账号防重入口、原八小时模型缓存及状态写回；原方法正文不改，取消、会话校验和失败保留规则不增减。跨文件仅开放两个原只读依赖及六个必要方法，不开放私有存储或 setter。为补充隔离回归，原设置依赖改为默认 `.shared` 的构造注入，`WarmupSettingsManager` 默认仍使用 `.standard`，全部偏好键、解码及回调保持原样；仅 Debug 方法用于放入指定时间的缓存样本，不新增存储。新增 12 项预热测试使用临时偏好和原离线 HTTP 夹具，原 105 个测试文件不改动。详见[预热拆分记录](features/quota-viewmodel-warmup-split-2026-10-15.md)。

第二轮第九批将九个只读展示计算归入 `QuotaViewModel+Presentation.swift`，五个 Antigravity 切换入口归入现有 `QuotaViewModel+AccountMutations.swift`。全部 253 个原成员的正文、属性及 Actor 边界保持一致，仅原 `refreshSettings` 从私有只读引用调整为内部只读引用。刷新集合仍通过主类原同步方法写入，`private(set)`、全部存储与 Task 所有权不变；涉及私有槽位、客户端、预热状态和懒加载写入的读取门面继续留在主类。仪表盘、API Key、通知方法未搬走或改写执行逻辑。收尾审计记录了既有 API Key 回写缺会话／读写世代保护、仪表盘手动刷新完成时间缺末尾会话复核、通知发送与恢复清理的提供商去重键不一致三项风险；这三项当时未混入结构迁移，随后专项修复见下段；不能把模型目录的请求令牌保护当作全部页面流程已隔离。详见[第九批实施与审计记录](features/quota-viewmodel-presentation-final-audit-2026-10-15.md)。

第九批收尾审计的三项风险已在后续[专项修复](features/quota-viewmodel-finalization-fixes-2026-10-15.md)中处理。API Key 页面读取与后台 `refreshData` 共用主类最新请求令牌，所有编辑在成功／失败提交前检查客户端、模式、代理会话和取消；客户端替换同步废弃旧令牌，旧 `defer` 只能释放自身互斥。通知用稳定提供商身份去重，原显示文案及偏好键不变，恢复时兼容清理旧显示名键。仪表盘用 `refreshData` 的明确结果和 `UsageStatisticsStore.refreshForDashboard(sessionID:)` 的同会话完成证据记时间；后者复用原消费者与等待屏障，不把失败、维护、取消、不支持接口或残留 `live` 视为本轮成功。主类及原管理器继续持有全部状态与任务，私有 setter 不开放；测试构造的依赖注入默认仍使用原共享实例和标准偏好。

第三轮第一批将原 `MonitorRuntime.swift` 中的 16 个类型按完整声明迁入 `Shared/Accounts/Monitor` 同名文件，旧合集已移除。账号模型、凭据协议及值、保险库、世代、元数据、快照、发现、协调器与辅助类型均保留原名称；`MonitorCredentialStore` 默认拒绝 CAS 的实现仍与协议同文件。比对上游仍使用合集时，按类型逐项映射，不重新创建共享实例或拆开原 actor 的字段与方法。保留保险库同步 CAS、世代锁临界段、快照连同错误的原子提交、协调器 `Flight` 与共享等待收尾，以及所有私有状态和 `issues private(set)`。唯一辅助调整为文件私有 `String.nilIfBlank` 等价归入 `MonitorIdentity.nilIfBlank(String?)`，账号与发现的六处调用相应替换；不向 String 全局开放接口。详见[监控运行类型拆分记录](features/monitor-runtime-type-split-2026-10-15.md)。

第三轮第二批将 `WorkspaceSessionService.swift` 的协议、`SessionIOUtils` 和 Claude／Codex／OpenCode／Pi／AGY 五个 Provider 归位到原 `BusinessModules/Workspace/Sessions/Services` 目录的同名文件。原文件只保留 `WorkspaceSessionService` actor；装配字典、`shared`、私有依赖、TaskGroup 汇总、排序、消息与删除分发及终端恢复保持原样。上游仍使用合集时按八个完整声明逐项比对，不拆开 Provider 私有解析方法，也不放宽权限或遗漏 `nonisolated`／`@concurrent`。保留数据库与文件来源优先级、关系补全及去重顺序、删除前重扫，以及统一删除引擎的约束复核、暂存、提交和失败回滚顺序；不把可重入 actor 门面当成全局删除锁。详见[工作区会话 Provider 拆分记录](features/workspace-session-provider-split-2026-10-15.md)。

第三轮第三批按实际业务复用纠正 CPA 公共契约归属：`CPAAccountWeight` 与原错误契约成组位于 `Infrastructure/CPA/Configuration/CPAAccountRoutingRules.swift`；设置和路由共用的 `CPARoutingStrategy` 整体位于 `Shared/UI/CPA/CPARoutingPolicy.swift`；共享查询返回的 `CPARoutingSnapshot` 位于 `Shared/Analytics/CPA/Models/CPAUsageRoutingReport.swift`；`CPASettingsNumberRow` 位于 `Shared/UI/Controls`。上游仍使用 Settings／Dashboard 合集时按职责对应，不把 `CPAAdvancedSettingsDraft`、保存基线、路由活动或动画一起下沉；不改原调用类型名、错误行为、查询或任务所有权。详见[CPA 公共业务归位记录](features/cpa-business-boundary-2026-10-15.md)。

第三轮第四批将 MenuBarAccountCatalog 归 `Shared/Accounts/Presentation`，IDE 扫描选项／结果／原 manager 归 `Shared/Accounts/Services/IDEScanSettings.swift`，原 CPAOAuthSessionCoordinator 归同 Services；传输协议与客户端适配保留在 `Infrastructure/CPA/API/CPAOAuthSessionClient.swift`。OAuthSheet 与其私有状态视图同文件归 `Shared/Accounts/Views`，账号页与仪表盘保留原调用。共享 OperatingMode／manager 成组位于 `Shared/AppSettings`，页面集合和可见性查询两个原成员在 `App/Navigation/OperatingMode+Navigation.swift`。比对上游时保留单例、私有 setter、模式 revision、账号歧义拒绝、显式扫描同意、OAuth 世代／期限／回调和弹窗任务，不把文件归位误当状态迁移。详见[账号共享能力归位记录](features/account-business-boundary-2026-10-15.md)。

第三轮第五批将模型读取业务归 `Shared/ModelManagement/Services/AgentModelCatalogService.swift`，共用请求传输归 `Infrastructure/Networking/ModelCatalogClient.swift`；旧 `AgentConfigurationService` 三个读取签名继续兼容，但页面、Pi 保存前查证和完整共享 Loader 不再为只读请求构造配置服务。合并上游时核对原端点、Bearer、十秒超时与代理工厂；保留实时空目录及候选 Copilot 筛选，连接测试允许 HTTP 200 非目录正文；当时页面静态兜底已由 2026-10-16 的动态目录方案移除。Loader 先取得本轮客户端 key，管理 key 不能回退为模型 key，取消屏障和原 ViewModel 世代提交不动。`PiSessionPaths` 的三个路径方法整体归 `Infrastructure/AgentClients`，timestamp 同名扩展留 Analytics 并显式保持 `nonisolated`；保留原环境变量、扫描目录、安装备份、写后重读和双文件回滚。详见[模型目录与 Pi 路径归位记录](features/model-catalog-business-boundary-2026-10-15.md)。

第三轮第六批将原 AnalyticsMaintenanceCoordinator 与 StorageDataDestination 成组归 `App/Composition/AnalyticsMaintenanceComposition.swift`。QuotioApp 原 State、环境注入和统计实例不变；App 的普通设置与日志兼容入口向 SettingsScreen 注入延迟目的地，设置页不引用 App 协调器或跨业务统计 VM。SettingsScreen 保持原非泛型类型及导航状态，其初始化现在明确接收目的地构造闭包；上游新增调用点须由 App 同样提供，不能在设置业务恢复原跨层装配或另造服务。原 service／Store／Screen 留 `Settings/Storage`；configure 仍在目的地 task 首次执行，不提早到 App 启动。保留 busy、private(set)、在途队列等待、清理事务、全模块失效、恢复与迁移墓碑。原维护生命周期测试内容不变，归 `QuotioTests/App/Composition`。详见[存储维护应用装配归位记录](features/storage-maintenance-composition-2026-10-15.md)。

### 3.3 合并时的关键约束

整理后审计确认的监控 Claude 授权取消风险已作[专项修复](features/monitor-claude-oauth-session-isolation-2026-10-15.md)：对照上游时保留 `MonitorOAuthCoordinator` 的同步会话失效、浏览器／token 返回校验及按所属会话收尾；保险库和元数据的授权保存重载在实际写入位置校验世代，不能只保留网络返回时的一次检查。原任务需按启动世代分别取消，迟到取消不能整段跳过旧设备任务，也不能取消新 Claude。ViewModel 以原 OAuthState.sessionID 与模式 revision 提交；原网络端点、请求正文、存储格式、CAS 及 shared 默认值不变。

- 后续重构按业务能力及实际耦合制定计划，先说明共同变更原因、依赖方向、状态与任务所有者、事务边界和维护收益，再列文件调整与必要验证。行数只作审计线索；保留内聚类型组，避免仅为缩短文件增加转发或跨文件跳转。此前完整类型归位记录用于映射历史变更，不构成继续按文件大小拆分的依据；规则见[代码架构标准](ARCHITECTURE_STANDARDS.md)。
- CPA 管理请求直接连接本机 `127.0.0.1`，模型请求使用客户端 key；不能把管理 key 回退为客户端 key。
- 代理启停保留 Quotio 自进程保护、运行会话标识和取消检查。
- 版本化代理存储保留 `current` 指向的活动版本。
- 写 CLI 配置时保留用户自有键、创建不冲突备份，验证不可信文件和链接目标。
- 账本只保存必要统计元数据，使用私有原子写入；不提交真实账号、Token、OAuth 文件或本地配置。
- CPA 模型请求量、客户端 Token 量、工具调用量、代理会话次数是不同口径，不能为追求数字一致而相加或相互替代。
- 调用分析 Schema 7 兼容读取 Schema 6。客户端账本与 CPA 账本也有各自版本，合并时先检查解码和迁移，不直接删历史文件解决兼容问题。

## 4. 第一次同步前：先把二开成果保存为提交

**当前工作区尚未提交，不能直接进入合并步骤。** 分支、标签或 `git bundle` 只能保存已提交的对象，不能代替保存未跟踪的新源文件。

先查看全部状态，包括新增文件：

```bash
# 从仓库根目录执行；这些命令不修改工作区。
git status --short
git diff --stat
git diff --name-status
git ls-files --others --exclude-standard
git diff --cached --stat
```

建议先建立长期二开分支 `fork/main`，然后按功能形成提交。新分支会保留工作区修改；如果该分支已经存在，不要重复创建。

```bash
# 仅首次创建二开分支时执行。
git switch -c fork/main

# 对共享的已跟踪文件按补丁选择；新增文件需逐路径显式暂存。
git add -p

# 每次提交前检查暂存区，再按实际功能填写提交说明。
git diff --cached --check
git diff --cached
```

新增路径应按上一节功能表分别 `git add <实际路径>`，再 `git commit`。不建议用 `git add .` 把不同任务、构建产物和本地配置一次性带入。当前还有用户删除的 `AGENTS.md`、`.codex/environments/environment.toml` 等工作区变化，要按实际维护意图处理，不能在合并时自动恢复，也不能假定这些删除都是二开功能所需。

将**全部需要保留的二开源码、新文件、文档和有意删除**保存后，确认 `git status --porcelain` 为空，再建立二开基线标签。标签使用 `fork-baseline-*`，避免误触项目 `v*` 发布流程；标签日期及提交信息应填实际保存时间。

## 5. Quotio 主要上游的标准同步流程

推荐使用 **fetch → 独立 worktree → 三方 merge → 验证 → 合入二开分支**。这能保留共同祖先和合并记录，后续上游更新仍能识别已经吸收的代码。对长期共享二开分支，不常规执行 rebase 重写历史。

### 5.1 配置并获取上游

```bash
# 首次配置。若已有 upstream，先检查地址，不重复添加或盲目覆盖。
git remote -v
git remote add upstream https://github.com/nguyenphutrong/quotio.git

# 获取上游提交但不修改当前源码；不自动导入所有上游发布标签。
git fetch --prune --no-tags upstream

# 查看上游默认分支；本次核对为 master，未来以远端为准。
git remote show upstream
```

保持 `origin` 指向自己的二开仓库，不用原项目覆盖 `origin`。普通 `git pull` 当前只会更新 `origin/master`，不会自动同步 `nguyenphutrong/quotio`。

### 5.2 建立可复核的合并分支

下列示例假设已创建并保存好 `fork/main`，且工作区干净。日期命名只用于可读性；同一天重复执行应加后缀避免重名。变量和 worktree 路径在同一终端会话中使用。

```bash
# 工作区必须先保存完毕。若有输出，先处理再继续。
git status --porcelain

# 在二开已提交基线上创建独立合并工作区。
sync_stamp=$(date +%Y%m%d-%H%M%S)
sync_branch="sync/quotio-${sync_stamp}"
sync_dir="../quotio-upstream-${sync_stamp}"
git worktree add -b "$sync_branch" "$sync_dir" fork/main
cd "$sync_dir"

# 记录本次输入：二开提交、上游目标提交和共同祖先。
fork_before=$(git rev-parse HEAD)
upstream_target=$(git rev-parse upstream/master)
sync_base=$(git merge-base HEAD "$upstream_target")
git log --oneline --left-right HEAD..."$upstream_target"
git diff --stat "$sync_base" "$upstream_target"
git diff --name-only "$sync_base" "$upstream_target"

# 固定到刚记录的目标SHA，不让后续fetch改变本次目标；先不自动提交。
git merge --no-ff --no-commit "$upstream_target"
```

如果 `git merge-base` 找不到共同祖先，应先检查远端 URL、分支和是否为浅克隆，不能通过 `--allow-unrelated-histories` 强行拼接。若上游已包含在当前分支中，Git 会报告已是最新，此时不需要制造空合并提交。

### 5.3 解决冲突：按行为三方比对

```bash
# 查看尚未解决的冲突及双方改动。
git status --short
git diff --name-only --diff-filter=U
git diff
```

在**本流程的 merge 操作中**，`ours` 是二开分支，`theirs` 是上游。不能对整仓执行“全部保留 ours／theirs”：前者会丢掉上游修复，后者会覆盖二开功能。以共同祖先、当前二开和上游三份文件分别判断每个改动目的，解决后显式 `git add <已解决路径>`。

优先审查 `QuotaViewModel`、`AgentConfigurationService`、`QuotioApp`、`ManagementAPIClient`、`CLIProxyManager`、`Quotio/Resources/Localizable.xcstrings`、`project.pbxproj`，因为它们既是上游活跃入口，也承载多项二开功能。

新增模块发生“双方都新增”冲突时，也需要整合实现和对应测试，不能只因为文件位于二开目录就保留整份本地文件。上游若已经修复相同问题，应优先复用上游实现，移除被替代的本地重复实现，但保留能保护二开需求的回归测试。

### 5.4 验证、提交与合入

先确认没有未解冲突，再运行第7节的构建、测试与人工验收。检查本次合并相对原二开基线的变化：

```bash
# 这些检查在合并worktree中执行。
git diff --name-only --diff-filter=U
git diff --check
git diff --cached --check
git diff --cached --stat "$fork_before"

# 确认验证成功后，完成合并提交；提交信息记录实际上游SHA。
git commit -m "chore(upstream): merge Quotio ${upstream_target}"
```

记录每次同步的上游完整 SHA、原二开 SHA、合并提交、重要冲突决策、验证命令和结果。可在 `docs/upstream-sync/` 按日期保存记录；不要只写“更新到最新版”。提交生成后可记录其 SHA 到后续维护记录或 PR，避免要求提交正文引用尚未生成的自身 SHA。

回到原工作区，确认它仍然干净，再合入已验证分支：

```bash
# 以下在原仓库工作区执行；sync_branch 取前面实际创建的分支名。
git switch fork/main
git merge --ff-only "$sync_branch"
```

如果 `--ff-only` 失败，说明开发期间 `fork/main` 又向前推进。返回同步 worktree，把新的 `fork/main` 合入、重新检查受影响范围，再尝试快进；不要强推覆盖并行开发成果。推送和发布按项目正常交付流程进行，本指南不自动推送。

合并尚未提交、需要放弃时，可在独立同步 worktree 中执行 `git merge --abort`，回到合并前提交。已发布的合并需要回退时采用经过审查的 revert 提交，不用 `reset --hard` 改写共享历史；回退合并会影响将来的再次合并，需要同时记录原因和恢复策略。

## 6. AIUsage、cc-switch、CPA 与依赖怎样更新

### 6.1 参考项目使用独立 checkout

建议放到仓库外的长期目录，例如 `~/Developer/quotio-references/`，不放入 Quotio 的同步源码组。以下仅用于第一次建立参考库：

```bash
mkdir -p "$HOME/Developer/quotio-references"
git clone https://github.com/sylearn/AIUsage.git "$HOME/Developer/quotio-references/AIUsage"
git clone https://github.com/farion1231/cc-switch.git "$HOME/Developer/quotio-references/cc-switch"
```

每次更新先获取新提交，再从**已采用的 SHA**比较变化，不直接将参考工作区切到最新版后整文件复制：

```bash
# AIUsage 示例：target SHA由本次选择的上游分支/版本确定。
cd "$HOME/Developer/quotio-references/AIUsage"
git fetch --prune origin
git remote show origin

# 替换下方 NEW_COMMIT 为核对后的完整SHA后执行。
git diff --stat bdb83bbe077879855c03e656cbc2fe5890bd27e9 NEW_COMMIT
git log --oneline bdb83bbe077879855c03e656cbc2fe5890bd27e9..NEW_COMMIT
```

AIUsage 优先核对 `StatsDataAdapter`、`ProxyStatsView*`、`DashboardView+Heatmap`、`CallAnalytics*` 及三个客户端 Provider。先确认新数据规则是否适用于本项目：它自己的 Gateway 归档、provider 排除和代理轨道不能原样套在 Quotio 的独立客户端账本上。移植后更新[源码对照与边界](features/usage-statistics-and-call-analytics.md)以及[来源说明](licenses/AIUsage-attribution.md)，记录具体采用的提交和模块。

cc-switch 从 `db41d701879592b8eca938cbe5c5ac28dd732b9f` 对比新提交，优先看 `src/components/providers/forms/ClaudeFormFields.tsx`、`forms/hooks/useModelState.ts` 以及 `src-tauri/src/` 的配置读写。它使用的前端／Rust实现需转换为现有 Swift 服务和模型，保留本项目私有写入、备份及用户配置保护。配置字段最终还要结合客户端官方文档和实际版本验证，不能把参考项目新增字段直接当作全部版本通用契约。

### 6.2 CPA 独立升级

当前 Quotio 通过 `CLIProxyManager` 从 `router-for-me/CLIProxyAPI` 发布页获取二进制，不在应用工程中编译 CPA 源码。更新时记录实际 CPA 版本，并验证：

2026-09-28 起，QuotioPlus 仅安装、激活和运行 CPA 8.x。官方仍同时发布 7.x，因此 Atom 发布源和版本列表必须先过滤主版本，再选择“最新”版本。既有 7.x 格式的 `config.yaml` 只作为迁移输入：先备份，使用 CPA 的 `/v8/management/config` 空 PATCH 完成官方迁移，验证 v8 配置和管理接口后保留首次迁移备份；失败时恢复原文件。新配置应直接使用 `server`、`management`、`access.api-keys`、`api-keys.<provider>`、`oauth`、`requests` 与 `observability` 结构。2026-10-14 起，全部现有 CPA 管理调用统一为 `/v8/management`，不再使用 `/v0/management` 或旧 `/usage` 网络回退。路径、原始 JSON 值、配置树、运维确认和副作用按官方 v8 契约处理，模型业务 `/v1` 协议保持独立。最低支持版为 8.0.0；后续大版本需验证契约后再纳入。详细规则与验证见 [CPA v8 API 适配与加固](features/cpa-v8-management-hardening-2026-10-14.md)。

1. 版本化存储和活动 `current` 链接可用，升级／回退不会删除活动版本。
2. 代理启动、停止、健康检查、授权和模型目录正常。
3. 管理 API 的 v8 路径、鉴权、原始配置值、字段和错误语义；尤其是用量队列的消费式读取，不再请求旧 `/usage`，历史账本继续保留。
4. 队列读取不能套用可能重复消费的普通自动重试；同一时段只能由现有单消费者负责。
5. 请求数／Token 的停止、重启、失败和持久化状态正确。

### 6.3 SwiftPM 依赖

当前锁定文件是 `Quotio.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`，已锁定 Sparkle 2.8.1、PostHog 3.64.1。上游更新依赖时连同实际版本约束、锁定文件和 API 变化一起检查，不能为了清除冲突直接删锁定文件并无条件升级全部依赖。

## 7. 每次同步后的验证

使用真实 Xcode 工程，不使用根目录 `swift build` 或 `swift test`：

```bash
# 构建。
xcodebuild -project Quotio.xcodeproj -scheme QuotioPlus -configuration Debug -destination 'platform=macOS' build

# 只运行直接相关的测试类；以下为 v8 契约示例，按改动选择 -only-testing，禁止全量测试。
xcodebuild -project Quotio.xcodeproj -scheme QuotioPlus -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO test -only-testing:QuotioPlusTests/CPA8ManagementAPIContractTests

# 构建并启动新应用；该脚本会停止当前正在运行的Quotio实例。
./scripts/build_and_run.sh --verify
```

重点关注的回归类包括 `ClaudeCodeConfigTests`、`CodexModelConfigTests`、`AgentBackupDeletionTests`、`AntigravityQuotaTests`、`DashboardModelCatalogLoaderTests`、`ModelCatalogTests`、`UsageStatisticsTests`、`UsageStatisticsStoreTests`、`ClientUsageTests`、`CodexClientUsageTests`、`OpenCodeClientUsageTests`、`CallAnalyticsMigrationTests`、`CallAnalyticsReplicaTests`。

2026-09-05 统计迁移完成时，记录过456项通过的串行回归；该次仅排除了两项已知语言环境基线问题：`AmpQuotaFetcherTests.testParserMapsSubscriptionOtherUsageAndRenewalSuffix`、`MonitorRuntimeTests.testCountMetricUnitsUseEnglishSingularAndPluralForms`。这是历史证据，**不代表未来同步可永久跳过它们，也不代表之后新增改动自动获得验证**。后续只运行与改动直接相关的定向测试，区分本次回归与已复现的环境问题，并记录实际结果；历史全量执行方式不再沿用。

当前用户负责界面人工验收。每次涉及 UI 的同步至少检查：启动 CPA 自动加载模型、模型展开入口、Claude 映射和默认项、Antigravity 窗口／菜单栏一致性、统计来源／日期筛选、模型明细、调用分析以及亮暗色和窄窗口。用户表示“会检查”只代表验收分工，不等于已经验收通过。

2026-09-28 UI 定版后，智能体管理、技能管理、用量统计与用量分析不再保留需要真实窗口渲染、固定尺寸或像素布局的纯 UI 自动测试；这些页面的统计计算、数据转换、服务逻辑与筛选语义测试继续保留。视觉样式按上段要求做人工验收。早期功能记录中的布局测试名称和截图路径是当时的历史验证记录，不代表当前测试目标仍包含这些用例。

## 8. 发布二开版本前必须处理的上游关联

2026-09-08 已将自有更新与上游维护分离：`Config/Updates.xcconfig` 配置自有仓库 `Geoege-xll/quotio`；Bundle、Sparkle、Atom 预检查和打包下载地址共用该配置。原项目 `nguyenphutrong/quotio` 的发行检查位于“诊断与维护 → 维护入口 → 检查上游更新”，只提供源码同步参考。

Bundle ID 已改为 `com.app.george.quotioplus`。首次启动按原迁移机制补齐旧 `app.bytrong.quotio` 的设置和凭据来源，保留新身份下已有设置，排除旧 Sparkle 更新状态。统计、代理和其他 Application Support 数据目录保持连续。

启用自动安装更新前，需要配置本项目的 `SPARKLE_PUBLIC_ED_KEY` 和配套 `SPARKLE_PRIVATE_KEY` 并发布 appcast。两者均未配置时允许发行手动更新版本，通过自有发布页下载安装，不初始化自动安装器；只配置一项会明确失败。打包脚本会用包内公钥验证更新归档签名，拒绝不配对的配置。Developer ID 签名和 Apple 公证也按凭据是否完整区分发行模式，并在发布页注明实际状态。详见 [发行流程](../RELEASE.md) 和 [自有更新与身份调整](features/own-updates-and-app-identity-2026-09-08.md)。

首发已统一以下关联：

- `.github/workflows/release.yml` 仅在显式配置本仓库所有者的 `HOMEBREW_TAP_REPOSITORY` 后才通知自有 tap；不会向上游发送发行通知。
- 根 README 的下载、克隆和反馈链接均指向 `Geoege-xll/quotio`，明确二开来源并感谢原作者；上游 Homebrew tap 仅作为原版安装渠道说明。
- `scripts/build_and_run.sh` 默认身份已统一为 `com.app.george.quotioplus`，启动和日志读取会优先使用构建产物中的实际 Bundle ID；开发构建覆盖身份时也可正确定位应用。
- 当前发布工作流由 `v*` 标签和手动操作触发，日常同步基线使用其它标签前缀。

首发版本号、发行说明和源码在同一提交中保存。工作流校验标签所指提交与版本配置，构建过程不追加版本提交；后续同步仍采用正常合并及快进推送，避免改写已发布历史。

## 9. 许可证与长期记录

根目录 Quotio 许可证为 MIT，保留原作者声明。AIUsage 改编模块保留 Apache-2.0 来源头、修改说明和随应用打包的许可证：`Quotio/Resources/ThirdPartyLicenses/AIUsage-LICENSE.txt`。cc-switch 参考仓库当前许可证为 MIT；后续直接移植代码时，应同时记录具体文件、提交和相应版权声明。

每轮维护至少保存：

- 二开分支、同步前 SHA、上游目标 SHA、合并或移植提交。
- 采用了哪些上游模块，哪些差异继续保留，以及原因。
- 管理 API、CLI 配置字段或本地账本版本是否变化。
- 实际测试／构建命令、结果、环境和人工验收结论。
- 参考项目来源与许可证变化，二开发布地址是否仍正确。

维护文档入口为本文；功能计算规则归入 `docs/features/`，上游来源归入 `docs/licenses/`，实际同步记录建议归入 `docs/upstream-sync/`。不要把“当前临时目录还在”或“上次聊天提到过”作为后续合并的唯一依据。

2026-10-15 代码清理后，测试按有效断言保留：纯截图导出、PNG 大小及空泛宽度验收已删除；原生菜单跟踪、滚动位置、图表联动、光流定点像素，以及显示界面不改配置的回归继续保留。这些验证实际行为，不作为主题样式的自动验收基线。已有配置迁移、历史账本解码和旧导航归一仍是生产兼容职责，不按“老代码”删除。
