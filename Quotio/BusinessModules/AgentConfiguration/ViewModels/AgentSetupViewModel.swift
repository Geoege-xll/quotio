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
    private let detectionService = AgentDetectionService()
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
         launchCommand: @escaping @MainActor (String) async throws -> Void = { try await TerminalLauncher.shared.launch(command: $0) }) {
        self.configurationService = configurationService
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

    func startConfiguration(for agent: CLIAgent, apiKey: String) {
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

        guard let proxyManager = proxyManager else {
            errorMessage = "Proxy manager not available"
            return
        }

        selectedAgent = agent
        isLoadingConfiguration = true

        // Use tunnel URL if active, otherwise use local proxy endpoint
        let endpoint: String
        if let tunnelURL = TunnelManager.shared.tunnelState.publicURL {
            endpoint = tunnelURL
        } else {
            endpoint = proxyManager.baseURL
        }

        // Create configuration with defaults first
        currentConfiguration = AgentConfiguration(
            agent: agent,
            proxyURL: endpoint + "/v1",
            apiKey: apiKey,
            setupMode: selectedSetupMode
        )

        // Cancel any previous configuration load task to prevent race conditions
        configurationLoadTask?.cancel()
        
        // Then load existing config, apply saved values, and load models - all in sequence
        configurationLoadTask = Task { [weak self] in
            guard let self else { return }
            
            await self.loadExistingConfiguration(for: agent)
            
            // Guard that selectedAgent still matches after async work
            guard !Task.isCancelled, self.selectedAgent == agent else { return }
            self.isLoadingConfiguration = false
            await self.loadModels()
        }
    }
    
    /// Load existing configuration from agent's config files and apply to current configuration
    private func loadExistingConfiguration(for agent: CLIAgent) async {
        // Read saved configuration
        let loadedConfig = await configurationService.readConfiguration(agent: agent)
        let loadedBackups = await configurationService.listBackups(agent: agent)
        // 每次挂起后确认仍在配置原代理，避免关闭或切换页面后的结果污染新表单。
        guard !Task.isCancelled, selectedAgent == agent else { return }
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
    func restoreFromBackup(_ backup: AgentConfigurationService.BackupFile) async {
        do {
            try await configurationService.restoreFromBackup(backup)
            
            // Reload configuration after restore
            if let agent = selectedAgent {
                await loadExistingConfiguration(for: agent)
                await refreshAgentStatuses()
            }
        } catch {
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
    func deleteBackups(_ backups: [AgentConfigurationService.BackupFile]) async {
        guard let agent = selectedAgent, !isDeletingBackups,
              backups.allSatisfy({ $0.agent == agent }) else { return }
        isDeletingBackups = true
        errorMessage = nil
        defer { isDeletingBackups = false }
        do {
            for backup in backups {
                try await configurationService.deleteBackup(backup)
            }
        } catch {
            errorMessage = String(format: "agents.backups.deleteFailed".localized(), error.localizedDescription)
        }
        let remaining = await configurationService.listBackups(agent: agent)
        guard selectedAgent == agent else { return }
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

    func applyConfiguration() async {
        if let validation = claudeConfigurationValidationMessage {
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

        isConfiguring = true
        defer { isConfiguring = false }

        do {
            let result = try await configurationService.generateConfiguration(
                agent: agent,
                config: config,
                mode: configurationMode,
                storageOption: agent == .claudeCode ? configStorageOption : .jsonOnly,
                detectionService: detectionService,
                availableModels: availableModels
            )

            if configurationMode == .automatic && result.success {
                let shouldUpdateShell = agent.configType == .both
                    ? (configStorageOption == .shellOnly || configStorageOption == .both)
                    : agent.configType != .file

                if let shellConfig = result.shellConfig, shouldUpdateShell {
                    try await shellManager.addToProfile(
                        shell: detectedShell,
                        configuration: shellConfig,
                        agent: agent
                    )
                }

                await detectionService.markAsConfigured(agent)
                await refreshAgentStatuses()
            }

            configResult = result

            if !result.success {
                errorMessage = result.error
            }
        } catch {
            errorMessage = error.localizedDescription
            configResult = .failure(error: error.localizedDescription)
        }
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
    func testConnection() async {
        guard selectedAgent != nil,
              let config = currentConfiguration else { return }

        isTesting = true
        defer { isTesting = false }

        testResult = await AgentModelCatalogService.testConnection(
            proxyURL: config.proxyURL,
            apiKey: config.apiKey
        )
    }

    func generatePreviewConfig() async -> AgentConfigResult? {
        guard let agent = selectedAgent,
              let config = currentConfiguration else { return nil }

        do {
            return try await configurationService.generateConfiguration(
                agent: agent,
                config: config,
                mode: .manual,
                detectionService: detectionService,
                availableModels: availableModels
            )
        } catch {
            return nil
        }
    }

    func dismissConfiguration() {
        configurationLoadTask?.cancel()
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

    func resetSheetState() {
        configResult = nil
        testResult = nil
        selectedRawConfigIndex = 0
        configurationMode = .automatic
        configStorageOption = .jsonOnly
        isConfiguring = false
        isTesting = false
        selectedSetupMode = .proxy
        // Don't reset availableModels here to allow caching to persist across dismissals
        // Don't reset savedConfig/availableBackups - they persist while sheet is open
    }

    /// Load available models for agent configuration.
    ///
    /// - Parameter forceRefresh: Reserved for future use.
    /// - Returns: `true` when models were fetched from remote successfully; `false` on fetch error.
    @discardableResult
    func loadModels(forceRefresh: Bool = false) async -> Bool {
        guard let config = modelRequestConfiguration() else { return false }
        let requestedAgent = selectedAgent

        isFetchingModels = true
        defer { isFetchingModels = false }
        var loadedFromRemote = false

        do {
            let fetchedModels = try await AgentModelCatalogService.fetchAvailableModels(proxyURL: config.proxyURL, apiKey: config.apiKey)
            let processedModels = processModels(fetchedModels)
            guard selectedAgent == requestedAgent else { return false }
            self.availableModels = processedModels
            loadedFromRemote = true

            // Log model list
            let modelList = processedModels.map { "\($0.id) (provider: \($0.provider))" }.joined(separator: ", ")
            logger.debug("[AgentSetupViewModel] Loaded \(processedModels.count) models: \(modelList)")
        } catch {
            // 实时目录仍如实报错；仅非 Pi 页面沿用原候选兜底，不覆盖已有选择或保存配置。
            logger.error("[AgentSetupViewModel] Failed to load models: \(error.localizedDescription)")
            guard selectedAgent == requestedAgent else { return false }
            if requestedAgent == .pi {
                availableModels = []
                errorMessage = "agents.pi.modelsFailed".localized()
            } else if availableModels.isEmpty {
                availableModels = AvailableModel.allModels.sorted { $0.displayName < $1.displayName }
            }
        }

        return loadedFromRemote
    }

    /// Builds the configuration used to talk to `/v1/models`.
    ///
    /// Returns `nil` when there is no configuration and no proxy manager to derive
    /// one from — the same condition under which `loadModels(forceRefresh:)`
    /// previously returned `false` without attempting a request.
    private func modelRequestConfiguration() -> AgentConfiguration? {
        // Reuse the sheet's configuration when one exists (agent-setup scenarios)
        if let existingConfig = currentConfiguration {
            return existingConfig
        }

        // Create a config when loading models outside the agent setup sheet.
        guard let proxyManager = proxyManager else { return nil }

        // Use the first API key from the API Keys management interface
        // If no keys exist, fall back to managementKey
        let apiKey = quotaViewModel?.apiKeys.first ?? proxyManager.managementKey

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
    /// 实时目录不使用静态兜底；配置候选的兜底仅由 loadModels 处理，Pi 始终只读实时模型。
    /// from the proxy or configured by the user.
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
        // 只开放模块内纯映射以便定向回归，不新增状态；Pi 不获得猜测的内置模型。
        let candidates = fetchedModels.isEmpty && selectedAgent != .pi ? AvailableModel.allModels : fetchedModels
        return candidates.sorted { $0.displayName < $1.displayName }
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
