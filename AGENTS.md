# Instructions for AI Agents (Codex, Claude, etc.)

## 1. Testing Rules (CRITICAL)
- **DO NOT run all tests**: The test suite has 98+ files. Running the full test suite takes minutes and is strictly prohibited.
- **Always run targeted tests**: Only execute tests directly related to modified files using `-only-testing:QuotioPlusTests/<TestClass>`.
- **Scheme Name**: Scheme is `QuotioPlus`.
- **Command template**:
  ```bash
  xcodebuild test -scheme QuotioPlus -only-testing:QuotioPlusTests/<TestClassName>
  ```

## 2. Git Workflow
- Always operate directly on `master`.
- Do not create worktrees or separate branches unless explicitly directed by the user.


## 3. 源码目录与维护入口
- 架构与代码结构标准体系见 [docs/ARCHITECTURE_STANDARDS.md](docs/ARCHITECTURE_STANDARDS.md)；目录规范与归属见 [docs/SOURCE_LAYOUT.md](docs/SOURCE_LAYOUT.md)，项目入口见 [docs/PROJECT.md](docs/PROJECT.md)。
- `Quotio/App` 负责装配和导航；`BusinessModules` 聚合业务；`Shared` 放实际复用的公共 UI 与业务能力；`Infrastructure` 接入外部系统；资源在 `Resources`。
- 遵循单向依赖与标准业务模块骨架（`Views / ViewModels / Models / Services`），页面专用组件留在业务模块，禁止业务模块横向强耦合。新增文件不恢复旧顶层集中目录，也不新增无边界的公共工具目录。
- 后续重构先按业务能力、共同变更原因、依赖关系及状态／任务所有权判断边界；代码行数只作为审计线索，不作为拆分目标、实施顺序或验收指标。职责内聚的大文件可以保留，强关联的小类型也可以同文件维护；此前按完整类型迁移的批次不代表后续必须一类型一文件。
- 每批计划先说明业务归属、当前耦合问题、拆分收益、保留的所有权与事务边界，再列文件调整和必要验证。优先解决职责混杂、重复规则和跨业务强耦合；公共能力仅按实际复用提取。若调整仅减少行数、增加转发或跨文件跳转而无维护收益，应保留原结构。
- 测试目录镜像主要职责，跨类夹具放在 `QuotioTests/Support`；目录移动不改测试类名称，继续仅用 `-only-testing:QuotioPlusTests/<TestClass>` 定向验证。
- 第一轮已完成文件归属与固定路径调整；第二轮第一批已完成公共模型和纯规则按完整声明拆分，旧合集不再作为维护入口。第二批已拆出设置、额度及菜单栏的独立视图，三个原入口保留；当前类型与文件对应见目录规范。
- `SettingsScreen` 持有原设置导航状态，`QuotaScreen` 保留旧导航兼容壳，`StatusBarMenuBuilder` 持有原菜单装配与缓存；独立视图内的状态和任务仍归原类型。不得为继续拆文件而复制状态、扩大任务数量或绕过原有单例。
- 第二轮第三批已将 `QuotaViewModel` 的模型、菜单投影、凭据传输和 OAuth 分文件维护，入口为 `Shared/Accounts/ViewModels/QuotaViewModel+*.swift` 及 `Models/OAuthState.swift`。主类仍持有全部原存储属性、Task 和生命周期；扩展继续使用同一实例，不表示已完成状态所有权或编译依赖隔离。
- 第二轮第四批已将 IDE 额度和账号变更归位到 `QuotaViewModel+IDEQuotas.swift`、`QuotaViewModel+AccountMutations.swift`。主类继续持有全部存储、上下文校验、刷新槽位和统一收尾；扩展复用原获取器与协调器，保留显式扫描同意、会话校验、删除清理及删除后不复活边界。
- 第二轮第五批已将本地、CPA 和监控模式的提供商取数归位到 `QuotaViewModel+LocalQuotaFetching.swift`、`QuotaViewModel+CPAQuotaRefresh.swift`、`QuotaViewModel+MonitorQuotaRefresh.swift`。原方法完整迁移；获取器仍由主类创建和持有。保留 CPA 接管失败不使用本机其他账号回退、精确凭据及唯一旧邮箱映射、原并发与连续提交段、监控旧值合并及所有会话校验；刷新协调、槽位、错误恢复判定和任务生命周期仍在主类。
- 第二轮第六批将目录读取、手动刷新、批量及单提供商／单账号刷新、账号发现和统一收尾归位到 `QuotaViewModel+QuotaRefresh.swift`。主类继续持有全部状态、私有节流时间、任务句柄、上下文校验和槽位写入；扩展通过主类两个同步方法判断到期和记录开始时间，不扩大私有 setter。保留两条批量路径原时间写入顺序、会话校验、原并发、失败处理及收尾顺序；目录事务和失败持久化辅助仍私有，Debug 钩子存储仍在主类。
- 第二轮第七批将启动／切换、完整模式初始化、禁用同步、升级检查、用量会话观察和获取器代理配置更新归位到 `QuotaViewModel+ProxyLifecycle.swift`。主类继续唯一持有原客户端、启动协调器及全部 Task；停止事务、三种自动刷新循环、独立恢复任务、模式选择和初始化注册保持原样。保留原启动顺序、取消传播、会话校验及 Observation 重订阅，不新增状态、任务或第二个用量消费者；扩展仅复用原只读协调器和必要方法入口。
- 第二轮第八批将预热设置操作、时间计算、精确凭据与模型选择、逐模型执行归位到 `QuotaViewModel+Warmup.swift`。调度 Task、整轮与单账号防重、八小时缓存及状态字典仍由主类原方法维护；不改变原取消、会话或失败保留规则。既有预热设置依赖支持默认 `.shared` 的构造注入，设置 manager 默认仍读 `.standard`，所有旧键、编码与回调不变；仅 Debug 的缓存样本方法用于隔离回归，不增加测试存储。新增预热测试使用临时偏好与离线 HTTP 夹具，不连接真实账号。
- 第二轮第九批将九个只读展示计算归位到 `QuotaViewModel+Presentation.swift`，五个 Antigravity 切换入口归入现有 `QuotaViewModel+AccountMutations.swift`。只开放原 `refreshSettings` 的只读引用；槽位、私有状态及懒加载读取入口继续留在主类。仪表盘、API Key 和通知仍由主类提交状态；收尾审计发现的既有会话回写及通知去重问题见 [第九批实施与审计记录](docs/features/quota-viewmodel-presentation-final-audit-2026-10-15.md)，不可因本批迁移或定向测试通过而宣称已修复。
- 第九批后的[收尾专项修复](docs/features/quota-viewmodel-finalization-fixes-2026-10-15.md)已处理上述三项问题：API Key 页面与后台读取统一经过主类请求令牌及来源校验，编辑期间不读，旧编辑不能释放新互斥；通知文案与去重身份分开并兼容清理旧键；仪表盘必须取得同一代理会话的目录与用量完成结果。用量继续复用唯一消费者及原等待屏障，不新增消费任务；所有受保护状态写入留在原宿主，后续新增密钥读取不得绕过统一提交入口。
- 第三轮第一批已将原 `MonitorRuntime.swift` 的 16 个现有类型按完整声明归位到 `Shared/Accounts/Monitor` 同名文件，原合集不再作为维护入口。协议默认实现仍与 `MonitorCredentialStore` 同文件；保险库、世代、元数据、快照、发现及协调器保留全部原私有存储、嵌套类型、共享实例、Task 和隔离标注。CAS、快照提交及共享等待正文不变；原文件私有空白辅助等价归入 `MonitorIdentity.nilIfBlank`，不新增全局 String 扩展。详见[监控运行类型拆分记录](docs/features/monitor-runtime-type-split-2026-10-15.md)。
- 第三轮第二批将 `WorkspaceSessionService.swift` 的协议、`SessionIOUtils` 和五个客户端 Provider 按完整类型归位到原 `BusinessModules/Workspace/Sessions/Services` 目录的同名文件。原 actor 门面保留装配、共享实例、私有依赖、并发汇总和分发；八个声明正文不变，不放宽任何访问权限。保留协议和具体实现的 `nonisolated`／`@concurrent`、Provider 私有解析方法、来源扫描与关系合并顺序，以及删除前重扫、约束校验和统一引擎事务；门面可重入，不能将其视为全局删除锁。详见[工作区会话 Provider 拆分记录](docs/features/workspace-session-provider-split-2026-10-15.md)。
- 第三轮第三批按实际使用方纠正 CPA 公共能力归属：权重和兼容错误成组位于 `Infrastructure/CPA/Configuration/CPAAccountRoutingRules.swift`，策略选择／展示位于 `Shared/UI/CPA/CPARoutingPolicy.swift`，共享查询快照位于 `Shared/Analytics/CPA/Models/CPAUsageRoutingReport.swift`，复用数值输入位于 `Shared/UI/Controls/CPASettingsNumberRow.swift`。原设置草稿仍在 `CPARequestSettings.swift`；设置基线、保存锁、查询、路由活动与光流代码不变。不得将页面草稿下沉或在公共控件中增加解析／保存状态；迁移不表示已隔离编译模块。详见[CPA 公共业务归位记录](docs/features/cpa-business-boundary-2026-10-15.md)。
- 第三轮第四批将原菜单账号目录归 `Shared/Accounts/Presentation/MenuBarAccountCatalog.swift`，IDE 扫描契约与原 manager 成组归 `Shared/Accounts/Services/IDEScanSettings.swift`，原 CPA 授权协调器归同目录 `CPAOAuthSessionCoordinator.swift`，实际共享的 OAuth 弹窗及私有状态视图归 `Shared/Accounts/Views/OAuthSheet.swift`。传输协议与客户端适配留 `Infrastructure/CPA/API/CPAOAuthSessionClient.swift`。共享模式与原 manager 成组位于 `Shared/AppSettings/OperatingMode.swift`，两个原只读导航成员位于 `App/Navigation/OperatingMode+Navigation.swift`。不放宽权限，不改账号映射、显式扫描同意、授权隔离和任何状态／Task 所有权；不将新导航引用加回共享模式。详见[账号共享能力归位记录](docs/features/account-business-boundary-2026-10-15.md)。
- 第三轮第五批将模型读取业务归 `Shared/ModelManagement/Services/AgentModelCatalogService.swift`，共用原 `/models` 请求的无状态传输归 `Infrastructure/Networking/ModelCatalogClient.swift`；原配置服务的三个读取签名保留兼容，实际页面、Pi 保存前查证与共享 Loader 直接使用读取业务。完整 `DashboardModelCatalogLoader` 及原测试归共享模型目录，保留凭据先行、取消屏障及原 ViewModel 世代提交。实时目录不补模型，候选保留 Copilot 筛选和原页面兜底，连接测试仍允许 HTTP 200 非目录正文；不得把三种语义合并为严格目录解析。`PiSessionPaths` 三个原路径方法归 `Infrastructure/AgentClients`，timestamp 同名扩展留 Analytics 并显式保留 `nonisolated`；不扩大扫描或改变 Pi 安装、备份与双文件回滚。详见[模型目录与 Pi 路径归位记录](docs/features/model-catalog-business-boundary-2026-10-15.md)。
- 第三轮第六批将原 `AnalyticsMaintenanceCoordinator` 与 `StorageDataDestination` 完整成组归 `App/Composition/AnalyticsMaintenanceComposition.swift`，原跨业务生命周期测试归 `QuotioTests/App/Composition`。`QuotioApp` 仍持有同一协调器并注入原环境；App 在两个设置入口提供延迟目的地，Settings 不再引用 App 协调器或跨业务统计 VM。服务仍在目的地原 `.task` 首次幂等配置，原 `StorageMaintenanceService`／`Store`／`StorageDataScreen` 留设置业务。保留私有 setter、busy 互斥、暂停与在途等待、同库原子删除、全部缓存失效和恢复顺序，不把服务配置提前到 App 启动或设置根页。详见[存储维护应用装配归位记录](docs/features/storage-maintenance-composition-2026-10-15.md)。
- 整理后专项修复已补齐监控 Claude 手动授权隔离：原 `MonitorOAuthCoordinator` 持有授权世代，VM 在取消／重试首次挂起前同步失效；网络返回、保险库与元数据实际写入分别复核同一世代，旧 defer 只清本轮 pending。原 activeTask 增所属世代校验，迟到取消按对象分别清理，不能漏停旧设备授权或清新 Claude；VM 原 OAuthState 以同一 sessionID 和模式世代提交。默认仍用原 shared 网络／保险库／浏览器，只读注入用于离线回归，不新增 Task 宿主或放宽 setter。详见[监控 Claude 授权隔离修复](docs/features/monitor-claude-oauth-session-isolation-2026-10-15.md)。
- 状态容器、Task、单例和 manager 所有权仍保持原样；后续改动保留类型名称、配置键、运行时数据路径及历史兼容逻辑。保留原 `private(set)`、可变私有存储及凭据传输会话隔离，跨文件访问只开放实际必需项。编写、优化代码继续加入详细中文注释。
