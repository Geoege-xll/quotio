//
//  QuotaViewModel.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import Foundation
import Observation

/// 账号页、仪表盘、客户端配置与菜单栏共用的现有状态协调器，因此完整归入 Shared/Accounts。
/// 应用继续持有同一实例；展示、模型、菜单、凭据、授权、IDE、账号变更、取数、刷新、启动及预热执行分文件维护。
/// 目录状态及原任务句柄继续由本类独占。读取、启停和账号变更共用同一会话校验，
/// 避免重复采集或跨页面使用不同的目录。
@MainActor
@Observable
final class QuotaViewModel {
    let proxyManager: CLIProxyManager
    /// 仅观察管理客户端指针的启停／替换，不订阅 actor 内部网络状态。
    /// 路由页依赖此身份重读配置；忽略指针会使空队列启停后保留旧策略与重试值。
    private var _apiClient: ManagementAPIClient? {
        didSet {
            guard oldValue !== _apiClient else { return }
            // 客户端替换同步废弃旧读写所有权；旧请求随后返回时既不能提交，也不能释放新请求的互斥。
            // 不创建或取消额外 Task，实际网络失效仍由原生命周期负责。
            apiKeyRequestID = UUID()
            cpaDirectory.confirmedSession = nil
            isMutatingAPIKeys = false
            // 同步撤销模型 VM 已排入配置 actor 的旧许可。不能只在 await 返回后检查 client，
            // 否则 stopProxy／模式切换可能先结束会话，旧目录随后仍在磁盘生效。
            invalidateAgentModelSource()
        }
    }
    
    var apiClient: ManagementAPIClient? { _apiClient }
    /// 取数扩展只读取主类原有的 AntigravityQuotaFetcher 实例；保持 let、ObservationIgnored、创建位置和实例数量。
    @ObservationIgnored let antigravityFetcher = AntigravityQuotaFetcher()
    /// 取数扩展只读取主类原有的 OpenAIQuotaFetcher 实例；保持 let、ObservationIgnored、创建位置和实例数量。
    @ObservationIgnored let openAIFetcher = OpenAIQuotaFetcher()
    /// 取数扩展只读取主类原有的 CopilotQuotaFetcher 实例；保持 let、ObservationIgnored、创建位置和实例数量。
    @ObservationIgnored let copilotFetcher = CopilotQuotaFetcher()
    /// 取数扩展只读取主类原有的 GLMQuotaFetcher 实例；保持 let、ObservationIgnored、创建位置和实例数量。
    @ObservationIgnored let glmFetcher = GLMQuotaFetcher()
    /// 取数扩展只读取主类原有的 DeepSeekQuotaFetcher 实例；保持 let、ObservationIgnored、创建位置和实例数量。
    @ObservationIgnored let deepseekFetcher = DeepSeekQuotaFetcher()
    /// 取数扩展只读取主类原有的 MoonshotQuotaFetcher 实例；保持 let、ObservationIgnored、创建位置和实例数量。
    @ObservationIgnored let moonshotFetcher = MoonshotQuotaFetcher()
    /// 取数扩展只读取主类原有的 WarpQuotaFetcher 实例；保持 let、ObservationIgnored、创建位置和实例数量。
    @ObservationIgnored let warpFetcher = WarpQuotaFetcher()
    /// 取数扩展只读取主类原有的 ClinePassQuotaFetcher 实例；保持 let、ObservationIgnored、创建位置和实例数量。
    @ObservationIgnored let clinePassFetcher = ClinePassQuotaFetcher()
    /// 取数扩展只读取主类原有的 FactoryDroidQuotaFetcher 实例；保持 let、ObservationIgnored、创建位置和实例数量。
    @ObservationIgnored let factoryDroidFetcher = FactoryDroidQuotaFetcher()
    /// 取数扩展只读取主类原有的 DevinQuotaFetcher 实例；保持 let、ObservationIgnored、创建位置和实例数量。
    @ObservationIgnored let devinFetcher = DevinQuotaFetcher()
    /// 取数扩展只读取主类原有的 GrokQuotaFetcher 实例；保持 let、ObservationIgnored、创建位置和实例数量。
    @ObservationIgnored let grokFetcher = GrokQuotaFetcher()
    /// 取数扩展只读取主类原有的 OpenRouterQuotaFetcher 实例；保持 let、ObservationIgnored、创建位置和实例数量。
    @ObservationIgnored let openRouterFetcher = OpenRouterQuotaFetcher()
    /// 取数扩展只读取主类原有的 AmpQuotaFetcher 实例；保持 let、ObservationIgnored、创建位置和实例数量。
    @ObservationIgnored let ampFetcher = AmpQuotaFetcher()
    /// 同类型的传输扩展只读取原注入实例；保持 let 与 ObservationIgnored，不复制服务或改变所有权。
    @ObservationIgnored let directAuthService: DirectAuthFileService
    /// 账号变更扩展复用原注入的协调器；只开放 let 引用，世代、持久化和在途刷新仍由原实例管理。
    @ObservationIgnored let monitorCoordinator: MonitorRefreshCoordinator
    /// 默认仍持有原共享通知管理器；隔离回归可注入同类型实例，不公开通知状态或私有 setter。
    @ObservationIgnored private let notificationManager: NotificationManager
    /// 菜单、传输和授权扩展读取同一个模式世代；只开放只读引用，模式状态仍由原 manager 管理。
    @ObservationIgnored let modeManager: OperatingModeManager
    @ObservationIgnored private let menuSettings: MenuBarSettingsManager
    /// 每个异步刷新在第一次挂起前取得上下文，结果提交前检查账号与运行模式两个世代。
    /// 账号变动使整批旧结果作废，下一次刷新仍可正常读取用户重新添加的同名账号。
    /// 授权、IDE 额度及账号变更扩展复用此原上下文；世代读取和提交校验继续集中于主类。
    nonisolated struct RefreshContext: Sendable {
        let revision: UInt64
        let modeRevision: UInt64
        let sessionID: UUID
        let proxyRunning: Bool
        var mutationAccountID: String? = nil
    }
    /// IDE 与账号变更扩展在原调用时点取得统一上下文，继续由本类读取同一组账号、模式和代理会话世代。
    func refreshContext() -> RefreshContext {
        RefreshContext(revision: monitorCoordinator.revision.current, modeRevision: modeManager.revision,
                       sessionID: proxyManager.runtimeSessionID, proxyRunning: proxyManager.proxyStatus.running)
    }
    /// 分文件方法在挂起后复用原提交检查；不缓存判断结果，也不为扩展另建一套会话有效性规则。
    func canCommit(_ context: RefreshContext) -> Bool {
        context.revision == monitorCoordinator.revision.current
            && canUseRefreshSource(context)
    }
    /// 等待刷新槽位时账号可能正常编辑，但读取来源不能跨代理就绪边界。
    /// CPA 在实际就绪前已经生成会话 ID，因此同一 ID 仍须核对运行状态，拒绝迟到的停机直读。
    func canUseRefreshSource(_ context: RefreshContext) -> Bool {
        !Task.isCancelled && context.modeRevision == modeManager.revision
            && context.sessionID == proxyManager.runtimeSessionID
            && context.proxyRunning == proxyManager.proxyStatus.running
    }
    /// 授权扩展与账号编辑共用此原入口；完整保留世代推进顺序，不新增第二套变更协调器。
    @discardableResult func beginAccountMutation(accountID: String? = nil) -> RefreshContext {
        monitorCoordinator.revision.advance(accountID: accountID)
        var context = refreshContext()
        context.mutationAccountID = accountID
        return context
    }
    /// 账号变更扩展继续按原账号世代判定完成结果，保留不同账号并行操作和同账号最新操作的边界。
    func canApplyMutation(_ context: RefreshContext) -> Bool {
        guard let accountID = context.mutationAccountID else { return canCommit(context) }
        return monitorCoordinator.revision.isCurrent(context.revision, accountID: accountID)
    }
    /// 展示扩展复用原只读刷新设置；实时读取频率，实例、ObservationIgnored 和主类所有权不变。
    @ObservationIgnored let refreshSettings: RefreshSettingsManager
    /// 预热扩展复用原只读设置依赖；正常初始化仍默认 shared，测试可注入临时偏好，存储与任务所有权不变。
    @ObservationIgnored let warmupSettings: WarmupSettingsManager
    /// 逐模型执行复用主类唯一创建的原服务 actor；只开放 let 引用，不新增服务或请求任务。
    @ObservationIgnored let warmupService = WarmupService()
    private var warmupNextRun: [WarmupAccountKey: Date] = [:]
    private var warmupStatuses: [WarmupAccountKey: WarmupStatus] = [:]
    @ObservationIgnored private var warmupModelCache: [WarmupAccountKey: (models: [WarmupModelInfo], fetchedAt: Date)] = [:]
    @ObservationIgnored private let warmupModelCacheTTL: TimeInterval = 28800
    @ObservationIgnored private var lastProxyURL: String?
    
    /// Tunnel manager for Cloudflare Tunnel integration
    let tunnelManager = TunnelManager.shared
    
    // Quota-Only Mode Fetchers (CLI-based)
    /// 取数扩展只读取主类原有的 ClaudeCodeQuotaFetcher 实例；保持 let、ObservationIgnored、创建位置和实例数量。
    @ObservationIgnored let claudeCodeFetcher = ClaudeCodeQuotaFetcher()
    /// IDE 扩展只读取原 Cursor 获取器引用，实例仍在本类创建，不新增读取器或任务。
    @ObservationIgnored let cursorFetcher = CursorQuotaFetcher()
    /// 取数扩展只读取主类原有的 CodexCLIQuotaFetcher 实例；保持 let、ObservationIgnored、创建位置和实例数量。
    @ObservationIgnored let codexCLIFetcher = CodexCLIQuotaFetcher()
    /// IDE 扩展复用原 Trae 获取器；保持 let 与 ObservationIgnored，沿用原数据库读取路径。
    @ObservationIgnored let traeFetcher = TraeQuotaFetcher()
    /// CLI 授权扩展复用原获取器刷新 Kiro token；仅开放 let 引用，创建位置与实例数量保持不变。
    @ObservationIgnored let kiroFetcher = KiroQuotaFetcher()

    @ObservationIgnored private var lastKnownAccountStatuses: [String: String] = [:]
    
    /// 启动时先展示整体运行状态；账号额度仍可从侧边栏直接进入。
    /// 将旧额度导航归一为唯一账号入口，保证侧栏选择状态与深链接内容一致。
    var currentPage: NavigationPage = .dashboard {
        didSet {
            if currentPage == .quota { currentPage = .providers }
        }
    }
    /// 同一份目录管理展示副本、当前会话许可和请求顺序。世代及恢复标记仅供同步事务判断；
    /// 界面继续观察文件、许可和错误，后台开始读取时无需重新渲染页面。
    @MainActor @Observable
    fileprivate final class CPAAccountDirectoryState {
        var files: [AuthFile] = []
        var confirmedSession: (sessionID: UUID, modeRevision: UInt64)?
        var failure: String?
        @ObservationIgnored var readGeneration: UInt64 = 0
        @ObservationIgnored var publishedGeneration: UInt64 = 0
        @ObservationIgnored var isRestoringSnapshot = false
        let snapshotDefaults: UserDefaults?

        init(snapshotDefaults: UserDefaults?) {
            self.snapshotDefaults = snapshotDefaults
        }
    }

    private let cpaDirectory: CPAAccountDirectoryState

    /// 停机、启动失败或目录请求失败时，现有页面继续通过此入口读取上一份确认的快照。
    var authFiles: [AuthFile] {
        get { cpaDirectory.files }
        set { cpaDirectory.files = newValue }
    }

    var lastCPAAccountDirectoryError: String? { cpaDirectory.failure }

    /// 额度入口可在就绪后尝试重新读取目录。账号管理操作必须等待本会话的成功目录。
    var canRefreshAccountQuotas: Bool { proxyManager.proxyStatus.running && apiClient != nil }
    var hasCurrentCPAAccountDirectory: Bool {
        canRefreshAccountQuotas && cpaDirectory.confirmedSession?.sessionID == proxyManager.runtimeSessionID
            && cpaDirectory.confirmedSession?.modeRevision == modeManager.revision
    }

    /// 同一会话可以同时发起手动刷新和后台读取。只允许较新的目录完成结果发布；
    /// 删除推进的账号世代阻止删除前已经在途的结果恢复旧账号。
    func readCPAAuthDirectory(
        read: () async throws -> [AuthFile],
        isCurrentSource: () -> Bool
    ) async throws -> [AuthFile]? {
        let context = refreshContext()
        cpaDirectory.readGeneration &+= 1
        let generation = cpaDirectory.readGeneration
        do {
            let files = try await read()
            guard canCommit(context), isCurrentSource(), generation > cpaDirectory.publishedGeneration else { return nil }
            cpaDirectory.publishedGeneration = generation
            if let previous = lastCPAAccountDirectoryError, errorMessage == previous { errorMessage = nil }
            cpaDirectory.failure = nil
            let previousNames = Set(authFiles.map(\.name))
            authFiles = AuthFileIdentity.deduplicated(files)
            cpaDirectory.confirmedSession = (context.sessionID, context.modeRevision)
            reconcileAccountQuotaIdentities()
            retainKnownAccountQuotas()
            persistAccountSnapshot()
            if previousNames != Set(authFiles.map(\.name)) {
                cpaDirectory.snapshotDefaults?.set(Date().timeIntervalSince1970, forKey: Self.authFilesChangedKey)
            }
            syncMenuBarSelection()
            return authFiles
        } catch {
            guard canCommit(context), isCurrentSource(), generation > cpaDirectory.publishedGeneration,
                  let message = Self.accountQuotaFailureMessage(error) else { return nil }
            // 快照与更新时间继续显示，管理按钮闭锁，直到同一会话取得下一份有效目录。
            cpaDirectory.publishedGeneration = generation
            cpaDirectory.confirmedSession = nil
            cpaDirectory.failure = message
            errorMessage = message
            notifyQuotaDataChanged()
            throw error
        }
    }

    /// Cursor／Trae 原镜像只保存显式扫描导入的账号。轮询只能更新已经存在的键。
    var importedIDEAccountKeys: [AIProvider: Set<String>] {
        Self.ideProvidersToSave.reduce(into: [:]) { result, provider in
            if let quotas = providerQuotas[provider] { result[provider] = Set(quotas.keys) }
        }
    }

    var configuredQuotaProviders: [CustomProvider] {
        #if DEBUG
        if let customProvidersForTesting { return customProvidersForTesting }
        #endif
        return CustomProviderService.shared.providers
    }

    /// 启用的用户配置和已确认的 CPA 条目与页面使用相同身份目录。同步过滤可避免空目录或删除后出现残留账号。
    private func retainKnownAccountQuotas() {
        let allowed = Set(MenuBarAccountCatalog.items(authFiles: authFiles, importedIDEAccountKeys: importedIDEAccountKeys,
            customProviders: configuredQuotaProviders, warpTokens: WarpService.shared.tokens).compactMap { item in
                item.aiProvider.map { QuotaAccountID(provider: $0, accountKey: item.accountKey) }
            })
        providerQuotas = providerQuotas.reduce(into: [:]) { filtered, entry in
            let values = entry.value.filter { allowed.contains(QuotaAccountID(provider: entry.key, accountKey: $0.key)) }
            if !values.isEmpty { filtered[entry.key] = values }
        }
        subscriptionInfos = subscriptionInfos.reduce(into: [:]) { filtered, entry in
            let values = entry.value.filter { allowed.contains(QuotaAccountID(provider: entry.key, accountKey: $0.key)) }
            if !values.isEmpty { filtered[entry.key] = values }
        }
        monitorAccountIssues = monitorAccountIssues.filter { allowed.contains($0.key) }
    }

    /// 在同步提交段持久化。IDE 继续使用原镜像；其他额度仅按现存目录／连接身份保存。
    func persistAccountSnapshot() {
        guard let defaults = cpaDirectory.snapshotDefaults else { return }
        let allowed = Set(MenuBarAccountCatalog.items(authFiles: authFiles, customProviders: configuredQuotaProviders,
                                                     warpTokens: WarpService.shared.tokens).compactMap { item in
            item.aiProvider.map { QuotaAccountID(provider: $0, accountKey: item.accountKey) }
        })
        let quotas = providerQuotas.reduce(into: [AIProvider: [String: ProviderQuotaData]]()) { filtered, entry in
            let values = entry.value.filter { allowed.contains(QuotaAccountID(provider: entry.key, accountKey: $0.key)) }
            if !values.isEmpty { filtered[entry.key] = values }
        }
        let snapshot = CPAAccountQuotaSnapshot(authFiles: authFiles, quotas: quotas, lastQuotaRefreshTime: lastQuotaRefreshTime)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: CPAAccountQuotaSnapshot.preferenceKey)
        }
    }

    private func restoreAccountSnapshot() {
        guard let data = cpaDirectory.snapshotDefaults?.data(forKey: CPAAccountQuotaSnapshot.preferenceKey),
              let snapshot = try? JSONDecoder().decode(CPAAccountQuotaSnapshot.self, from: data) else { return }
        cpaDirectory.isRestoringSnapshot = true
        defer { cpaDirectory.isRestoringSnapshot = false }
        authFiles = snapshot.authFiles
        providerQuotas.merge(snapshot.quotas) { current, _ in current }
        subscriptionInfos = snapshot.quotas.mapValues { $0.compactMapValues(\.subscriptionInfo) }
        lastQuotaRefreshTime = snapshot.lastQuotaRefreshTime
        retainKnownAccountQuotas()
    }

    /// 只有实际成功的读取可以推进可见更新时间。失败及目录读取只保留历史时间。
    func recordAccountQuotaSuccess(at updatedAt: Date) {
        lastQuotaRefreshTime = max(lastQuotaRefreshTime ?? updatedAt, updatedAt)
        persistAccountSnapshot()
    }
    /// 仪表盘与统计页共享同一个队列消费者，历史快照随应用生命周期恢复。
    let usageMonitor = UsageStatisticsStore()
    var apiKeys: [String] = []
    var isLoading = false
    private(set) var refreshingProviders: Set<AIProvider> = []
    private(set) var refreshingAccounts: Set<QuotaAccountID> = []
    @ObservationIgnored private var activeRefreshProviders: Set<AIProvider> = []

    /// 此读取直接关联私有占用集合，继续留在主类，避免为展示归位开放集合或增加重复槽位状态。
    func isRefreshBlocked(for account: QuotaAccountID) -> Bool {
        activeRefreshProviders.contains(account.provider)
    }

    var errorMessage: String?
    var oauthState: OAuthState?
    /// CPA v8 会话取消与迟到响应隔离独立管理，避免关闭弹窗后旧轮询覆盖新的登录状态。
    /// 原 CPA 会话所有者继续在主类唯一创建；授权扩展仅调用同一实例，停止代理仍能取消原会话。
    @ObservationIgnored let cpaOAuthSession = CPAOAuthSessionCoordinator()

    /// Notification name for quota data updates (used for menu bar refresh)
    static let quotaDataDidChangeNotification = Notification.Name("QuotaViewModel.quotaDataDidChange")
    
    /// 导入与既有兼容操作用的本地认证类型，不参与 CPA 账号展示或额度查询。
    var directAuthFiles: [DirectAuthFile] = []
    var monitorIssues: [AIProvider: MonitorRefreshIssue] = [:]
    var monitorAccountIssues: [QuotaAccountID: MonitorRefreshIssue] = [:]

    /// Last quota refresh time (for quota-only mode display)
    var lastQuotaRefreshTime: Date?
    
    /// IDE Scan state
    var showIDEScanSheet = false
    /// 显式扫描扩展继续更新原扫描设置单例；这里只开放原只读引用，不复制同意状态。
    @ObservationIgnored let ideScanSettings = IDEScanSettingsManager.shared
    
    @ObservationIgnored private var _agentSetupViewModel: AgentSetupViewModel?
    var agentSetupViewModel: AgentSetupViewModel {
        if let vm = _agentSetupViewModel {
            return vm
        }
        let vm = AgentSetupViewModel()
        vm.setup(proxyManager: proxyManager, quotaViewModel: self)
        _agentSetupViewModel = vm
        return vm
    }

    /// 账号可用性变更只携带本次刷新上下文，不增加状态或 Task；两个目录仍由各自原宿主提交。
    struct AccountModelCatalogRefresh {
        let source: RefreshContext
        let configuration: AgentSetupViewModel.AccountModelReload?
        let refreshVisibleCatalog: Bool
    }

    func invalidateModelsAfterCPAAccountChange(source: RefreshContext) -> AccountModelCatalogRefresh? {
        guard canUseRefreshSource(source) else { return nil }
        var endpoints = [proxyManager.baseURL]
        if let tunnel = TunnelManager.shared.tunnelState.publicURL { endpoints.append(tunnel) }
        let configuration = _agentSetupViewModel?.invalidateModelsForAccountChange(serviceBaseURLs: endpoints)
        let wasLoaded = modelCatalog.hasCompletedFetch || modelCatalog.isLoading
        // 先废弃旧目录 requestID；账号刷新期间迟到的目录不能再次被当成当前模型。
        // 懒加载 VM 未创建、目录从未显示时不创建新宿主，页面首次出现仍由原加载入口读取。
        if wasLoaded { modelCatalog.reset() }
        return AccountModelCatalogRefresh(source: source, configuration: configuration, refreshVisibleCatalog: wasLoaded)
    }

    func refreshModelsAfterCPAAccountChange(_ refresh: AccountModelCatalogRefresh?) async {
        guard let refresh, canUseRefreshSource(refresh.source) else { return }
        if let configuration = refresh.configuration {
            await _agentSetupViewModel?.reloadModelsAfterAccountChange(configuration)
        }
        guard canUseRefreshSource(refresh.source) else { return }
        if refresh.refreshVisibleCatalog { await refreshDashboardModels() }
        guard canUseRefreshSource(refresh.source) else { return }
        var endpoints = [proxyManager.baseURL]
        if let tunnel = TunnelManager.shared.tunnelState.publicURL { endpoints.append(tunnel) }
        // 使用原懒加载所有者；只有磁盘已接管的 Claude 配置才取目录，不增加持久 Task。
        let failure = await agentSetupViewModel.synchronizeManagedClaudeCatalog(serviceBaseURLs: endpoints) { [weak self] in
            self?.canUseRefreshSource(refresh.source) == true
        }
        if canUseRefreshSource(refresh.source), let failure { errorMessage = failure }
    }

    /// 生命周期扩展通过原宿主失效已存在的配置 VM，不触发懒加载，也不扩大原私有存储权限。
    func invalidateAgentModelSource() { _agentSetupViewModel?.invalidateCPAModelSource() }

    /// 账号新增／恢复可用的成功入口共用同一桥接，避免只更新账号列表却让菜单来源停在旧账号池。
    /// 原调用链内顺序执行，不新增 Task；目录和最终提交继续校验同一模式、运行会话及管理客户端。
    @discardableResult
    func refreshAfterCPAAccountChange(refreshQuotas: Bool = true) async -> Bool {
        let source = refreshContext(), client = apiClient
        let modelRefresh = invalidateModelsAfterCPAAccountChange(source: source)
        let refreshed = await refreshData(refreshQuotas: refreshQuotas)
        guard canUseRefreshSource(source), apiClient === client else { return false }
        await refreshModelsAfterCPAAccountChange(modelRefresh)
        return refreshed
    }
    
    /// Quota data per provider per account (email -> QuotaData)
    var providerQuotas: [AIProvider: [String: ProviderQuotaData]] = [:] {
        // 字典中的账号数不变也可能更新额度；任何数据写回都通知原生菜单栏。
        // SwiftUI 配额页和 NSStatusItem 从同一份新快照刷新，不依赖窗口是否打开。
        didSet {
            guard !cpaDirectory.isRestoringSnapshot else { return }
            notifyQuotaDataChanged()
            // 同步发布来源及新旧值快照，采样服务由 App 注入和订阅，不在本 VM 新增存储／任务。
            // 不能在稍后的菜单通知中读取当时的新模式来解释旧观测。
            let publication = QuotaHistoryPublication(mode: modeManager.currentMode.rawValue,
                current: providerQuotas, previous: oldValue, aliases: currentQuotaAccountAliases)
            NotificationCenter.default.post(name: QuotaHistoryPublication.notification, object: self,
                userInfo: ["publication": publication])
        }
    }

    @ObservationIgnored private var quotaNotificationTask: Task<Void, Never>?
    
    /// Subscription info per provider per account (provider -> email -> SubscriptionInfo)
    var subscriptionInfos: [AIProvider: [String: SubscriptionInfo]] = [:]
    
    /// Antigravity account switcher (for IDE token injection)
    let antigravitySwitcher = AntigravityAccountSwitcher.shared
    
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var warmupTask: Task<Void, Never>?
    /// 生命周期扩展复用原只读启动协调器；主类仍唯一创建和持有，停止仍取消同一轮初始化。
    @ObservationIgnored let proxyStartFlow = ProxyStartFlow()
    @ObservationIgnored private var proxyStartupDataTask: Task<Void, Never>?
    @ObservationIgnored private var proxyRecoveryTask: Task<Void, Never>?
    private(set) var isRestartingProxy = false
    @ObservationIgnored private var lastLogTimestamp: Int?
    @ObservationIgnored private var isWarmupRunning = false
    @ObservationIgnored private var warmupRunningAccounts: Set<WarmupAccountKey> = []

    // MARK: - IDE Quota Persistence Keys

    /// IDE 持久化扩展使用同一原始偏好键；仅开放只读常量，存储位置、键名和历史格式不变。
    static let ideQuotasKey = "persisted.ideQuotas"
    /// Providers whose quota is imported from a local IDE database and persisted
    /// separately (Cursor, Trae). Also drives `refreshImportedIDEQuotas()`.
    nonisolated static let ideProvidersToSave: Set<AIProvider> = [.cursor, .trae]

    /// Key for tracking when auth files last changed (for model cache invalidation)
    static let authFilesChangedKey = "quotio.authFiles.lastChanged"

    // MARK: - Disabled Auth Files Persistence

    private static let disabledAuthFilesKey = "persisted.disabledAuthFiles"

    /// Load disabled auth file names from UserDefaults
    /// 账号变更扩展通过此原入口读取禁用偏好；私有存储键继续留在本类，不另设偏好镜像。
    func loadDisabledAuthFiles() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: Self.disabledAuthFilesKey) ?? []
        return Set(array)
    }

    /// Save disabled auth file names to UserDefaults
    /// 账号变更扩展通过此原同步入口写回禁用偏好，保持与代理启动时同步禁用状态的共同存储。
    func saveDisabledAuthFiles(_ names: Set<String>) {
        UserDefaults.standard.set(Array(names), forKey: Self.disabledAuthFilesKey)
    }

    /// Post notification to trigger UI updates (works even when window is closed)
    /// 菜单扩展只调用原通知合并入口；Task 的创建、持有和释放仍由本类及原方法负责。
    func notifyQuotaDataChanged() {
        // 多账号批量写入与既有显式通知合并到下一轮，避免连续重建原生菜单。
        guard quotaNotificationTask == nil else { return }
        quotaNotificationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.quotaNotificationTask = nil
            NotificationCenter.default.post(name: Self.quotaDataDidChangeNotification, object: nil)
        }
    }

    /// 刷新扩展通过原同步入口占用槽位，受保护的刷新集合和 activeRefreshProviders 仍只由主类写入。
    func beginScopedRefresh(provider: AIProvider, account: QuotaAccountID? = nil) -> Bool {
        guard supportsScopedRefresh(for: provider), activeRefreshProviders.insert(provider).inserted else {
            return false
        }
        if let account {
            refreshingAccounts.insert(account)
        } else {
            refreshingProviders.insert(provider)
        }
        notifyQuotaDataChanged()
        return true
    }

    /// 刷新扩展的原 defer 成对释放同一槽位；不开放 private(set)，不改变释放和通知的先后顺序。
    func endScopedRefresh(provider: AIProvider, account: QuotaAccountID? = nil) {
        activeRefreshProviders.remove(provider)
        if let account {
            refreshingAccounts.remove(account)
        } else {
            refreshingProviders.remove(provider)
        }
        notifyQuotaDataChanged()
    }

    /// IDE 刷新通过原同步入口检查并占用槽位；可写刷新集合及 private(set) 状态仍仅在本类维护。
    func beginBatchRefresh(providers: Set<AIProvider>) -> Bool {
        guard activeRefreshProviders.isDisjoint(with: providers) else { return false }
        activeRefreshProviders.formUnion(providers)
        refreshingProviders.formUnion(providers)
        notifyQuotaDataChanged()
        return true
    }

    /// IDE 扩展原 defer 继续成对释放同一槽位，不把刷新集合的 setter 开放给扩展。
    func endBatchRefresh(providers: Set<AIProvider>) {
        activeRefreshProviders.subtract(providers)
        refreshingProviders.subtract(providers)
        notifyQuotaDataChanged()
    }

    init(monitorCoordinator: MonitorRefreshCoordinator = MonitorRefreshCoordinator(),
         directAuthService: DirectAuthFileService = DirectAuthFileService(),
         startsBackgroundServices: Bool = true,
         modeManager: OperatingModeManager = .shared,
         menuBarSettings: MenuBarSettingsManager = .shared,
         refreshSettings: RefreshSettingsManager = .shared,
         warmupSettings: WarmupSettingsManager = .shared,
         notificationManager: NotificationManager = .shared,
         accountSnapshotDefaults: UserDefaults? = nil) {
        self.cpaDirectory = CPAAccountDirectoryState(snapshotDefaults: accountSnapshotDefaults)
        self.notificationManager = notificationManager
        self.warmupSettings = warmupSettings
        self.modeManager = modeManager
        self.menuSettings = menuBarSettings
        self.refreshSettings = refreshSettings
        self.monitorCoordinator = monitorCoordinator
        self.directAuthService = directAuthService
        self.proxyManager = CLIProxyManager.shared
        // 原生页面渲染回归只需离线快照。显式关闭后台服务后，不恢复真实用量、
        // 不读取用户 IDE 缓存、不注册刷新／预热回调；正常应用默认完整启动原有服务。
        if startsBackgroundServices { loadPersistedIDEQuotas() }
        restoreAccountSnapshot()
        guard startsBackgroundServices else { return }
        observeUsageLifecycle()
        Task { await usageMonitor.restore() }
        setupRefreshCadenceCallback()
        setupWarmupCallback()
        restartWarmupScheduler()
        lastProxyURL = normalizedProxyURL(UserDefaults.standard.string(forKey: "proxyURL"))
        setupProxyURLObserver()
    }

    private func setupProxyURLObserver() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let currentProxyURL = self.normalizedProxyURL(UserDefaults.standard.string(forKey: "proxyURL"))
                guard currentProxyURL != self.lastProxyURL else { return }
                self.lastProxyURL = currentProxyURL
                await self.updateProxyConfiguration()
            }
        }
    }

    private func normalizedProxyURL(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        let sanitized = ProxyURLValidator.sanitize(rawValue)
        return sanitized.isEmpty ? nil : sanitized
    }

    private func setupRefreshCadenceCallback() {
        refreshSettings.onRefreshCadenceChanged = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartAutoRefresh()
            }
        }
    }
    
    private func setupWarmupCallback() {
        warmupSettings.onEnabledAccountsChanged = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartWarmupScheduler()
            }
        }
        warmupSettings.onWarmupCadenceChanged = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartWarmupScheduler()
            }
        }
        warmupSettings.onWarmupScheduleChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.restartWarmupScheduler()
            }
        }
    }
    
    func restartAutoRefresh() {
        if canRefreshAccountQuotas {
            startAutoRefresh()
        } else {
            // 停机和安装缺失都只展示上次成功快照，不创建备用额度任务。
            stopQuotaAutoRefresh()
        }
    }

    // MARK: - 启动初始化

    func initialize() async {
        await initializeLocalProxy(isInstalled: proxyManager.isBinaryInstalled,
                                   startProxy: { await self.startProxy() })
    }

    private func initializeLocalProxy(isInstalled: Bool, startProxy: () async -> Void) async {
        guard isInstalled else { return }
        await startProxy()
    }

    #if DEBUG
    /// 只隔离原内核启动调用，停机时没有额度读取闭包或定时任务。
    func initializeLocalProxyForTesting(isInstalled: Bool, startProxy: () async -> Void) async {
        await initializeLocalProxy(isInstalled: isInstalled, startProxy: startProxy)
    }
    #endif

    /// 延续原启动后的账号初始化序列，任务由代理会话拥有。
    /// 停止会取消旧任务，新管理客户端就绪后才能读取新会话的目录和额度。
    func scheduleProxyStartupData(sessionID: UUID) {
        proxyStartupDataTask?.cancel()
        proxyStartupDataTask = Task { [weak self] in
            guard let self, !Task.isCancelled, proxyManager.runtimeSessionID == sessionID else { return }
            await completeProxyStartupData(sessionID: sessionID)
        }
    }

    // MARK: - Warmup

    func warmupStatus(provider: AIProvider, accountKey: String) -> WarmupStatus {
        let key = WarmupAccountKey(provider: provider, accountKey: accountKey)
        return warmupStatuses[key] ?? WarmupStatus()
    }

    func warmupNextRunDate(provider: AIProvider, accountKey: String) -> Date? {
        let key = WarmupAccountKey(provider: provider, accountKey: accountKey)
        return warmupNextRun[key]
    }

    /// 启动扩展复用原预热调度入口；计划、缓存与 warmupTask 仍由主类维护，不改变重启顺序。
    /// 调度及任务所有权继续留在主类；仍先取消旧 Task，再重建计划和状态，最后按原最小到期时间等待。
    func restartWarmupScheduler() {
        warmupTask?.cancel()
        
        guard canRefreshAccountQuotas, !warmupSettings.enabledAccountIds.isEmpty else { return }
        
        let now = Date()
        warmupNextRun = [:]
        for target in warmupTargets() {
            let mode = warmupSettings.warmupScheduleMode(provider: target.provider, accountKey: target.accountKey)
            switch mode {
            case .interval:
                warmupNextRun[target] = now
            case .daily:
                let minutes = warmupSettings.warmupDailyMinutes(provider: target.provider, accountKey: target.accountKey)
                warmupNextRun[target] = nextDailyRunDate(minutes: minutes, now: now)
            }
            updateWarmupStatus(for: target) { status in
                status.nextRun = warmupNextRun[target]
            }
        }
        guard !warmupNextRun.isEmpty else { return }
        
        warmupTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let next = warmupNextRun.values.min() else { return }
                let delay = max(next.timeIntervalSince(Date()), 1)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await runWarmupCycle()
            }
        }
    }

    /// 启动扩展等待同一原预热周期；防重、状态写入、取消和账号调度继续由主类原实现负责。
    /// 整轮防重、停服延期、逐账号调用及下一次时间写入保持原位置；本批不新增会话检查或取消后的额外行为。
    func runWarmupCycle() async {
        guard !isWarmupRunning else { return }
        let targets = warmupTargets()
        guard !targets.isEmpty else { return }
        
        guard proxyManager.proxyStatus.running else {
            let now = Date()
            for target in targets {
                let mode = warmupSettings.warmupScheduleMode(provider: target.provider, accountKey: target.accountKey)
                switch mode {
                case .interval:
                    let cadence = warmupSettings.warmupCadence(provider: target.provider, accountKey: target.accountKey)
                    warmupNextRun[target] = now.addingTimeInterval(cadence.intervalSeconds)
                case .daily:
                    let minutes = warmupSettings.warmupDailyMinutes(provider: target.provider, accountKey: target.accountKey)
                    warmupNextRun[target] = nextDailyRunDate(minutes: minutes, now: now)
                }
                updateWarmupStatus(for: target) { status in
                    status.nextRun = warmupNextRun[target]
                }
            }
            return
        }
        
        isWarmupRunning = true
        defer { isWarmupRunning = false }
        
        // Warmup cycle started; no log.
        
        let now = Date()
        let dueTargets = targets.filter { target in
            guard let next = warmupNextRun[target] else { return false }
            return next <= now
        }
        
        for target in dueTargets {
            if Task.isCancelled { break }
            await warmupAccount(
                provider: target.provider,
                accountKey: target.accountKey
            )
            let mode = warmupSettings.warmupScheduleMode(provider: target.provider, accountKey: target.accountKey)
            switch mode {
            case .interval:
                let cadence = warmupSettings.warmupCadence(provider: target.provider, accountKey: target.accountKey)
                warmupNextRun[target] = Date().addingTimeInterval(cadence.intervalSeconds)
            case .daily:
                let minutes = warmupSettings.warmupDailyMinutes(provider: target.provider, accountKey: target.accountKey)
                warmupNextRun[target] = nextDailyRunDate(minutes: minutes, now: Date())
            }
            updateWarmupStatus(for: target) { status in
                status.nextRun = warmupNextRun[target]
            }
        }

        // 上游 0d37cdb：更新调度时间不能清除最近一次失败；只在下次实际执行预热时重置错误。
    }

    /// 原单账号入口继续私有并留在主类：先占用原集合，defer 成对释放，再依次校验运行状态、客户端和凭据。
    private func warmupAccount(provider: AIProvider, accountKey: String) async {
        guard provider == .antigravity else {
            // Warmup not supported for this provider; no log.
            return
        }
        let account = WarmupAccountKey(provider: provider, accountKey: accountKey)
        guard warmupRunningAccounts.insert(account).inserted else {
            // Warmup already running for this account; no log.
            return
        }
        defer { warmupRunningAccounts.remove(account) }
        guard hasCurrentCPAAccountDirectory else {
            // 快照里的索引只用于显示，不能用于本会话的预热请求。
            return
        }
        
        guard let apiClient else {
            // Warmup skipped when management client is missing; no log.
            return
        }
        
        guard let authInfo = warmupAuthInfo(provider: provider, accountKey: accountKey) else {
            // Warmup skipped when auth index is missing; no log.
            return
        }
        
        let source = refreshContext()
        func isCurrentWarmup() -> Bool {
            canCommitQuotaRefresh(source, client: apiClient)
                && warmupAuthInfo(provider: provider, accountKey: accountKey)?.authIndex == authInfo.authIndex
        }
        let availableModels = await fetchWarmupModels(
            provider: provider,
            accountKey: accountKey,
            authFileName: authInfo.authFileName,
            apiClient: apiClient
        )
        guard isCurrentWarmup(), !availableModels.isEmpty else {
            // 会话或账号已变化时不能使用旧索引进行预热。
            return
        }
        await warmupAccount(
            provider: provider,
            accountKey: accountKey,
            availableModels: availableModels,
            authIndex: authInfo.authIndex,
            apiClient: apiClient,
            isCurrent: isCurrentWarmup
        )
    }

    /// 预热扩展继续经此原缓存入口读取；缓存键、八小时 TTL、成功后记录时间和失败返回空列表的规则不变。
    func fetchWarmupModels(
        provider: AIProvider,
        accountKey: String,
        authFileName: String,
        apiClient: ManagementAPIClient
    ) async -> [WarmupModelInfo] {
        do {
            let key = WarmupAccountKey(provider: provider, accountKey: accountKey)
            if let cached = warmupModelCache[key] {
                let age = Date().timeIntervalSince(cached.fetchedAt)
                if age <= warmupModelCacheTTL {
                    return cached.models
                }
            }
            let models = try await warmupService.fetchModels(managementClient: apiClient, authFileName: authFileName)
            warmupModelCache[key] = (models: models, fetchedAt: Date())
            // Warmup fetched models; no log.
            return models
        } catch {
            // Warmup fetch failed; no log.
            return []
        }
    }

    #if DEBUG
    /// 仅供离线回归放入指定时间的缓存样本，以验证原 TTL；不参与生产读取，也不改过期判断或新增测试存储。
    func setWarmupModelCacheForTesting(provider: AIProvider, accountKey: String,
                                      models: [WarmupModelInfo], fetchedAt: Date) {
        let key = WarmupAccountKey(provider: provider, accountKey: accountKey)
        warmupModelCache[key] = (models: models, fetchedAt: fetchedAt)
    }
    #endif

    // Warmup logging intentionally disabled.
    
    /// 执行扩展经此原同步入口更新状态；私有字典仍由主类读改写，不开放 setter 或增加异步提交点。
    func updateWarmupStatus(for key: WarmupAccountKey, update: (inout WarmupStatus) -> Void) {
        var status = warmupStatuses[key] ?? WarmupStatus()
        update(&status)
        warmupStatuses[key] = status
    }

    private(set) var modelCatalog = ModelCatalogState()
    @ObservationIgnored private var modelCatalogSessionID: UUID?

    /// 单次读取先等待当前代理的客户端凭据，再查询模型；不能依赖稍后才加载的 apiKeys 缓存。
    /// 会话标识与请求令牌分别保护重启和并发刷新，配置页的临时 endpoint/key 不参与仪表盘查询。
    /// 模型目录的 requestID、运行会话与私有状态写入继续集中在主类；展示扩展不接管加载或提交。
    func refreshDashboardModels() async {
        let session = proxyManager.runtimeSessionID
        if modelCatalogSessionID != session || !proxyManager.proxyStatus.running {
            modelCatalog.reset()
            modelCatalogSessionID = session
        }
        guard proxyManager.proxyStatus.running else { return }
        let request = modelCatalog.beginLoading()
        do {
            let loader = DashboardModelCatalogLoader.local(
                baseURL: proxyManager.baseURL,
                managementKey: proxyManager.managementKey
            )
            let entries = try await loader.load()
            guard !Task.isCancelled, proxyManager.proxyStatus.running,
                  proxyManager.runtimeSessionID == session else { return }
            modelCatalog.complete(entries: entries, fetchedAt: Date(), requestID: request)
        } catch {
            guard !Task.isCancelled, proxyManager.proxyStatus.running,
                  proxyManager.runtimeSessionID == session else { return }
            modelCatalog.fail(requestID: request)
        }
    }

    /// 仪表盘手动刷新序号只驱动目录重新读取，不混用配额轮询状态。
    private(set) var dashboardRefreshID = UUID()
    private(set) var isRefreshingDashboard = false
    private(set) var dashboardRefreshTime: Date?

    /// 正常入口继续使用同一个目录刷新与唯一用量消费者；主类持有全部受保护状态。
    func refreshDashboard() async {
        await performDashboardRefresh(
            refreshData: { await self.refreshData() },
            refreshUsage: { await self.usageMonitor.refreshForDashboard(sessionID: self.proxyManager.runtimeSessionID) }
        )
    }

    /// 两个闭包仅描述原外部等待步骤，不持有任务或状态。提交保护在本类统一执行，测试不必读写真实账本。
    private func performDashboardRefresh(refreshData: () async -> Bool, refreshUsage: () async -> Bool) async {
        guard !isRefreshingDashboard, proxyManager.proxyStatus.running, let client = apiClient else { return }
        let source = refreshContext()
        func isCurrentSource() -> Bool {
            canUseRefreshSource(source) && proxyManager.proxyStatus.running && apiClient === client
        }
        guard isCurrentSource() else { return }
        isRefreshingDashboard = true
        defer { isRefreshingDashboard = false }
        dashboardRefreshID = UUID()
        // 目录刷新明确返回本轮是否完成，不能借用被别处清空的全局错误作为唯一成功证据。
        let didRefreshData = await refreshData()
        guard isCurrentSource() else { return }
        let didRefreshUsage = await refreshUsage()
        guard isCurrentSource(), didRefreshData, didRefreshUsage, errorMessage == nil else { return }
        dashboardRefreshTime = Date()
    }

    #if DEBUG
    /// 只替换两项外部 I/O；真实互斥、刷新序号、会话复核和完成时间仍经过生产提交路径。
    func refreshDashboardForTesting(refreshData: () async -> Bool, refreshUsage: () async -> Bool) async {
        await performDashboardRefresh(refreshData: refreshData, refreshUsage: refreshUsage)
    }
    #endif

    /// 安装失败通过现有可呈现错误状态回传，视图不承担下载与文件操作。
    func installDashboardProxy() async {
        errorMessage = nil
        do {
            try await proxyManager.downloadAndInstallBinary()
            try Task.checkCancellation()
            await startProxy()
        } catch is CancellationError {
            // 应用或安装调用取消时，不交给后续流程再启动代理。
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 路由中心和菜单栏共用一个重启事务。底层 start 等待当前进程真实退出，
    /// 并以运行会话校验等待期间出现的停止或退出请求。
    func restartProxy() async {
        guard !isRestartingProxy, !proxyStartFlow.isRunning, !proxyManager.isStarting else { return }
        isRestartingProxy = true
        defer { isRestartingProxy = false }
        if proxyManager.proxyStatus.running {
            stopProxy()
        }
        await startProxy()
    }

    /// 停止事务在状态宿主依次取消启动／恢复／轮询、结束授权与代理，并保留原目录和额度快照。
    func stopProxy() {
        // 这是停止事务的同步线性化起点，先撤销排队的目录提交，再改变运行会话或执行停止副作用。
        // _apiClient.didSet 仍为直接替换客户端的路径提供同一兜底，不能把撤销延迟到 stop 的末尾。
        invalidateAgentModelSource()
        // 释放的是这一轮初始化，不能让慢请求、重试或预热阻止下一次启动。
        proxyStartFlow.cancel()
        proxyStartupDataTask?.cancel()
        proxyStartupDataTask = nil
        proxyRecoveryTask?.cancel()
        proxyRecoveryTask = nil
        stopQuotaAutoRefresh()

        if tunnelManager.tunnelState.isActive || tunnelManager.tunnelState.status == .starting {
            Task { @MainActor in
                await tunnelManager.stopTunnel()
            }
        }
        
        // 停止代理同步结束本地 OAuth 生命周期，后续迟到的授权响应不能重新打开旧弹窗。
        cpaOAuthSession.cancel()
        proxyManager.stop()
        // 停止后保留原 CPA 规范键及上次成功时间；不重键到本机文件，也不派生替代刷新。
        restartWarmupScheduler()
        notifyQuotaDataChanged()

        // Invalidate URLSession to close all connections
        // Capture client reference before setting to nil to avoid race condition
        let clientToInvalidate = _apiClient
        _apiClient = nil
        
        if let client = clientToInvalidate {
            Task {
                await client.invalidate()
            }
        }
    }

    /// 启动扩展通过此原同步入口建立管理客户端；私有指针与 Observation 仍由主类持有和写入。
    func setupAPIClient() {
        _apiClient = ManagementAPIClient(
            baseURL: proxyManager.managementURL,
            authKey: proxyManager.managementKey
        )
    }
    
    /// 启动扩展通过原入口建立 CPA 轮询；refreshTask 仍由本类唯一持有。
    /// 定时到期本身就是额度刷新依据，不再通过 refreshData 内的机会性节流二次判断。
    func startAutoRefresh() {
        startAutoRefresh(
            now: { ContinuousClock.now },
            sleepUntil: { try await ContinuousClock().sleep(until: $0) },
            refreshQuotas: { await self.refreshAllQuotas(waitForAvailability: true) }
        )
    }

    /// 时钟与额度读取仅以闭包注入，便于离线验证到期／取消，不增加状态、Task 或第二个计时器。
    /// 正式运行固定使用单调时钟及原批量入口；网络耗时不会再与整段刷新间隔重复累计。
    private func startAutoRefresh(
        now: @escaping @MainActor () -> ContinuousClock.Instant,
        sleepUntil: @escaping @MainActor (ContinuousClock.Instant) async throws -> Void,
        refreshQuotas: @escaping @MainActor () async -> Void
    ) {
        stopQuotaAutoRefresh()
        guard canRefreshAccountQuotas,
              let intervalNs = refreshSettings.refreshCadence.intervalNanoseconds else {
            return
        }
        let modeRevision = modeManager.revision
        func isCurrentMode() -> Bool {
            !Task.isCancelled && modeManager.revision == modeRevision
        }

        refreshTask = Task {
            var consecutiveFailures = 0
            let maxFailuresBeforeRecovery = max(3, Int(180_000_000_000 / intervalNs))
            let interval = Duration.nanoseconds(Int64(intervalNs))
            var nextRefresh = now().advanced(by: interval)

            while !Task.isCancelled {
                do { try await sleepUntil(nextRefresh) } catch { break }
                guard isCurrentMode() else { break }

                // 在原轮询 Task 内完整等待一轮，避免派生的额度任务失去取消归属，
                // 或被最近的启动／手动批次时间戳挡住后再等一整个周期。
                // CPA 管理器可自行重启而不重建本 Task，因此会话／客户端只绑定一轮。
                // 旧轮失效时拒绝继续和写回，保留下个到期点采样新来源，不能永久停掉调度。
                let completedInSource = await refreshScheduledCPAData(refreshQuotas: refreshQuotas)
                guard isCurrentMode() else { break }
                
                if completedInSource && errorMessage != nil {
                    consecutiveFailures += 1
                    Log.quota("Refresh failed, consecutive failures: \(consecutiveFailures)")
                    
                    if consecutiveFailures >= maxFailuresBeforeRecovery {
                        Log.quota("Attempting proxy recovery...")
                        await attemptProxyRecovery()
                        consecutiveFailures = 0
                    }
                } else {
                    if consecutiveFailures > 0 {
                        Log.quota("Refresh succeeded, resetting failure count")
                    }
                    consecutiveFailures = 0
                }

                // 正常请求维持原定周期边界；超长请求或休眠错过边界时不并发补跑多轮。
                // 已有槽位互斥继续生效，慢轮次完成后重新等待一周期，避免追赶请求风暴。
                nextRefresh = nextRefresh.advanced(by: interval)
                let finishedAt = now()
                if nextRefresh <= finishedAt {
                    nextRefresh = finishedAt.advanced(by: interval)
                }
            }
        }
    }

    #if DEBUG
    /// 测试只替换时钟与外部额度 I/O，真实定时 Task、目录读取、会话保护及菜单通知仍走生产路径。
    func startCPAAutoRefreshForTesting(
        now: @escaping @MainActor () -> ContinuousClock.Instant,
        sleepUntil: @escaping @MainActor (ContinuousClock.Instant) async throws -> Void,
        refreshQuotas: @escaping @MainActor () async -> Void
    ) {
        startAutoRefresh(now: now, sleepUntil: sleepUntil, refreshQuotas: refreshQuotas)
    }

    /// 只等待主类现有任务结束，供会话失效回归确认旧循环已退出；不暴露句柄或新增任务存储。
    func waitForQuotaAutoRefreshForTesting() async {
        await refreshTask?.value
    }
    #endif
    
    /// Attempt to recover an unresponsive proxy
    /// 恢复任务继续由主类独立持有；先按原顺序停止，再采样新会话并建立恢复 Task，避免继承已取消的轮询状态。
    private func attemptProxyRecovery() async {
        guard !Task.isCancelled, proxyManager.proxyStatus.running else { return }
        Log.quota("Attempting proxy recovery...")
        stopProxy()
        let session = proxyManager.runtimeSessionID
        // stopProxy 会取消当前轮询任务。恢复必须由独立任务执行，不能把轮询的取消
        // 状态传给新启动；同时保留任务引用，让用户随后手动停止仍能取消自动恢复。
        let recovery = Task { [weak self] in
            guard let self, !Task.isCancelled, proxyManager.runtimeSessionID == session else { return }
            await self.startProxy()
        }
        proxyRecoveryTask = recovery
        await recovery.value
    }
    
    @ObservationIgnored private var lastQuotaRefresh: Date?
    
    private var quotaRefreshInterval: TimeInterval {
        refreshSettings.refreshCadence.intervalSeconds ?? 60
    }

    /// 非定时入口读取 CPA 目录时沿用原机会性节流：从未启动过批次则立即到期，否则按设置间隔判断。
    /// CPA 自动任务由单调时钟直接判定到期，不再把这个时间戳当成第二道定时门槛。
    /// 此方法同步读取原私有时间和频率，不缓存判断、不推进时间，也不把原字段的 setter 开放给扩展。
    func isQuotaRefreshDueForPolling() -> Bool {
        if let lastRefresh = lastQuotaRefresh {
            return Date().timeIntervalSince(lastRefresh) >= quotaRefreshInterval
        } else {
            return true
        }
    }

    /// 仅替代原批次入口的私有时间赋值；调用点仍在槽位申请和来源校验之后，不增加挂起或调度。
    /// 可见刷新时间继续由各原路径在既定位置写入，不合并两次 Date() 或调整原先后顺序。
    func recordQuotaRefreshStart() {
        lastQuotaRefresh = Date()
    }

    /// 状态归 ViewModel 持有，原生菜单重建不会丢失进行中的用户刷新状态。
    /// 菜单与账号页重复点击合为同一轮，后台刷新不驱动此进度圈。
    let manualAccountRefreshState = ManualRefreshState()

    /// 停止轮询不停止代理，可用于切换频率和隔离的生命周期验证。
    func stopQuotaAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    #if DEBUG
    // 只替换测试夹具里的外部读取；正式运行没有这些钩子，也不缩短用户刷新周期。
    @ObservationIgnored var accountRefreshStepHookForTesting: (@MainActor (AccountRefreshStep) async -> Void)?
    @ObservationIgnored var localQuotaFetchHookForTesting: (@MainActor (AIProvider) async -> [String: ProviderQuotaData])?
    @ObservationIgnored var customProvidersForTesting: [CustomProvider]?
    var isQuotaAutoRefreshScheduledForTesting: Bool { refreshTask != nil }

    #endif

    #if DEBUG
    /// Test seam: replaces the IDE database read so a test can suspend *inside* the fetch
    /// and drive main-actor reentrancy deterministically. Never set outside tests.
    @ObservationIgnored var ideQuotaFetchHookForTesting: (@MainActor (AIProvider) async -> [String: ProviderQuotaData])?
    #endif

    #if DEBUG
    // 仅替代外部文件读取和最终刷新，实际目标选择、上下文校验和上传仍经过生产路径。
    // 离线回归可以挂起第二个文件的读取，不启停用户 CPA，也不扫描真实凭据目录。
    @ObservationIgnored var authImportReadHookForTesting: (@MainActor (URL) async throws -> Data)?
    @ObservationIgnored var authImportRefreshHookForTesting: (@MainActor (Bool) async -> Void)?
    func setAuthImportClientForTesting(_ client: ManagementAPIClient?) { _apiClient = client }
    /// 离线账号启停回归复用原子 VM 所有者，仅替换外部取数依赖，不新增测试状态。
    func setAgentSetupViewModelForTesting(_ viewModel: AgentSetupViewModel) { _agentSetupViewModel = viewModel }
    #endif

    /// 同一个提交令牌同时排序列表读取与编辑；有效编辑开始即废弃之前的列表快照。
    /// 编辑期间不发出列表读取，避免旧服务端快照在写成功后覆盖已确认值；状态仍仅由主类持有。
    @ObservationIgnored private var apiKeyRequestID = UUID()
    private(set) var isMutatingAPIKeys = false

    private struct APIKeyRequestContext {
        let requestID: UUID
        let client: ManagementAPIClient
        let source: RefreshContext
    }

    private func beginAPIKeyRequest(using client: ManagementAPIClient) -> APIKeyRequestContext {
        apiKeyRequestID = UUID()
        return APIKeyRequestContext(requestID: apiKeyRequestID, client: client, source: refreshContext())
    }

    /// 账号目录变更不影响客户端密钥列表；只验证取消、客户端身份、模式／运行会话及本列表的读写令牌。
    private func canCommitAPIKeyRequest(_ request: APIKeyRequestContext) -> Bool {
        apiKeyRequestID == request.requestID && apiClient === request.client && canUseRefreshSource(request.source)
    }

    /// 仅原编辑所有者能释放互斥。跨客户端的新编辑已取得令牌时，旧 defer 不得改变新编辑状态。
    private func finishAPIKeyMutation(_ request: APIKeyRequestContext) {
        if apiKeyRequestID == request.requestID { isMutatingAPIKeys = false }
    }

    /// 页面和后台目录刷新统一经此提交列表，成功与失败都验证同一来源及读写世代。
    /// 返回 false 表示失败、取消、被新操作取代或正在编辑，调用方不能据此标记整轮刷新成功。
    func refreshAPIKeySnapshot(using client: ManagementAPIClient, clearingErrorOnSuccess: Bool = false) async -> Bool {
        guard !Task.isCancelled, apiClient === client, !isMutatingAPIKeys else { return false }
        let request = beginAPIKeyRequest(using: client)
        do {
            let keys = try await client.fetchAPIKeys()
            guard canCommitAPIKeyRequest(request) else { return false }
            apiKeys = keys
            if clearingErrorOnSuccess { errorMessage = nil }
            return true
        } catch {
            guard canCommitAPIKeyRequest(request), !(error is CancellationError) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// 页面保持原无返回值入口；读取失败留在同一个错误状态中，迟到响应不会污染新页面会话。
    func fetchAPIKeys() async {
        guard let client = apiClient else { return }
        _ = await refreshAPIKeySnapshot(using: client)
    }

    /// 写入结果显式返回页面：只有服务端确认成功，才允许销毁编辑草稿。
    /// 串行化修改操作，避免重复点击导致并发覆盖；成功后直接更新已确认的本地值。
    @discardableResult
    func addAPIKey(_ key: String) async -> Bool {
        guard !Task.isCancelled, !isMutatingAPIKeys else { return false }
        guard let client = apiClient else {
            errorMessage = "apiKeys.manager.disconnected".localized()
            return false
        }
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !apiKeys.contains(value) else {
            errorMessage = "apiKeys.manager.invalid".localized()
            return false
        }
        let request = beginAPIKeyRequest(using: client)
        isMutatingAPIKeys = true
        defer { finishAPIKeyMutation(request) }
        do {
            try await client.addAPIKey(value)
            guard canCommitAPIKeyRequest(request) else { return false }
            apiKeys.append(value)
            errorMessage = nil
            return true
        } catch {
            guard canCommitAPIKeyRequest(request), !(error is CancellationError) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// 编辑仍通过原互斥标记和服务端确认后更新本地列表，返回值继续供页面保留或关闭草稿。
    @discardableResult
    func updateAPIKey(old: String, new: String) async -> Bool {
        guard !Task.isCancelled, !isMutatingAPIKeys else { return false }
        guard let client = apiClient else {
            errorMessage = "apiKeys.manager.disconnected".localized()
            return false
        }
        let value = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value == old || !apiKeys.contains(value) else {
            errorMessage = "apiKeys.manager.invalid".localized()
            return false
        }
        let request = beginAPIKeyRequest(using: client)
        isMutatingAPIKeys = true
        defer { finishAPIKeyMutation(request) }
        do {
            try await client.updateAPIKey(old: old, new: value)
            guard canCommitAPIKeyRequest(request) else { return false }
            apiKeys = apiKeys.map { $0 == old ? value : $0 }
            errorMessage = nil
            return true
        } catch {
            guard canCommitAPIKeyRequest(request), !(error is CancellationError) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// 删除仍复用原客户端与实例级互斥，原 defer 释放、确认后本地删除及错误反馈不迁移。
    @discardableResult
    func deleteAPIKey(_ key: String) async -> Bool {
        guard !Task.isCancelled, !isMutatingAPIKeys else { return false }
        guard let client = apiClient else {
            errorMessage = "apiKeys.manager.disconnected".localized()
            return false
        }
        let request = beginAPIKeyRequest(using: client)
        isMutatingAPIKeys = true
        defer { finishAPIKeyMutation(request) }
        do {
            try await client.deleteAPIKey(value: key)
            guard canCommitAPIKeyRequest(request) else { return false }
            apiKeys.removeAll { $0 == key }
            errorMessage = nil
            return true
        } catch {
            guard canCommitAPIKeyRequest(request), !(error is CancellationError) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }
    
    // MARK: - Notification Helpers
    
    /// 目录刷新复用原冷却通知与状态去重入口；私有状态字典和通知管理器继续仅由主类持有。
    /// 显示名称只负责文案；状态与通知去重统一使用稳定提供商身份，保留原账号字符串和状态比较。
    func checkAccountStatusChanges() {
        for file in authFiles {
            let providerID = file.providerType?.rawValue ?? file.provider
            let accountKey = "\(providerID)_\(file.email ?? file.name)"
            let previousStatus = lastKnownAccountStatuses[accountKey]
            
            if file.status == "cooling" && previousStatus != "cooling" {
                notificationManager.notifyAccountCooling(
                    provider: file.providerType?.displayName ?? file.provider,
                    account: file.email ?? file.name,
                    providerID: providerID
                )
            } else if file.isReady && previousStatus == "cooling" {
                // v8 恢复后使用 active，继续清理已有 cooling 提醒；不把未知状态当作恢复。
                notificationManager.clearCoolingNotification(
                    provider: providerID,
                    account: file.email ?? file.name
                )
            }
            
            lastKnownAccountStatuses[accountKey] = file.status
        }
    }
    
    /// 继续筛掉未知比例并以最小剩余额度判定原提醒；通知及恢复清理不在展示扩展重复触发。
    func checkQuotaNotifications() {
        for (provider, accountQuotas) in providerQuotas {
            for (account, quotaData) in accountQuotas {
                guard !quotaData.models.isEmpty else { continue }
                
                // Filter out models with unknown percentage (-1 means unavailable/unknown)
                let validPercentages = quotaData.models.map(\.percentage).filter { $0 >= 0 }
                guard !validPercentages.isEmpty else { continue }
                
                let minRemainingPercent = validPercentages.min() ?? 100.0
                
                if minRemainingPercent <= notificationManager.quotaAlertThreshold {
                    notificationManager.notifyQuotaLow(
                        provider: provider.displayName,
                        account: account,
                        remainingPercent: minRemainingPercent,
                        providerID: provider.rawValue
                    )
                } else {
                    notificationManager.clearQuotaNotification(
                        provider: provider.rawValue,
                        account: account
                    )
                }
            }
        }
    }

    // MARK: - Menu Bar Quota Items
    
    var menuBarSettings: MenuBarSettingsManager {
        menuSettings
    }

}
