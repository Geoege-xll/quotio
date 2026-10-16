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
    private let shellManager = ShellProfileManager()
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
    private var modelLoadGeneration = UUID()
    private let fetchModels: @Sendable (String, String) async throws -> [AvailableModel]
    /// 弹窗身份与单次目录请求分别计数：同一客户端关闭重开也必须是不同会话。
    /// 身份、操作令牌仍归原 ViewModel；页面仅捕获不可变 UUID，不持有第二份业务状态或 Task。
    private(set) var configurationSessionID = UUID()
    private var configurationReadGeneration = UUID()
    private var configurationOperationID = UUID()
    private var connectionRequestID = UUID()
    private let configurationEndpoint: (@MainActor () -> String?)?
    private let readConfiguration: @Sendable (CLIAgent) async -> AgentConfigurationService.SavedAgentConfig?
    private let probeConnection: @Sendable (String, String) async -> ConnectionTestResult
    private let generateConfiguration: @Sendable (CLIAgent, AgentConfiguration, ConfigurationMode, ConfigStorageOption, [AvailableModel]) async throws -> AgentConfigResult

    var currentConfiguration: AgentConfiguration?
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
         fetchModels: @escaping @Sendable (String, String) async throws -> [AvailableModel] = { url, key in
             try await AgentModelCatalogService.fetchAvailableModels(proxyURL: url, apiKey: key)
         },
         configurationEndpoint: (@MainActor () -> String?)? = nil,
         readConfiguration: (@Sendable (CLIAgent) async -> AgentConfigurationService.SavedAgentConfig?)? = nil,
         probeConnection: @escaping @Sendable (String, String) async -> ConnectionTestResult = { url, key in
             await AgentModelCatalogService.testConnection(proxyURL: url, apiKey: key)
         },
         generateConfiguration: (@Sendable (CLIAgent, AgentConfiguration, ConfigurationMode, ConfigStorageOption, [AvailableModel]) async throws -> AgentConfigResult)? = nil,
         launchCommand: @escaping @MainActor (String) async throws -> Void = { try await TerminalLauncher.shared.launch(command: $0) }) {
        let detector = AgentDetectionService()
        self.detectionService = detector
        self.configurationService = configurationService
        self.fetchModels = fetchModels
        self.configurationEndpoint = configurationEndpoint
        // 只读／执行依赖默认仍复用原 actor 与检测器；注入仅用于显式挂起迟到响应的离线验证。
        self.readConfiguration = readConfiguration ?? { await configurationService.readConfiguration(agent: $0) }
        self.probeConnection = probeConnection
        self.generateConfiguration = generateConfiguration ?? { agent, config, mode, storage, models in
            try await configurationService.generateConfiguration(agent: agent, config: config, mode: mode,
                storageOption: storage, detectionService: detector, availableModels: models)
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

        agentStatuses = await detectionService.detectAllAgents(forceRefresh: forceRefresh)
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
            // Fable 是新增可选槽，旧三槽备份中没有这个键就代表没有固定映射。
            // 恢复操作复用当前表单，必须同步删除缺失值，防止下一次保存把恢复前的 Fable 写回磁盘。
            currentConfiguration?.modelSlots[.fable] = saved.modelSlots[.fable]
        }
        for (slot, model) in saved.modelSlots {
            currentConfiguration?.modelSlots[slot] = model
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
        guard !Task.isCancelled, isCurrentConfigurationSession(expectedSessionID), selectedAgent == backup.agent else { return }
        let sessionID = configurationSessionID
        let agent = backup.agent
        let readID = UUID()
        configurationReadGeneration = readID
        do {
            // 已确认的文件恢复仍交给原 actor；恢复完成后只能回填发起它的页面，不选取此时的新客户端。
            try await configurationService.restoreFromBackup(backup)
            guard !Task.isCancelled, isCurrentConfigurationSession(sessionID), configurationReadGeneration == readID else { return }
            await loadExistingConfiguration(for: agent, sessionID: sessionID, readID: readID)
            guard !Task.isCancelled, isCurrentConfigurationSession(sessionID), configurationReadGeneration == readID else { return }
            await refreshAgentStatuses()
        } catch {
            guard !Task.isCancelled, isCurrentConfigurationSession(sessionID), configurationReadGeneration == readID else { return }
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
            // 目录或手动选择可能直接给出 model[1m]；将后缀转成该槽的独立开关，
            // 否则请求 ID 生成时会规范化掉后缀，造成界面选中 1M、实际却写入普通模型。
            let selected = AgentConfiguration.normalizedClaudeModelID(model)
            currentConfiguration?.modelSlots[slot] = selected.base
            if selected.uses1M {
                currentConfiguration?.claudeModel1M[slot] = true
            }
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

    func updateClaudeMaxContextTokens(_ tokens: Int) {
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
        // Fable 从 2.1.257 开始提供；仅在用户明确使用该角色时拦截已知旧版，旧三槽配置继续可用。
        let usesFable = config.configuredClaudeSlots.contains(.fable)
            || AgentConfiguration.normalizedClaudeModelID(config.claudeDefaultModelSelector).base == "fable"
            || AgentConfiguration.normalizedClaudeModelID(config.claudeSubagentSelector ?? "").base == "fable"
        if usesFable, let version = status(for: .claudeCode)?.version,
           let range = version.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression),
           String(version[range]).compare("2.1.257", options: .numeric) == .orderedAscending {
            return "agents.claude.fable.oldVersion".localized()
        }
        if configurationMode == .automatic && configStorageOption == .shellOnly {
            // 撤下已有菜单或移除 JSON 中的固定子代理，单独 unset Shell 无法完成。
            // 只检查明确需要修改 JSON 的操作，旧草稿不接管菜单的行为仍然保留。
            let removesExistingMenu = config.claudeModelPicker.mode == .native && config.claudeModelPicker.shouldWrite
                && savedConfig.map { $0.claudeModelPicker.mode != .native } == true
            if (config.claudeModelPicker.shouldWrite
                && (config.claudeModelPicker.mode == .curated || config.claudeModelPicker.mode == .append)) || removesExistingMenu {
                return "agents.claudePicker.shellOnly".localized()
            }
            if savedConfig?.claudeSubagentModel != nil && config.claudeSubagentSelector == nil {
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
            currentConfiguration?.claudeModel = model
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
        guard !Task.isCancelled, isCurrentConfigurationSession(expectedSessionID), !isConfiguring else { return }
        if let validation = configurationValidationMessage {
            errorMessage = validation
            return
        }
        guard !isLoadingConfiguration, let agent = selectedAgent,
              let config = currentConfiguration else { return }

        if agent == .claudeCode {
            guard config.claudeMaxContextTokens > 0 else {
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
        let storage = configStorageOption
        let shell = detectedShell
        let models = availableModels
        func ownsOperation() -> Bool {
            isCurrentConfigurationSession(sessionID) && configurationOperationID == operationID
        }
        isConfiguring = true
        defer { if ownsOperation() { isConfiguring = false } }

        do {
            let result = try await generateConfiguration(agent, config, mode,
                agent == .claudeCode ? storage : .jsonOnly, models)
            // 已授权的保存事务保持原文件→Shell→检测顺序；旧页面消失不把它改造成半途写入。
            // 页面结果与互斥的提交则必须再次核对会话，不能把旧事务结果显示在新表单。
            if mode == .automatic && result.success {
                let shouldUpdateShell = agent.configType == .both
                    ? (storage == .shellOnly || storage == .both)
                    : agent.configType != .file
                if let shellConfig = result.shellConfig, shouldUpdateShell {
                    try await shellManager.addToProfile(shell: shell, configuration: shellConfig, agent: agent)
                }
                await detectionService.markAsConfigured(agent)
                await refreshAgentStatuses()
            }
            guard !Task.isCancelled, ownsOperation() else { return }
            configResult = result
            if !result.success { errorMessage = result.error }
        } catch {
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
              let config = currentConfiguration else { return nil }

        let sessionID = configurationSessionID
        do {
            let result = try await generateConfiguration(agent, config, .manual, .jsonOnly, availableModels)
            guard !Task.isCancelled, isCurrentConfigurationSession(sessionID) else { return nil }
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
        // 打开弹窗时客户端 key 可能仍在原刷新流程中；用户重试后补用已就绪的 key，
        // 同步回原草稿才能保证目录读取与最终写出的认证一致。已有明确 key 不覆盖。
        if currentConfiguration?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true,
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
        }

        do {
            let fetchedModels = try await fetchModels(config.proxyURL, config.apiKey)
            guard isCurrentRequest() else { return false }
            availableModels = processModels(fetchedModels)
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
