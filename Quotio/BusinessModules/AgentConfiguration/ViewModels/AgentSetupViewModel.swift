//
//  AgentSetupViewModel.swift
//  Quotio - Agent Setup State Management
//

import Foundation
import SwiftUI
import AppKit
import os.log

@MainActor
@Observable
final class AgentSetupViewModel {
    private let detectionService: AgentDetectionService
    private let configurationService: AgentConfigurationService
    /// 只读终端依赖默认仍使用原启动器；离线回归可模拟拉起失败，不新增操作状态或 Task 宿主。
    private let launchCommand: @MainActor (String) async throws -> Void
    private let shellManager: ShellProfileManager
    /// 检测结果仍由本 VM 提交，默认复用原检测 actor；只读注入让原生弹窗回归不扫描真实客户端。
    private let detectAgentStatuses: @Sendable (Bool) async -> [AgentStatus]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Quotio", category: "AgentSetup")

    var agentStatuses: [AgentStatus] = []
    var isLoading = false
    var isConfiguring = false
    /// 初次回填结束前禁用编辑与保存，防止用户选择被稍后返回的旧配置覆盖。
    var isLoadingConfiguration = false
    var isDeletingBackups = false
    var isTesting = false
    var selectedAgent: CLIAgent?
    var configResult: AgentConfigResult?
    var testResult: ConnectionTestResult?
    var errorMessage: String?

    var availableModels: [AvailableModel] = []
    var isFetchingModels = false
    /// 仅描述本次目录读取结果，不与保存错误共用弹窗，也不把旧候选伪装成当前可用目录。
    private(set) var modelLoadMessage: String?
    /// 原 ViewModel 持有请求世代；不创建第二个任务宿主。关闭、重开和并行刷新都会使旧结果失效。
    private var modelLoadGeneration = UUID() {
        didSet {
            // 世代不仅约束网络返回，还同步撤销已经排进配置 actor 的旧提交。
            // 关闭／重开、换客户端、刷新和账号变更沿用原世代入口，不复制第二份计数。
            managedCatalogAuthorization?.invalidate()
            managedCatalogAuthorization = nil
        }
    }
    @ObservationIgnored private var managedCatalogAuthorization: ClaudeCatalogCommitAuthorization?
    /// 目录证据仍归原状态宿主；保存与预览只采用当前会话、客户端、地址和 key 的成功结果。
    /// 原始注册证据与筛选候选仍归同一宿主，不创建任务；换连接后，旧证据不能用于迁移模型。
    private var loadedModelSource: (sessionID: UUID, agent: CLIAgent?, url: String, key: String, catalog: [AvailableModel])?
    private let fetchModels: @Sendable (String, String) async throws -> AgentModelCatalogService.Selection
    /// 弹窗身份与单次目录请求分别计数：同一客户端关闭重开也必须是不同会话。
    /// 身份、操作令牌仍归原 ViewModel；页面仅捕获不可变 UUID，不持有第二份业务状态或 Task。
    private(set) var configurationSessionID = UUID()
    private var configurationReadGeneration = UUID()
    private var configurationOperationID = UUID()
    private var connectionRequestID = UUID()
    private let configurationEndpoint: (@MainActor () -> String?)?
    private let readConfiguration: @Sendable (CLIAgent) async -> AgentConfigurationService.SavedAgentConfig?
    private let probeConnection: @Sendable (String, String) async -> ConnectionTestResult
    /// 对外保留既有五参数注入；内部统一冻结 Shell，与配置模式、存储方式一起传给同一生成事务。
    /// 不在生成途中重新读取 detectedShell，避免 JSON 与后续 Profile 分别采用不同的终端语法。
    private let generateConfiguration: @Sendable (CLIAgent, AgentConfiguration, ConfigurationMode, ConfigStorageOption, [AvailableModel], ShellType) async throws -> AgentConfigResult

    var currentConfiguration: AgentConfiguration?
    /// 原数组仍由本 VM 提交；视图只读取与当前页面、地址和 key 匹配的候选，防止换连接后沿用旧目录。
    var currentModelCandidates: [AvailableModel] {
        guard let source = loadedModelSource, let config = currentConfiguration,
              source.sessionID == configurationSessionID, source.agent == selectedAgent,
              source.url == config.proxyURL, source.key == config.apiKey else { return [] }
        return availableModels
    }
    /// 仅把当前成功读取的原世代提供给原弹窗任务，用于同步别名元数据；不增加刷新计数或后台轮询。
    var currentModelCatalogRevision: UUID? {
        guard let source = loadedModelSource, let config = currentConfiguration,
              source.sessionID == configurationSessionID, source.agent == selectedAgent,
              source.url == config.proxyURL, source.key == config.apiKey else { return nil }
        return modelLoadGeneration
    }
    var claudeCompatibilityModels: [AvailableModel] {
        guard let source = loadedModelSource, let config = currentConfiguration,
              source.sessionID == configurationSessionID, source.agent == selectedAgent,
              source.url == config.proxyURL, source.key == config.apiKey else { return [] }
        return source.catalog
    }
    var claudeCompatibilityPlan: ClaudeConfigurationPlan? {
        guard selectedAgent == .claudeCode, let config = currentConfiguration else { return nil }
        return ClaudeConfigurationPlan(configuration: config, availableModels: claudeCompatibilityModels,
                                       legacy: savedConfig?.claudeLegacyModelReferences ?? .init())
    }
    var detectedShell: ShellType = .zsh
    var configurationMode: ConfigurationMode = .automatic
    var configStorageOption: ConfigStorageOption = .jsonOnly
    var selectedRawConfigIndex: Int = 0

    // MARK: - Remote Version & Lifecycle State
    var remoteVersions: [CLIAgent: String] = [:]
    var isCheckingUpdates: [CLIAgent: Bool] = [:]
    var updateMessages: [CLIAgent: String] = [:]
    
    // MARK: - Saved Configuration State
    
    /// Currently saved configuration read from agent's config files
    var savedConfig: AgentConfigurationService.SavedAgentConfig?
    
    /// Available backup files for the selected agent
    var availableBackups: [AgentConfigurationService.BackupFile] = []
    
    /// Selected setup mode (proxy or default)
    var selectedSetupMode: ConfigurationSetup = .proxy
    
    /// Task reference for cancellation when switching agents quickly
    private var configurationLoadTask: Task<Void, Never>?

    weak var proxyManager: CLIProxyManager?

    /// Reference to QuotaViewModel for quota checking
    weak var quotaViewModel: QuotaViewModel?

    /// 可注入临时目录中的配置服务，用于验证备份操作不会影响未保存的表单状态。
    init(configurationService: AgentConfigurationService = AgentConfigurationService(),
         shellManager: ShellProfileManager = ShellProfileManager(),
         fetchModels: (@Sendable (String, String) async throws -> [AvailableModel])? = nil,
         fetchModelSelection: (@Sendable (String, String) async throws -> AgentModelCatalogService.Selection)? = nil,
         configurationEndpoint: (@MainActor () -> String?)? = nil,
         readConfiguration: (@Sendable (CLIAgent) async -> AgentConfigurationService.SavedAgentConfig?)? = nil,
         probeConnection: @escaping @Sendable (String, String) async -> ConnectionTestResult = { url, key in
             await AgentModelCatalogService.testConnection(proxyURL: url, apiKey: key)
         },
         generateConfiguration: (@Sendable (CLIAgent, AgentConfiguration, ConfigurationMode, ConfigStorageOption, [AvailableModel]) async throws -> AgentConfigResult)? = nil,
         detectAgentStatuses: (@Sendable (Bool) async -> [AgentStatus])? = nil,
         launchCommand: @escaping @MainActor (String) async throws -> Void = { try await TerminalLauncher.shared.launch(command: $0) }) {
        let detector = AgentDetectionService()
        self.detectionService = detector
        self.configurationService = configurationService
        self.shellManager = shellManager
        self.detectAgentStatuses = detectAgentStatuses ?? { await detector.detectAllAgents(forceRefresh: $0) }
        // 保留原注入签名供既有离线用例使用；生产一次读取同时获得目录证据和筛选候选。
        self.fetchModels = fetchModelSelection ?? { url, key in
            if let fetchModels {
                let models = try await fetchModels(url, key)
                return .init(catalog: models, candidates: models)
            }
            return try await AgentModelCatalogService.fetchModelSelection(proxyURL: url, apiKey: key)
        }
        self.configurationEndpoint = configurationEndpoint
        // 只读／执行依赖默认仍复用原 actor 与检测器；注入仅用于显式挂起迟到响应的离线验证。
        self.readConfiguration = readConfiguration ?? { await configurationService.readConfiguration(agent: $0) }
        self.probeConnection = probeConnection
        self.generateConfiguration = { agent, config, mode, storage, models, shell in
            if let generateConfiguration {
                return try await generateConfiguration(agent, config, mode, storage, models)
            }
            return try await configurationService.generateConfiguration(agent: agent, config: config, mode: mode,
                storageOption: storage, detectionService: detector, availableModels: models, shell: shell)
        }
        self.launchCommand = launchCommand
    }

    func setup(proxyManager: CLIProxyManager, quotaViewModel: QuotaViewModel? = nil) {
        self.proxyManager = proxyManager
        self.quotaViewModel = quotaViewModel
    }

    func refreshAgentStatuses(forceRefresh: Bool = false) async {
        isLoading = true
        defer { isLoading = false }

        agentStatuses = await detectAgentStatuses(forceRefresh)
        detectedShell = await shellManager.detectShell()
    }

    func status(for agent: CLIAgent) -> AgentStatus? {
        agentStatuses.first { $0.agent == agent }
    }

    @discardableResult
    func startConfiguration(for agent: CLIAgent, apiKey: String) -> UUID {
        configurationSessionID = UUID()
        let sessionID = configurationSessionID
        configurationReadGeneration = UUID()
        let readID = configurationReadGeneration
        configurationLoadTask?.cancel()
        loadedModelSource = nil
        isDeletingBackups = false
        errorMessage = nil
        isLoadingConfiguration = false
        selectedAgent = nil
        currentConfiguration = nil
        availableModels = []
        modelLoadMessage = nil
        isFetchingModels = false
        configResult = nil
        testResult = nil
        selectedRawConfigIndex = 0
        configurationMode = .automatic
        configStorageOption = .jsonOnly
        isConfiguring = false
        isTesting = false
        savedConfig = nil
        availableBackups = []
        selectedSetupMode = .proxy  // Reset to default

        // 正常入口仍读取原代理与隧道；离线回归只注入地址，不创建真实 CPA manager 或访问钥匙串。
        let endpoint = configurationEndpoint?() ?? proxyManager.map { manager in
            TunnelManager.shared.tunnelState.publicURL ?? manager.baseURL
        }
        guard let endpoint else {
            errorMessage = "Proxy manager not available"
            return sessionID
        }

        selectedAgent = agent
        // 新页面不能复用上一提供商／密钥的目录；已保存模型稍后按原回填顺序恢复。
        modelLoadGeneration = UUID()
        availableModels = []
        modelLoadMessage = nil
        isFetchingModels = false
        isLoadingConfiguration = true

        // Create configuration with defaults first
        currentConfiguration = AgentConfiguration(
            agent: agent,
            proxyURL: endpoint + "/v1",
            apiKey: apiKey,
            setupMode: selectedSetupMode
        )

        // 本次用户明确授权接管目录菜单；只在生产配置入口启用，旧序列化草稿仍可正常读取。
        if agent == .claudeCode { currentConfiguration?.claudeCatalogManaged = true }

        // 仍由原唯一回填 Task 顺序读取磁盘和模型目录；会话切换时已同步取消旧 Task。
        configurationLoadTask = Task { [weak self] in
            guard let self else { return }
            
            await self.loadExistingConfiguration(for: agent, sessionID: sessionID, readID: readID)
            
            // Guard that selectedAgent still matches after async work
            guard !Task.isCancelled, self.isCurrentConfigurationSession(sessionID), self.selectedAgent == agent,
                  self.configurationReadGeneration == readID else { return }
            self.isLoadingConfiguration = false
            await self.loadModels(sessionID: sessionID)
        }
        return sessionID
    }

    /// 可选身份只为既有程序调用兼容；生产页面始终传入展示时捕获的 UUID。
    /// 必须在任何补 key、清目录、加锁和写错误之前校验，不能等请求返回才判断。
    func isCurrentConfigurationSession(_ sessionID: UUID?) -> Bool {
        sessionID == nil || configurationSessionID == sessionID
    }
    
    /// Load existing configuration from agent's config files and apply to current configuration
    private func loadExistingConfiguration(for agent: CLIAgent, sessionID: UUID, readID: UUID) async {
        func isCurrentRead() -> Bool {
            !Task.isCancelled && isCurrentConfigurationSession(sessionID) && selectedAgent == agent && configurationReadGeneration == readID
        }
        guard isCurrentRead() else { return }
        let loadedConfig = await readConfiguration(agent)
        guard isCurrentRead() else { return }
        let loadedBackups = await configurationService.listBackups(agent: agent)
        // 相同客户端也可能已经重开；恢复备份不属于初次回填 Task，不能只依赖任务取消或客户端名称。
        guard isCurrentRead() else { return }
        savedConfig = loadedConfig
        availableBackups = loadedBackups
        
        // Pre-populate configuration with saved values
        guard let saved = savedConfig else { return }
        
        // Determine setup mode from saved config
        selectedSetupMode = saved.isProxyConfigured ? .proxy : .defaultSetup
        
        // Update current configuration with saved model slots
        if agent == .claudeCode {
            // 回填必须同时恢复服务来源和对应凭据。当前 CPA 的新客户端 key 可继续使用；
            // 外部／旧 CPA 地址则只使用该来源自己的 key，不能把本机 CPA 的认证发送给其他服务。
            if saved.isProxyConfigured, let baseURL = saved.baseURL, !baseURL.isEmpty {
                let savedURL = ClaudeConfigurationSource.modelAPIBaseURL(baseURL)
                let sameCPA = isCPAModelServiceURL(savedURL)
                let currentSourceIsCPA = currentConfiguration.map { isCPAModelServiceURL($0.proxyURL) } ?? false
                let currentKey = currentConfiguration?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                currentConfiguration?.proxyURL = savedURL
                if !sameCPA || !currentSourceIsCPA || currentKey.isEmpty {
                    currentConfiguration?.apiKey = saved.apiKey ?? ""
                }
            }
            // Claude 回填是完整快照：缺失槽表示没有固定映射，不能把恢复前草稿的旧目标再次写回。
            // 原读取层继续解释历史名称与 1M，不在这里为缺失的角色猜测具体型号。
            currentConfiguration?.modelSlots = saved.modelSlots
        } else {
            for (slot, model) in saved.modelSlots {
                currentConfiguration?.modelSlots[slot] = model
            }
        }

        if agent == .claudeCode {
            currentConfiguration?.claudeDefaultModel = saved.defaultModel
            currentConfiguration?.claudeDefaultModel1M = saved.claudeDefaultModel1M
            currentConfiguration?.claudeModelDisplayNames = saved.modelDisplayNames
            currentConfiguration?.claudeModelPlatformHints = saved.modelPlatformHints
            currentConfiguration?.claudeMaxContextTokens = saved.claudeMaxContextTokens
            currentConfiguration?.claudeAutoCompactPercentage = saved.claudeAutoCompactPercentage
            currentConfiguration?.claudeDisableAutoCompact = saved.claudeDisableAutoCompact
            currentConfiguration?.claudeModel1M = saved.claudeModel1M
            currentConfiguration?.claudeGatewayModelDiscovery = saved.claudeGatewayModelDiscovery
            currentConfiguration?.claudeModelPicker = saved.claudeModelPicker
            currentConfiguration?.claudeSubagentModel = saved.claudeSubagentModel
            currentConfiguration?.claudeSubagentModelForce = saved.claudeSubagentModelForce
        }

        // Restore saved Codex reasoning effort
        if let effort = saved.reasoningEffort {
            currentConfiguration?.codexReasoningEffort = effort
        }

        // Update setup mode in current configuration
        currentConfiguration?.setupMode = selectedSetupMode
    }

    /// Restore configuration from a backup file
    func restoreFromBackup(_ backup: AgentConfigurationService.BackupFile, sessionID expectedSessionID: UUID? = nil) async {
        guard !Task.isCancelled, isCurrentConfigurationSession(expectedSessionID), selectedAgent == backup.agent,
              !isConfiguring, !isLoadingConfiguration, !isDeletingBackups else { return }
        let sessionID = configurationSessionID
        let agent = backup.agent
        let readID = UUID()
        let operationID = UUID()
        configurationOperationID = operationID
        configurationReadGeneration = readID
        // 恢复是原表单中的完整写操作：恢复文件、回填、目录取证和预览必须处于同一互斥范围。
        // 不增加 Task／锁宿主；关闭重开时原会话身份和操作令牌共同禁止旧 defer 释放新页面。
        func ownsOperation() -> Bool {
            isCurrentConfigurationSession(sessionID) && configurationOperationID == operationID
        }
        isConfiguring = true
        isLoadingConfiguration = true
        errorMessage = nil
        configResult = nil
        modelLoadGeneration = UUID()
        loadedModelSource = nil
        availableModels = []
        modelLoadMessage = nil
        defer {
            if ownsOperation() { isConfiguring = false; isLoadingConfiguration = false }
        }
        do {
            // 已确认的文件恢复仍交给原 actor；恢复完成后只能回填发起它的页面，不选取此时的新客户端。
            try await configurationService.restoreFromBackup(backup)
            guard !Task.isCancelled, ownsOperation(), configurationReadGeneration == readID else { return }
            await loadExistingConfiguration(for: agent, sessionID: sessionID, readID: readID)
            guard !Task.isCancelled, ownsOperation(), configurationReadGeneration == readID else { return }
            await loadModels(forceRefresh: true, sessionID: sessionID)
            guard !Task.isCancelled, ownsOperation() else { return }
            await refreshAgentStatuses()
        } catch {
            guard !Task.isCancelled, ownsOperation(), configurationReadGeneration == readID else { return }
            errorMessage = "Failed to restore backup: \(error.localizedDescription)"
        }
    }



    func updateModelSlot(_ slot: ModelSlot, model: String) {
        // 先按旧目标识别自动名称，再切换模型；包含旧 ID 的 1M 后缀，避免它被误留为自定义标题。
        if let previousModel = currentConfiguration?.modelSlots[slot],
           AgentConfiguration.normalizedClaudeDisplayName(currentConfiguration?.claudeModelDisplayNames?[slot],
                for: slot, modelID: previousModel) == nil {
            currentConfiguration?.claudeModelDisplayNames?.removeValue(forKey: slot)
        }
        if currentConfiguration?.agent == .claudeCode {
            // 只有明确的末尾 [1m] 声明才开启上下文；型号名称本身不提供能力或启用授权。
            let reference = ClaudeModelReference(model)
            let selected = AgentConfiguration.normalizedClaudeModelID(reference.selector)
            currentConfiguration?.modelSlots[slot] = selected.base
            // 这里只保存选择值自带的显式声明；目录容量由纯计划实时投影，不能写成永久开关。
            // 普通选择移除旧槽声明而非写死 false，目录迟到或容量更新后仍能自动跟随。
            // 已保存 true/false 在回填时继续保留，本次主动换型号则重新采用自动规则。
            if selected.uses1M { currentConfiguration?.claudeModel1M[slot] = true }
            else { currentConfiguration?.claudeModel1M.removeValue(forKey: slot) }
        } else {
            currentConfiguration?.modelSlots[slot] = model
        }
    }

    func updateModelDisplayName(_ slot: ModelSlot, name: String) {
        let oldName = currentConfiguration?.claudeDisplayName(for: slot)
        if currentConfiguration?.claudeModelDisplayNames == nil {
            currentConfiguration?.claudeModelDisplayNames = [:]
        }
        currentConfiguration?.claudeModelDisplayNames?[slot] = name
        // 菜单里跟随该角色的标题同步更新；用户导入的独立标题仅在仍等于旧角色名时跟随。
        if var picker = currentConfiguration?.claudeModelPicker {
            for index in picker.options.indices where picker.options[index].selector == slot.rawValue {
                if picker.options[index].label.isEmpty || picker.options[index].label == oldName {
                    picker.options[index].label = ""
                }
            }
            currentConfiguration?.claudeModelPicker = picker
        }
    }

    func updateClaude1MContext(_ enabled: Bool, for slot: ModelSlot) {
        currentConfiguration?.claudeModel1M[slot] = enabled
    }

    /// 默认行只有直接选择时可编辑 1M，继承角色时禁止写入另一份互相冲突的状态。
    func updateClaudeDefault1MContext(_ enabled: Bool) {
        guard let config = currentConfiguration, config.claudeDefaultModelSlot == nil else { return }
        currentConfiguration?.claudeDefaultModel1M = enabled
        let parsed = AgentConfiguration.normalizedClaudeModelID(config.claudeModel)
        if !enabled, parsed.uses1M, ModelSlot(rawValue: parsed.base) != nil {
            // Claude 自身可能保存 opus[1m]；关闭的是显式覆盖，恢复普通角色继承，不改角色槽。
            currentConfiguration?.claudeModel = parsed.base
        }
    }

    /// nil 是用户明确选择“跟随 CLI”；自定义的空输入暂存为 0，由统一验证阻止保存。
    /// 配置仍由原草稿持有，不在视图或后台另建窗口状态与请求任务。
    func updateClaudeMaxContextTokens(_ tokens: Int?) {
        currentConfiguration?.claudeMaxContextTokens = tokens
    }

    func updateClaudeAutoCompactPercentage(_ percentage: Int) {
        currentConfiguration?.claudeAutoCompactPercentage = percentage
    }

    func updateClaudeDisableAutoCompact(_ disabled: Bool) {
        currentConfiguration?.claudeDisableAutoCompact = disabled
    }

    /// 仅控制网关目录的展示，不刷新或重置用户尚未保存的模型槽、名称及默认模型。
    func updateClaudeGatewayModelDiscovery(_ enabled: Bool) {
        currentConfiguration?.claudeGatewayModelDiscovery = enabled
    }

    /// 切换策略只改变展示方式，保留编辑中的条目；首次开启时补入三个角色引用。
    func updateClaudePickerMode(_ mode: ClaudeModelPickerMode) {
        if currentConfiguration?.claudeModelPicker.preservedExternalJSON != nil && mode != .external && mode != .native {
            // 无法理解的外部结构只有在用户主动重新生成菜单时才由 Quotio 接管。
            currentConfiguration?.claudeModelPicker.isQuotioManaged = true
            currentConfiguration?.claudeModelPicker.preservedExternalJSON = nil
        }
        if mode != .native && mode != .external && currentConfiguration?.claudeModelPicker.options.isEmpty == true {
            currentConfiguration?.claudeModelPicker.options = ClaudeModelPickerConfiguration.roleDefaults().options
        }
        currentConfiguration?.claudeModelPicker.mode = mode
        currentConfiguration?.claudeModelPicker.shouldWrite = true
    }

    func addClaudePickerOption() {
        // 回填菜单默认只读；旧调用方明确编辑条目时才重新开启写入，不影响普通模型槽保存。
        currentConfiguration?.claudeModelPicker.shouldWrite = true
        currentConfiguration?.claudeModelPicker.options.append(ClaudeModelPickerOption(model: ""))
    }

    /// 用稳定 UUID 定位条目，排序和异步刷新不会把输入写到另一行。
    func updateClaudePickerOption(_ option: ClaudeModelPickerOption) {
        guard let index = currentConfiguration?.claudeModelPicker.options.firstIndex(where: { $0.id == option.id }) else { return }
        currentConfiguration?.claudeModelPicker.shouldWrite = true
        // 在菜单中编辑普通角色标题时，也更新官方 _NAME，使补全和原生角色行使用同一个名称。
        if let role = ModelSlot(rawValue: option.selector),
           currentConfiguration?.claudeModelPicker.options[index].label != option.label {
            updateModelDisplayName(role, name: option.label)
        }
        currentConfiguration?.claudeModelPicker.options[index] = option
    }

    func removeClaudePickerOption(_ id: UUID) {
        // 无效身份属于空操作，不能仅因尝试删除而接管磁盘菜单。
        guard currentConfiguration?.claudeModelPicker.options.contains(where: { $0.id == id }) == true else { return }
        currentConfiguration?.claudeModelPicker.shouldWrite = true
        currentConfiguration?.claudeModelPicker.options.removeAll { $0.id == id }
    }

    func moveClaudePickerOption(_ id: UUID, by offset: Int) {
        guard var picker = currentConfiguration?.claudeModelPicker,
              let index = picker.options.firstIndex(where: { $0.id == id }),
              picker.options.indices.contains(index + offset) else { return }
        picker.options.swapAt(index, index + offset)
        picker.shouldWrite = true
        currentConfiguration?.claudeModelPicker = picker
    }

    func updateClaudeSubagentModel(_ model: String?) {
        currentConfiguration?.claudeSubagentModel = model
    }

    /// 模式选择与具体模型编辑分开，避免为了回显 inherit 而在视图构建期间修改草稿。
    /// 用户明确恢复默认规则时同时关闭强制覆盖；显式 inherit／空 FORCE 可覆盖旧 Shell，
    /// 只保存 JSON 时也不会重新继承父进程中遗留的固定模型或强制开关。
    func updateClaudeSubagentMode(_ specifiesModel: Bool) {
        guard var configuration = currentConfiguration else { return }
        if specifiesModel {
            // 重复点击“指定”保留用户已有目标；FORCE 的含义与是否指定默认模型独立。
            guard configuration.claudeSubagentSelector == nil else { return }
            configuration.claudeSubagentModel = ModelSlot.haiku.rawValue
        } else {
            // 只开启 FORCE 的历史配置也必须可由“使用默认规则”明确撤下覆盖。
            // 普通回显不经过此入口，未知的关闭原值仍仅在用户明确点击后才改变。
            guard configuration.claudeSubagentSelector != nil || configuration.claudeSubagentSettings.isForced else { return }
            configuration.claudeSubagentModel = "inherit"
            configuration.claudeSubagentModelForce = ""
        }
        currentConfiguration = configuration
    }

    /// 新增选择仍写入原配置草稿，不另建状态容器或任务；关闭的空字符串明确覆盖旧 Shell 值。
    func updateClaudeSubagentForce(_ enabled: Bool) {
        currentConfiguration?.claudeSubagentModelForce = enabled ? "1" : ""
    }

    /// Codex 需要具体模型；目录为空不再补固定型号。已保存或手填的别名无需出现在目录中，
    /// 保留离线编辑和代理自定义路由。原 Claude 菜单／版本校验继续由原属性负责。
    var configurationValidationMessage: String? {
        // 去除管理密钥兜底后，客户端 key 未就绪的草稿不可覆盖磁盘上已有的有效认证。
        // 非代理默认模式只负责恢复客户端自己的设置，不要求代理密钥。
        if selectedSetupMode == .proxy, let config = currentConfiguration,
           config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "agents.models.clientKeyRequired".localized()
        }
        // 目录型客户端首次配置依赖真实目录；加载未结束前不能用空集合提交并跳到失败结果页。
        // Claude 原生角色和 Codex 的明确模型不受此等待影响，目录 Task 与加载状态仍由本 ViewModel 持有。
        if selectedSetupMode == .proxy, selectedAgent == .openCode || selectedAgent == .factoryDroid,
           isFetchingModels {
            return "agents.models.loading".localized()
        }
        if selectedSetupMode == .proxy, selectedAgent == .codexCLI,
           let config = currentConfiguration, config.codexModel.isEmpty {
            return "agents.models.selectRequired".localized()
        }
        return claudeConfigurationValidationMessage
    }

    /// 验证在提交之前完成，避免写了 Shell 后才发现菜单必须存入 JSON。
    /// 旧版 CLI 仍可使用原生模式；不支持的菜单字段不会被当作已生效功能展示。
    var claudeConfigurationValidationMessage: String? {
        guard selectedAgent == .claudeCode, selectedSetupMode == .proxy,
              let config = currentConfiguration else { return nil }
        let operation = ClaudeConfigurationOperation(mode: configurationMode, storage: configStorageOption)
        if let tokens = config.claudeMaxContextTokens, tokens <= 0 {
            return "agents.claude.advanced.context.validation".localized()
        }
        if operation.storage == .shellOnly, let old = savedConfig?.claudeMaxContextTokens,
           old != config.claudeMaxContextTokens {
            return "agents.claude.advanced.context.requiresJSON".localized()
        }
        if config.claudeCatalogManaged {
            if isFetchingModels { return "agents.models.loading".localized() }
            if let version = status(for: .claudeCode)?.version,
               let range = version.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression),
               String(version[range]).compare("2.1.242", options: .numeric) == .orderedAscending {
                return "agents.catalog.oldVersion".localized()
            }
            if operation.storage == .shellOnly { return "agents.catalog.requiresJSON".localized() }
            if let plan = claudeCompatibilityPlan, plan.catalogCount == 0 { return "agents.models.empty".localized() }
            if let plan = claudeCompatibilityPlan, !plan.blockingReferences.isEmpty {
                return "agents.catalog.blocked".localized() + " " + plan.blockingReferences.joined(separator: ", ")
            }
        }
        // Fable 从 2.1.257 开始提供；仅在用户明确使用该角色时拦截已知旧版，旧三槽配置继续可用。
        let usesFable = config.configuredClaudeSlots.contains(.fable)
            || AgentConfiguration.normalizedClaudeModelID(config.claudeDefaultModelSelector).base == "fable"
            || AgentConfiguration.normalizedClaudeModelID(config.claudeSubagentSelector ?? "").base == "fable"
        if usesFable, let version = status(for: .claudeCode)?.version,
           let range = version.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression),
           String(version[range]).compare("2.1.257", options: .numeric) == .orderedAscending {
            return "agents.claude.fable.oldVersion".localized()
        }
        // 仅限制本次新开启的能力；已有 FORCE 原值继续保留，不能因本机降级阻止无关配置保存。
        if config.claudeSubagentSettings.isForced,
           !(savedConfig.map { ClaudeSubagentSettings(model: $0.claudeSubagentModel, force: $0.claudeSubagentModelForce).isForced } ?? false),
           let version = status(for: .claudeCode)?.version,
           let range = version.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression),
           String(version[range]).compare("2.1.257", options: .numeric) == .orderedAscending {
            return "agents.claudeSubagent.force.oldVersion".localized()
        }
        if operation.mode == .automatic && operation.storage == .shellOnly {
            if claudeCompatibilityPlan?.requiresJSONUpdate == true {
                return "agents.claudeCompatibility.requiresJSON".localized()
            }
            // 撤下已有菜单或变更 JSON 中的子代理设置，单独修改 Shell 无法完成。
            // 只检查明确需要修改 JSON 的操作，旧草稿不接管菜单的行为仍然保留。
            let removesExistingMenu = config.claudeModelPicker.mode == .native && config.claudeModelPicker.shouldWrite
                && savedConfig.map { $0.claudeModelPicker.mode != .native } == true
            if (config.claudeModelPicker.shouldWrite
                && (config.claudeModelPicker.mode == .curated || config.claudeModelPicker.mode == .append)) || removesExistingMenu {
                return "agents.claudePicker.shellOnly".localized()
            }
            if let saved = savedConfig,
               config.claudeSubagentSettings.requiresJSONUpdate(comparedTo:
                    ClaudeSubagentSettings(model: saved.claudeSubagentModel, force: saved.claudeSubagentModelForce)) {
                return "agents.claudeSubagent.requiresJSON".localized()
            }
        }
        // 未改写的已有菜单不参与新菜单校验：页面没有编辑入口，旧条目或版本限制
        // 不应阻止用户修改模型槽；若调用方明确编辑菜单，仍沿用原来的完整校验。
        guard config.claudeModelPicker.shouldWrite,
              config.claudeModelPicker.mode == .curated || config.claudeModelPicker.mode == .append else { return nil }
        if config.claudeModelPicker.options.isEmpty || config.claudeModelPicker.options.contains(where: { $0.selector.isEmpty }) {
            return "agents.claudePicker.emptyModel".localized()
        }
        if let version = status(for: .claudeCode)?.version,
           let range = version.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression),
           String(version[range]).compare("2.1.242", options: .numeric) == .orderedAscending {
            return "agents.claudePicker.oldVersion".localized()
        }
        return nil
    }

    /// 批量移到废纸篓；中途失败也重新读取列表，准确反映已完成的删除。
    /// 这里不能调用配置回填，否则会覆盖用户尚未保存的模型与名称编辑。
    func deleteBackups(_ backups: [AgentConfigurationService.BackupFile], sessionID expectedSessionID: UUID? = nil) async {
        guard !Task.isCancelled, isCurrentConfigurationSession(expectedSessionID), let agent = selectedAgent, !isDeletingBackups,
              !isConfiguring, !isLoadingConfiguration,
              backups.allSatisfy({ $0.agent == agent }) else { return }
        let sessionID = configurationSessionID
        isDeletingBackups = true
        errorMessage = nil
        defer { if isCurrentConfigurationSession(sessionID) { isDeletingBackups = false } }
        do {
            for backup in backups {
                try await configurationService.deleteBackup(backup)
            }
        } catch {
            guard !Task.isCancelled, isCurrentConfigurationSession(sessionID) else { return }
            errorMessage = String(format: "agents.backups.deleteFailed".localized(), error.localizedDescription)
        }
        guard !Task.isCancelled, isCurrentConfigurationSession(sessionID) else { return }
        let remaining = await configurationService.listBackups(agent: agent)
        guard !Task.isCancelled, isCurrentConfigurationSession(sessionID), selectedAgent == agent else { return }
        availableBackups = remaining
    }

    /// 默认模型与三个槽独立更新，切换默认项不会重写槽映射。
    func updateDefaultModel(_ model: String) {
        if selectedAgent == .claudeCode {
            // 先解析输入再写入配置，避免 optional 的修改访问期间再读取依赖该配置的目录投影。
            // 目录推导的 1M 仅进入统一计划，不能回写草稿而冻结后续目录刷新结果。
            let reference = ClaudeModelReference(model)
            currentConfiguration?.claudeModel = reference.selector
            if let config = currentConfiguration, config.claudeDefaultModelSlot == nil {
                // claudeModel 的 setter 会拆分字面 ID 与后缀；不能再从已拆分的 getter 反推，
                // 否则用户选择／旧菜单传入的 literal[1m] 会被紧接着覆盖成普通窗口。
                currentConfiguration?.claudeDefaultModel1M = reference.uses1M
            }
        } else if selectedAgent == .pi {
            // 复用单模型槽存储，但不使用 Codex 的兜底模型和思考强度。
            currentConfiguration?.modelSlots[.sonnet] = model
        } else if selectedAgent == .codexCLI {
            currentConfiguration?.codexModel = model
        }
    }

    func updateReasoningEffort(_ effort: CodexReasoningEffort) {
        currentConfiguration?.codexReasoningEffort = effort
    }

    func applyConfiguration(sessionID expectedSessionID: UUID? = nil) async {
        guard !Task.isCancelled, isCurrentConfigurationSession(expectedSessionID),
              !isConfiguring, !isLoadingConfiguration, !isDeletingBackups else { return }
        if let validation = configurationValidationMessage {
            errorMessage = validation
            return
        }
        guard !isLoadingConfiguration, let agent = selectedAgent,
              let config = currentConfiguration else { return }

        if agent == .claudeCode {
            // 恢复官方配置不使用代理窗口；不能因尚未填完的自定义草稿阻止原恢复入口。
            if config.setupMode == .proxy, let tokens = config.claudeMaxContextTokens, tokens <= 0 {
                errorMessage = "agents.claude.advanced.context.validation".localized()
                return
            }
            guard (1...100).contains(config.claudeAutoCompactPercentage) else {
                errorMessage = "agents.claude.advanced.compaction.validation".localized()
                return
            }
        }

        let sessionID = configurationSessionID
        let operationID = UUID()
        configurationOperationID = operationID
        // 保存副作用使用点击时的同一组输入，不能在网络／安装返回后重新读取另一页面的模式或 Shell。
        let mode = configurationMode
        let storage = agent == .claudeCode
            ? ClaudeConfigurationOperation(mode: mode, storage: configStorageOption).storage : configStorageOption
        let shell = detectedShell
        let models = agent == .claudeCode ? claudeCompatibilityModels : availableModels
        func ownsOperation() -> Bool {
            isCurrentConfigurationSession(sessionID) && configurationOperationID == operationID
        }
        isConfiguring = true
        defer { if ownsOperation() { isConfiguring = false } }

        var rollback: ClaudeConfigurationRollback?
        do {
            if agent == .claudeCode, config.claudeCatalogManaged, config.setupMode == .proxy {
                let previous = Set(models.map(\.id))
                // 保存前必须重新取证；仍使用原加载入口与原世代，不另建保存目录缓存。
                let loaded = await loadModels(forceRefresh: true, sessionID: sessionID)
                guard ownsOperation(), !Task.isCancelled,
                      currentConfiguration?.proxyURL == config.proxyURL, currentConfiguration?.apiKey == config.apiKey else { return }
                guard loaded else { errorMessage = "agents.models.failed".localized(); return }
                guard Set(claudeCompatibilityModels.map(\.id)) == previous else {
                    errorMessage = "agents.catalog.changed".localized(); return
                }
            }
            let currentModels = agent == .claudeCode && config.claudeCatalogManaged ? claudeCompatibilityModels : models
            let result = try await generateConfiguration(agent, config, mode,
                agent == .claudeCode ? storage : .jsonOnly, currentModels, shell)
            rollback = result.claudeRollback
            // 已授权的保存事务保持原文件→Shell→检测顺序；旧页面消失不把它改造成半途写入。
            // 页面结果与互斥的提交则必须再次核对会话，不能把旧事务结果显示在新表单。
            if mode == .automatic && result.success {
                if agent == .claudeCode, let action = result.claudeShellAction {
                    // 服务根据同一次配置操作返回动作，官方恢复同样撤下受管段；
                    // 任一 Shell 失败均进入原 JSON 回执回滚，不再由页面猜测是否应该清理。
                    switch action {
                    case .preserve: break
                    case .replace(let configuration):
                        try await shellManager.addToProfile(shell: shell, configuration: configuration, agent: agent)
                    case .remove:
                        try await shellManager.removeFromProfile(shell: shell, agent: agent)
                    }
                } else {
                    // 非 Claude 仍沿用原存储规则；旧五参数离线注入也保持兼容。
                    let shouldUpdateShell = agent.configType == .both
                        ? (storage == .shellOnly || storage == .both)
                        : agent.configType != .file
                    if agent == .claudeCode, config.claudeCatalogManaged, config.setupMode == .proxy, !shouldUpdateShell {
                        // 旧注入结果没有新动作时保留原兼容路径；生产服务始终明确返回 Shell 动作。
                        try await shellManager.removeFromProfile(shell: shell, agent: agent)
                    }
                    if let shellConfig = result.shellConfig, shouldUpdateShell {
                        try await shellManager.addToProfile(shell: shell, configuration: shellConfig, agent: agent)
                    }
                }
                await detectionService.markAsConfigured(agent)
                await refreshAgentStatuses()
            }
            guard !Task.isCancelled, ownsOperation() else { return }
            configResult = result
            if !result.success { errorMessage = result.error }
        } catch {
            if let rollback {
                do { try await configurationService.rollbackClaudeConfiguration(rollback) }
                catch {
                    guard ownsOperation() else { return }
                    errorMessage = "agents.catalog.rollbackFailed".localized() + " " + error.localizedDescription
                    return
                }
            }
            guard !Task.isCancelled, ownsOperation() else { return }
            errorMessage = error.localizedDescription
            configResult = .failure(error: error.localizedDescription)
        }
    }



    /// 失败后返回同一份草稿，保留模型选择、目录说明和高级选项；不重新回填磁盘或新建任务。
    /// 用户可继续刷新目录或修改输入，避免只能关闭弹窗后丢失本轮编辑。
    func retryConfiguration(sessionID: UUID? = nil) {
        guard isCurrentConfigurationSession(sessionID) else { return }
        configResult = nil
        errorMessage = nil
    }

    func copyRawConfigToClipboard(index: Int) {
        guard let result = configResult,
              index < result.rawConfigs.count else { return }

        let rawConfig = result.rawConfigs[index]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawConfig.content, forType: .string)
    }

    func copyAllRawConfigsToClipboard() {
        guard let result = configResult else { return }

        let allContent = result.rawConfigs.map { config in
            """
            # \(config.filename ?? "Configuration")
            # Target: \(config.targetPath ?? "N/A")

            \(config.content)
            """
        }.joined(separator: "\n\n---\n\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allContent, forType: .string)
    }

    // 模型读取与连接探测走共享只读业务；本类原表单、回填 Task、加载互斥和失败兜底仍在原入口维护。
    func testConnection(sessionID expectedSessionID: UUID? = nil) async {
        guard !Task.isCancelled, isCurrentConfigurationSession(expectedSessionID), selectedAgent != nil,
              let config = currentConfiguration else { return }
        let sessionID = configurationSessionID
        let requestedAgent = selectedAgent
        let requestID = UUID()
        connectionRequestID = requestID
        // 连接探测沿用原状态宿主，连续测试采用最后一次请求；旧 defer 不能释放新请求。
        defer {
            if isCurrentConfigurationSession(sessionID), connectionRequestID == requestID { isTesting = false }
        }
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            testResult = ConnectionTestResult(success: false, message: "agents.models.clientKeyRequired".localized(),
                latencyMs: nil, modelResponded: nil)
            return
        }
        isTesting = true
        let result = await probeConnection(config.proxyURL, config.apiKey)
        guard !Task.isCancelled, isCurrentConfigurationSession(sessionID), connectionRequestID == requestID,
              selectedAgent == requestedAgent, currentConfiguration?.proxyURL == config.proxyURL, currentConfiguration?.apiKey == config.apiKey else { return }
        testResult = result
    }

    func generatePreviewConfig(sessionID expectedSessionID: UUID? = nil) async -> AgentConfigResult? {
        guard !Task.isCancelled, isCurrentConfigurationSession(expectedSessionID), let agent = selectedAgent,
              !isLoadingConfiguration, let config = currentConfiguration else { return nil }

        let sessionID = configurationSessionID
        do {
            let models = agent == .claudeCode ? claudeCompatibilityModels : availableModels
            let shell = detectedShell
            let operation = ClaudeConfigurationOperation(mode: .manual, storage: configStorageOption)
            let result = try await generateConfiguration(agent, config, operation.mode, operation.storage, models, shell)
            guard !Task.isCancelled, isCurrentConfigurationSession(sessionID), currentConfiguration == config,
                  !isLoadingConfiguration, selectedAgent == agent, detectedShell == shell,
                  (agent == .claudeCode ? claudeCompatibilityModels : availableModels) == models else { return nil }
            return result
        } catch {
            return nil
        }
    }

    func dismissConfiguration(sessionID: UUID? = nil) {
        guard isCurrentConfigurationSession(sessionID) else { return }
        configurationSessionID = UUID()
        configurationReadGeneration = UUID()
        configurationLoadTask?.cancel()
        isDeletingBackups = false
        // 关闭后使所有未完成目录读取失效；已保存配置不受影响，下一次打开重新读取当前服务。
        modelLoadGeneration = UUID()
        availableModels = []
        modelLoadMessage = nil
        isFetchingModels = false
        isLoadingConfiguration = false
        selectedAgent = nil
        configResult = nil
        testResult = nil
        currentConfiguration = nil
        errorMessage = nil
        selectedRawConfigIndex = 0
        isConfiguring = false
        isTesting = false
        savedConfig = nil
        availableBackups = []
        selectedSetupMode = .proxy
    }

    func resetSheetState(sessionID: UUID? = nil) {
        guard isCurrentConfigurationSession(sessionID) else { return }
        configResult = nil
        testResult = nil
        selectedRawConfigIndex = 0
        configurationMode = .automatic
        configStorageOption = .jsonOnly
        // onAppear 不解除正在进行的保存／测试互斥；首次与重开由 startConfiguration 统一初始化。
        // 模式由 startConfiguration 初始化、磁盘回填恢复；onAppear 不再重置，避免快回填被改回代理模式。
        // 不清理正在读取的目录；onAppear 只重置表单显示，不能使 startConfiguration 的请求失效。
        // Don't reset savedConfig/availableBackups - they persist while sheet is open
    }

    /// 每次显式读取当前服务实际暴露的目录，不注入内置型号；forceRefresh 保留原调用签名，
    /// 当前没有额外模型缓存，普通加载与手动刷新都发起真实请求。选择、槽位及凭据不随目录变更。
    @discardableResult
    func loadModels(forceRefresh: Bool = false, sessionID expectedSessionID: UUID? = nil) async -> Bool {
        // 旧页面排队的 Task 可能尚未启动且从未被取消；先验所属页面，再碰新草稿或请求令牌。
        guard !Task.isCancelled, isCurrentConfigurationSession(expectedSessionID) else { return false }
        let sessionID = configurationSessionID
        loadedModelSource = nil
        // 打开弹窗时客户端 key 可能仍在原刷新流程中；用户重试后补用已就绪的 key，
        // 同步回原草稿才能保证目录读取与最终写出的认证一致。已有明确 key 不覆盖。
        if usesCPAModelService,
           currentConfiguration?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true,
           let key = quotaViewModel?.apiKeys.first, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            currentConfiguration?.apiKey = key
        }
        guard let config = modelRequestConfiguration() else {
            // 密钥尚未就绪也必须结束旧加载，不能沿用上一服务目录或发送管理密钥试探。
            modelLoadGeneration = UUID()
            availableModels = []
            isFetchingModels = false
            modelLoadMessage = "agents.models.failed".localized()
            return false
        }
        let requestedAgent = selectedAgent
        // 来源补充仅限已确认同一 CPA 的 Claude 页面，外部服务不能借用本机管理客户端。
        // 仍在原 loadModels 的结构化调用中完成，原世代覆盖目录和来源整轮提交。
        let usesCPASource = requestedAgent == .claudeCode && usesCPAModelService
        let sourceClient = usesCPASource ? quotaViewModel?.apiClient : nil
        let generation = UUID()
        modelLoadGeneration = generation
        isFetchingModels = true
        availableModels = []
        modelLoadMessage = nil
        defer {
            // 旧请求不得清除新一轮的加载状态，也不能在重新打开同一客户端时回写候选。
            if isCurrentConfigurationSession(sessionID), modelLoadGeneration == generation { isFetchingModels = false }
        }

        func isCurrentRequest() -> Bool {
            guard !Task.isCancelled, isCurrentConfigurationSession(sessionID), modelLoadGeneration == generation,
                  selectedAgent == requestedAgent, let current = modelRequestConfiguration() else { return false }
            return current.proxyURL == config.proxyURL && current.apiKey == config.apiKey
                && (!usesCPASource || sourceClient === quotaViewModel?.apiClient)
        }

        do {
            var selection = try await fetchModels(config.proxyURL, config.apiKey)
            guard isCurrentRequest() else { return false }
            if let sourceClient {
                do { selection = try await AgentModelSourceCatalog.enrich(selection, client: sourceClient) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    // 模型目录已成功时，辅助来源读取失败不伪造账号，也不把可用目录整体清空。
                    // 统一展示规则会回退到明确的目录归属或“来源未标明”。
                    logger.debug("[AgentSetupViewModel] CPA model source metadata unavailable")
                }
            }
            guard isCurrentRequest() else { return false }
            loadedModelSource = (sessionID, requestedAgent, config.proxyURL, config.apiKey, selection.catalog)
            availableModels = processModels(selection.candidates)
            if availableModels.isEmpty { modelLoadMessage = "agents.models.empty".localized() }
            logger.debug("[AgentSetupViewModel] Loaded \(self.availableModels.count) models from current service")
            return true
        } catch {
            guard isCurrentRequest() else { return false }
            // 保留配置中的旧模型／角色与手填入口；失败不等价于服务提供了一组默认型号。
            logger.error("[AgentSetupViewModel] Failed to load models: \(error.localizedDescription)")
            modelLoadMessage = "agents.models.failed".localized()
            return false
        }
    }

    /// Builds the configuration used to talk to `/v1/models`.
    ///
    /// Returns `nil` when there is no configuration and no proxy manager to derive
    /// one from — the same condition under which `loadModels(forceRefresh:)`
    /// previously returned `false` without attempting a request.
    private func modelRequestConfiguration() -> AgentConfiguration? {
        // Reuse the sheet's configuration when one exists (agent-setup scenarios)
        if let existingConfig = currentConfiguration {
            guard !existingConfig.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return existingConfig
        }

        // Create a config when loading models outside the agent setup sheet.
        guard let proxyManager = proxyManager else { return nil }

        // 客户端目录与 v8 管理端点的认证边界独立；无客户端密钥时等待原 API Key 加载流程，
        // 不能拿高权限 managementKey 回退请求 /v1/models。配置弹窗已明确提供的 key 仍优先沿用。
        guard let apiKey = quotaViewModel?.apiKeys.first, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        // Use tunnel URL if active, otherwise use local proxy endpoint
        let modelEndpoint: String
        if let tunnelURL = TunnelManager.shared.tunnelState.publicURL {
            modelEndpoint = tunnelURL
        } else {
            modelEndpoint = proxyManager.baseURL
        }

        return AgentConfiguration(
            agent: .claudeCode,
            proxyURL: modelEndpoint + "/v1",
            apiKey: apiKey
        )
    }

    /// Fetches the proxy's `/v1/models` catalog exactly as the endpoint reported it.
    ///
    /// This is the read-only counterpart to `loadModels(forceRefresh:)`.
    /// 实时目录和配置候选均不使用静态兜底；Pi 保存前仍使用自己的实时查证流程。
    ///
    /// This method performs no fallback, reads and writes no cached state, and does
    /// not touch `availableModels`, so existing `loadModels` consumers are unaffected.
    /// Errors propagate so the caller can distinguish a failure from an empty catalog.
    func fetchModelCatalog() async throws -> [ModelCatalogEntry] {
        guard let config = modelRequestConfiguration() else {
            throw ModelCatalogError.proxyUnavailable
        }
        return try await AgentModelCatalogService.fetchModelCatalog(proxyURL: config.proxyURL, apiKey: config.apiKey)
    }

    func processModels(_ fetchedModels: [AvailableModel]) -> [AvailableModel] {
        // 只排序实际返回的候选，空目录如实为空；不以型号白名单过滤历史 ID 或自定义别名。
        return fetchedModels.sorted { $0.displayName < $1.displayName }
    }

    /// 账号变更只影响同一 CPA 服务。严格比较目录 URL，不能按域名／前缀把外部服务或另一个端口算进来。
    func usesModelService(_ baseURLs: [String]) -> Bool {
        guard selectedAgent != nil, let configuration = currentConfiguration,
              let current = ModelCatalogClient.modelsURL(baseURL: configuration.proxyURL) else { return false }
        return baseURLs.contains {
            ModelCatalogClient.modelsURL(baseURL: $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1") == current
        }
    }

    var usesCPAModelService: Bool {
        guard let url = currentConfiguration?.proxyURL else { return false }
        return isCPAModelServiceURL(url)
    }

    /// 仅用当前已知 CPA 来源作精确目录 URL 比较；不会因 host 相同或端口相近就共享认证。
    /// 本方法不依赖 selectedAgent，供初次回填恢复原来源时复用，不生成缓存或第二份连接状态。
    private func isCPAModelServiceURL(_ url: String) -> Bool {
        guard let target = ModelCatalogClient.modelsURL(baseURL: url) else { return false }
        var endpoints: [String] = []
        if let proxyManager {
            endpoints.append(proxyManager.baseURL)
            if let publicURL = TunnelManager.shared.tunnelState.publicURL { endpoints.append(publicURL) }
        }
        if let endpoint = configurationEndpoint?() { endpoints.append(endpoint) }
        return endpoints.contains {
            ModelCatalogClient.modelsURL(baseURL: ClaudeConfigurationSource.modelAPIBaseURL($0)) == target
        }
    }

    /// 原 CPA 客户端退出或替换时同步撤销整轮读取和排队提交许可；不能等迟到网络返回再拒绝。
    /// 外部服务表单继续持有自己的目录和草稿，不受本机 CPA 生命周期影响。
    func invalidateCPAModelSource() {
        guard selectedAgent == nil || usesCPAModelService else { return }
        modelLoadGeneration = UUID()
        loadedModelSource = nil
        availableModels = []
        isFetchingModels = false
        if selectedAgent != nil { modelLoadMessage = "agents.models.accountsChanged".localized() }
    }

    #if DEBUG
    /// 只读暴露已有许可供离线排队事务回归检查；不增加测试状态，不开放配置提交或私有 setter。
    func managedCatalogAuthorizationForTesting() -> ClaudeCatalogCommitAuthorization? { managedCatalogAuthorization }
    #endif

    /// 本次账号变更的瞬时令牌复用原请求世代；不新增可变状态、Task 或缓存所有者。
    struct AccountModelReload: Sendable {
        let sessionID: UUID
        let generation: UUID
        let agent: CLIAgent?
        let url: String
        let key: String
    }

    func invalidateModelsForAccountChange(serviceBaseURLs: [String]) -> AccountModelReload? {
        guard !Task.isCancelled else { return nil }
        // 关闭页也可能有受管菜单同步在途。账号变更一经确认就推进原世代，不能等下一轮同步
        // 真正开始才作废旧目录；页面草稿仅在同源打开时清理，外部服务表单继续保持原样。
        if selectedAgent == nil { modelLoadGeneration = UUID(); return nil }
        guard usesModelService(serviceBaseURLs), let config = currentConfiguration else { return nil }
        modelLoadGeneration = UUID()
        loadedModelSource = nil
        availableModels = []
        isFetchingModels = false
        modelLoadMessage = "agents.models.accountsChanged".localized()
        return AccountModelReload(sessionID: configurationSessionID, generation: modelLoadGeneration,
                                  agent: selectedAgent, url: config.proxyURL, key: config.apiKey)
    }

    @discardableResult
    func reloadModelsAfterAccountChange(_ reload: AccountModelReload) async -> Bool {
        guard !Task.isCancelled, isCurrentConfigurationSession(reload.sessionID),
              modelLoadGeneration == reload.generation, selectedAgent == reload.agent,
              currentConfiguration?.proxyURL == reload.url, currentConfiguration?.apiKey == reload.key else { return false }
        // 用户已手动刷新、关闭重开或切换服务时不再追加读取，原 loadModels 仍负责完整的迟到响应校验。
        return await loadModels(forceRefresh: true, sessionID: reload.sessionID)
    }


    /// 已接管目录的后续同步复用原 VM、目录读取依赖和请求世代；不创建后台轮询。
    /// 配置页打开时保留未保存草稿，由现有保存按钮统一提交；关闭后才同步磁盘中的受管配置。
    func synchronizeManagedClaudeCatalog(serviceBaseURLs: [String], canCommit: @MainActor () -> Bool) async -> String? {
        guard selectedAgent == nil, canCommit(), !Task.isCancelled else { return nil }
        let generation = UUID()
        modelLoadGeneration = generation
        // 从首次挂起前固定来源；模型目录返回后才取 client 会把旧目录与新账号注册信息拼接。
        let sourceClient = quotaViewModel?.apiClient
        func isCurrentSource() -> Bool {
            modelLoadGeneration == generation && selectedAgent == nil && canCommit() && !Task.isCancelled
                && sourceClient === quotaViewModel?.apiClient
        }
        let authorization = ClaudeCatalogCommitAuthorization()
        managedCatalogAuthorization = authorization
        defer {
            authorization.invalidate()
            if modelLoadGeneration == generation { managedCatalogAuthorization = nil }
        }
        guard let config = await configurationService.managedClaudeConfiguration(serviceBaseURLs: serviceBaseURLs),
              isCurrentSource() else { return nil }
        do {
            var selection = try await fetchModels(config.proxyURL, config.apiKey)
            guard isCurrentSource() else { return nil }
            // 关闭配置页后的账号联动沿用同一来源投影，避免下一轮同步又退回重复 ID。
            if let client = sourceClient {
                do { selection = try await AgentModelSourceCatalog.enrich(selection, client: client) }
                catch is CancellationError { throw CancellationError() }
                catch { logger.debug("[AgentSetupViewModel] Background CPA model source metadata unavailable") }
                guard client === quotaViewModel?.apiClient else { return nil }
            }
            guard isCurrentSource() else { return nil }
            let result = await configurationService.synchronizeManagedClaudeCatalog(
                sourceID: ClaudeConfigurationPlan.sourceID(url: config.proxyURL, key: config.apiKey),
                serviceBaseURLs: serviceBaseURLs, models: selection.catalog, authorization: authorization)
            guard modelLoadGeneration == generation, selectedAgent == nil, canCommit() else { return nil }
            return result?.success == false ? result?.error : nil
        } catch {
            guard modelLoadGeneration == generation, selectedAgent == nil, canCommit() else { return nil }
            return "agents.models.failed".localized()
        }
    }

    // MARK: - Lifecycle: Update & Uninstall

    /// 针对特定智能体状态检测远程最新版本（自动区分 Homebrew Cask、Homebrew Formula 与 npm/pnpm/bun 渠道）
    func checkForUpdate(for status: AgentStatus) async {
        let agent = status.agent
        isCheckingUpdates[agent] = true
        defer { isCheckingUpdates[agent] = false }

        do {
            let remoteVersion: String
            switch status.installMethod {
            case .homebrewCask(let caskName):
                remoteVersion = try await fetchBrewCaskLatestVersion(caskName: caskName)
            case .homebrewFormula(let formulaName):
                remoteVersion = try await fetchBrewFormulaLatestVersion(formulaName: formulaName)
            case .npm(let pkg), .pnpm(let pkg), .bun(let pkg):
                remoteVersion = try await fetchNpmLatestVersion(packageName: pkg)
            case .standalone, .unknown:
                if let pkg = agent.npmPackageName {
                    remoteVersion = try await fetchNpmLatestVersion(packageName: pkg)
                } else {
                    updateMessages[agent] = "agents.update.noSource".localized()
                    return
                }
            }

            remoteVersions[agent] = remoteVersion
            let cleanRemote = Self.cleanVersionString(remoteVersion)
            if let current = status.version, !current.isEmpty {
                let cleanCurrent = Self.cleanVersionString(current)
                let comparison = cleanRemote.compare(cleanCurrent, options: .numeric)
                if comparison == .orderedDescending {
                    updateMessages[agent] = String(format: "agents.updateAvailable".localized(), remoteVersion)
                } else {
                    updateMessages[agent] = "agents.latestVersion".localized()
                }
            } else {
                updateMessages[agent] = String(format: "agents.updateAvailable".localized(), remoteVersion)
            }
        } catch {
            updateMessages[agent] = "agents.checkUpdate.failed".localized() + ": \(error.localizedDescription)"
        }
    }

    /// 兼容重载：按 CLIAgent 查询当前状态后检测
    func checkForUpdate(for agent: CLIAgent) async {
        if let current = status(for: agent) {
            await checkForUpdate(for: current)
        } else if let pkg = agent.npmPackageName {
            isCheckingUpdates[agent] = true
            defer { isCheckingUpdates[agent] = false }
            if let ver = try? await fetchNpmLatestVersion(packageName: pkg) {
                remoteVersions[agent] = ver
                updateMessages[agent] = String(format: "agents.updateAvailable".localized(), ver)
            }
        }
    }

    /// 清理并提取版本号字符串（提取语义版本主干，如 "2.1.292" 或 "0.85.1"，过滤前缀与附加描述文本）
    static func cleanVersionString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) {
            return String(trimmed[range])
        }
        var str = trimmed
        if str.lowercased().hasPrefix("v") {
            str.removeFirst()
        }
        if let first = str.components(separatedBy: " ").first {
            str = first
        }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 判断是否检测到比本地更高的远程版本（仅在远程版本严格高于当前已安装版本时返回 true）
    func hasNewerVersion(for status: AgentStatus) -> Bool {
        guard let remote = remoteVersions[status.agent], !remote.isEmpty else { return false }
        guard let current = status.version, !current.isEmpty else { return false }
        let cleanRemote = Self.cleanVersionString(remote)
        let cleanCurrent = Self.cleanVersionString(current)
        guard !cleanRemote.isEmpty && !cleanCurrent.isEmpty else { return false }
        return cleanRemote.compare(cleanCurrent, options: .numeric) == .orderedDescending
    }

    /// 查询 Homebrew Cask 官方 API (formulae.brew.sh)
    private func fetchBrewCaskLatestVersion(caskName: String) async throws -> String {
        let urlString = "https://formulae.brew.sh/api/cask/\(caskName).json"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = json["version"] as? String {
            return version
        }
        throw URLError(.cannotParseResponse)
    }

    /// 查询 Homebrew Formula 官方 API (formulae.brew.sh)
    private func fetchBrewFormulaLatestVersion(formulaName: String) async throws -> String {
        let urlString = "https://formulae.brew.sh/api/formula/\(formulaName).json"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let versions = json["versions"] as? [String: Any],
           let stable = versions["stable"] as? String {
            return stable
        }
        throw URLError(.cannotParseResponse)
    }

    /// 查询 NPM Registry 官方 API
    private func fetchNpmLatestVersion(packageName: String) async throws -> String {
        let urlString = "https://registry.npmjs.org/\(packageName)/latest"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = json["version"] as? String {
            return version
        }
        throw URLError(.cannotParseResponse)
    }

    /// 升级智能体：根据实际安装渠道（Homebrew / npm / bun 等）在终端中运行适配的升级命令
    func upgradeAgent(_ status: AgentStatus) async {
        let command = status.upgradeCommand
        guard !command.isEmpty else {
            updateMessages[status.agent] = "agents.update.manualSource".localized(); return
        }
        do { try await launchCommand(command) }
        catch { updateMessages[status.agent] = error.localizedDescription; return }

        // 启动后台轮询任务，在命令执行一段时间后自动刷新状态，展示最新版本
        scheduleAutoRefresh(agent: status.agent, intervals: [3, 8, 15])
    }

    /// 兼容重载
    func upgradeAgent(_ agent: CLIAgent) async {
        if let current = status(for: agent) {
            await upgradeAgent(current)
        } else {
            // 兼容入口也不能绕过渠道确认；未探测到入口不等于已知 npm 安装。
            updateMessages[agent] = "agents.update.manualSource".localized()
        }
    }

    /// 卸载智能体：根据实际安装渠道（Homebrew / npm / bun 等）在终端中运行适配的卸载命令
    func uninstallAgent(_ status: AgentStatus) async {
        let command = status.uninstallCommand
        guard !command.isEmpty else {
            updateMessages[status.agent] = "agents.update.manualSource".localized(); return
        }

        // 拉起终端不代表卸载成功，不能提前清配置偏好和 lastConfigured；即使真正卸载，
        // 用户配置也继续保留以便重装。原轮询只负责重新探测 installed 状态。
        do { try await launchCommand(command) }
        catch { updateMessages[status.agent] = error.localizedDescription; return }

        // 启动后台轮询，卸载完成后自动把卡片迁移至“未安装”列表
        scheduleAutoRefresh(agent: status.agent, intervals: [2, 5, 9, 14])
    }

    /// 兼容重载
    func uninstallAgent(_ agent: CLIAgent) async {
        if let current = status(for: agent) {
            await uninstallAgent(current)
        } else {
            updateMessages[agent] = "agents.update.manualSource".localized()
        }
    }

    /// 安装智能体：在终端中运行推荐安装命令
    func installAgent(_ agent: CLIAgent) async {
        let command = agent.recommendedInstallCommand
        guard !command.isEmpty else { return }
        try? await TerminalLauncher.shared.launch(command: command)
        scheduleAutoRefresh(agent: agent, intervals: [3, 8, 15, 25])
    }

    private func scheduleAutoRefresh(agent: CLIAgent, intervals: [Int]) {
        Task { [weak self] in
            for sec in intervals {
                try? await Task.sleep(nanoseconds: UInt64(sec) * 1_000_000_000)
                guard let self else { return }
                await self.detectionService.invalidateCache()
                await self.refreshAgentStatuses(forceRefresh: true)
            }
        }
    }
}
