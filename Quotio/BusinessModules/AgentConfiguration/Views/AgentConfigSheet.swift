//
//  AgentConfigSheet.swift
//  Quotio - Agent configuration modal with automatic/manual modes
//

import SwiftUI

/// 配置弹窗的只读呈现契约，由客户端列表和仪表盘快捷入口实际复用。
/// 客户端与 startConfiguration 返回的 UUID 必须一起传给 sheet(item:)；分开用两个 State 传递时，
/// 首次呈现闭包可能读取旧 UUID，使真实按钮被会话保护静默拒绝。两个页面仍各自持有呈现状态，
/// 原 ViewModel 继续唯一持有草稿、请求世代和 Task；本值不生成身份，也不承接任何业务状态。
struct AgentConfigurationPresentation: Identifiable {
    let id: UUID
    let agent: CLIAgent
}

struct AgentConfigSheet: View {
    @Bindable var viewModel: AgentSetupViewModel
    let agent: CLIAgent
    /// 展示时冻结所属会话；迟到的 onDismiss、按钮 Task 和 onDisappear 不得操作重开的同类型页面。
    let configurationSessionID: UUID

    init(viewModel: AgentSetupViewModel, agent: CLIAgent, configurationSessionID: UUID? = nil) {
        self._viewModel = Bindable(wrappedValue: viewModel)
        self.agent = agent
        self.configurationSessionID = configurationSessionID ?? viewModel.configurationSessionID
    }
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var previewConfig: AgentConfigResult?
    /// 快速编辑名称或排序会连续触发预览；取消旧任务并丢弃其结果，避免旧 JSON 回写到新表单。
    @State private var previewTask: Task<Void, Never>?
    @State private var aliasStore = CPAModelAliasesViewModel()
    @State private var showModelAliases = false
    @FocusState private var isCloseFocused: Bool
    /// 手动预览是整份草稿的投影，不能靠列举若干字段或 Picker 内部随机身份碰巧触发。
    /// 本值只用于比较输入，不持有业务状态；实际取消和执行仍复用原 previewTask。
    private struct PreviewInput: Equatable {
        let configuration: AgentConfiguration
        let models: [AvailableModel]
        let legacy: ClaudeLegacyModelReferences
        let shell: ShellType
        let sessionID: UUID
    }
    private var previewInput: PreviewInput? {
        guard isManualMode, !viewModel.isLoadingConfiguration,
              viewModel.isCurrentConfigurationSession(configurationSessionID),
              let configuration = viewModel.currentConfiguration else { return nil }
        return PreviewInput(configuration: configuration,
            models: agent == .claudeCode ? viewModel.claudeCompatibilityModels : viewModel.availableModels,
            legacy: viewModel.savedConfig?.claudeLegacyModelReferences ?? .init(),
            shell: viewModel.detectedShell, sessionID: configurationSessionID)
    }
    /// 元数据只属于同一 CPA；候选是否公开由选择器统一与实时目录核对。
    /// 仍把同源配置规则交给 Codex 推理强度等原功能，避免目录失败时丢失已保存的服务端约束说明。
    /// 更换外部服务时不沿用本机 CPA 映射，也不因隐藏旧别名而删除其配置。
    private var serviceAliases: [CPAModelAlias] {
        viewModel.usesCPAModelService ? aliasStore.aliases : []
    }
    private var hasResult: Bool {
        viewModel.configResult != nil
    }
    
    private var isSuccess: Bool {
        viewModel.configResult?.success == true
    }
    
    private var isManualMode: Bool {
        viewModel.configurationMode == .manual
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            ScrollView {
                VStack(spacing: 16) {
                    if hasResult {
                        resultView
                    } else {
                        configurationView
                            .disabled(viewModel.isLoadingConfiguration || viewModel.isConfiguring)
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.automatic, axes: .vertical)
            
            footerView
        }
        // Claude 新增菜单编辑和子代理区域，增加可用宽度，避免模型 ID 与名称互相挤压。
        .frame(width: agent == .claudeCode ? 720 : 580, height: agent == .claudeCode ? 780 : 620)
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
        .task(id: viewModel.currentModelCatalogRevision) {
            // 复用弹窗原有任务槽：目录刷新成功后也读取最新别名定义，避免名称仍有效但目标说明过期。
            // 首次仍允许独立读取配置规则；加载中已有快照不重复取数，关闭页面由 SwiftUI 取消。
            guard viewModel.isCurrentConfigurationSession(configurationSessionID),
                  viewModel.currentModelCatalogRevision != nil || aliasStore.aliases.isEmpty else { return }
            await aliasStore.load(client: viewModel.quotaViewModel?.apiClient)
        }
        .sheet(isPresented: $showModelAliases, onDismiss: {
            // 关闭管理窗口后读取 CPA 最新目录，保留用户尚未保存的槽位和默认模型选择。
            Task {
                guard viewModel.isCurrentConfigurationSession(configurationSessionID) else { return }
                await viewModel.loadModels(forceRefresh: true, sessionID: configurationSessionID)
                guard viewModel.isCurrentConfigurationSession(configurationSessionID) else { return }
                await aliasStore.load(client: viewModel.quotaViewModel?.apiClient)
            }
        }) {
            CPAModelAliasManagerSheet(store: aliasStore, client: viewModel.quotaViewModel?.apiClient)
        }
        .onAppear {
            viewModel.resetSheetState(sessionID: configurationSessionID)
        }
        .onChange(of: previewInput, initial: true) { _, input in
            if input != nil { generatePreview() }
            else {
                previewTask?.cancel()
                previewConfig = nil
            }
        }
        .onDisappear { previewTask?.cancel() }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }
    
    private func generatePreview() {
        previewTask?.cancel()
        guard let input = previewInput else { previewConfig = nil; return }
        previewTask = Task {
            let result = await viewModel.generatePreviewConfig(sessionID: configurationSessionID)
            // 输入变化时即使旧服务不响应取消，也不能让旧 FORCE／1M／上下文结果覆盖当前预览。
            guard !Task.isCancelled, previewInput == input else { return }
            previewConfig = result
        }
    }
    
    private var headerView: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                    .fill(agent.color.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: agent.systemIcon)
                    .font(.title3)
                    .foregroundStyle(agent.color)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("agents.configure".localized() + " " + agent.displayName)
                    .font(.headline)
                
                Text(agent.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            QuotioCircularIconButton(systemImage: "xmark") {
                viewModel.dismissConfiguration(sessionID: configurationSessionID)
                dismiss()
            }
            .focused($isCloseFocused)
            .overlay(Circle().strokeBorder(isCloseFocused ? Color.accentColor : .clear, lineWidth: 2))
            .accessibilityLabel("action.close".localized())
            .help("action.close".localized())
        }
        .padding(16)
    }
    
    private var configurationView: some View {
        VStack(spacing: 16) {
            setupModeSection

            // 在提交前说明插件安装及默认模式的边界，预览不会执行安装命令。
            if agent == .pi {
                Label("agents.pi.setupInfo".localized(), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            modeSelectionSection
            
            if agent == .claudeCode && !isManualMode {
                storageOptionSection
            }
            
            // Only show proxy-specific options when in proxy mode
            if viewModel.selectedSetupMode == .proxy {
                // Claude Code 场景下移除冗余的连接信息（本地代理地址与掩码密钥）
                if agent != .claudeCode {
                    connectionInfoSection
                }

                // 状态警示与目录加载提示（如 CPA 代理未运行、目录加载失败带刷新按钮等）统一置于模型槽上方
                proxyAndCatalogStatusSection

                if agent == .codexCLI {
                    CodexModelConfigSection(
                        viewModel: viewModel,
                        configurationSessionID: configurationSessionID,
                        aliases: serviceAliases,
                        onManageAliases: { showModelAliases = true },
                        onModelOrEffortChange: {}
                    )
                } else if agent == .pi {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("agents.defaultModel".localized()).font(.subheadline.weight(.semibold))
                            Spacer()
                            Button("cpaAliases.manage".localized()) { showModelAliases = true }
                                .buttonStyle(.quotioMicroCapsule)
                        }
                        AgentDefaultModelPicker(
                            agent: agent,
                            selectedModel: Binding(
                                get: { viewModel.currentConfiguration?.modelSlots[.sonnet] ?? "" },
                                set: { model in
                                    viewModel.updateDefaultModel(model)
                                }
                            ),
                            availableModels: viewModel.currentModelCandidates,
                            isFetchingModels: viewModel.isFetchingModels,
                            onRefresh: { Task { await viewModel.loadModels(forceRefresh: true, sessionID: configurationSessionID) } },
                            aliases: serviceAliases,
                            showsHeader: false
                        )
                    }
                    .quotioInsetCard()
                }

                if agent == .claudeCode {
                    ClaudeModelMappingView(viewModel: viewModel, configurationSessionID: configurationSessionID, aliases: serviceAliases, onManageAliases: { showModelAliases = true }, onOneMillionChange: {})
                    if let plan = viewModel.claudeCompatibilityPlan {
                        ClaudeCompatibilityNotice(plan: plan)
                    }
                    // 菜单预览属于角色配置的直接核对入口，独立于高级参数；沿用原组件的折叠与分段状态。
                    // 继续读取同一份纯值计划，不新增目录请求、配置副本或后台任务。
                    if let configuration = viewModel.currentConfiguration {
                        ClaudeModelPanelPreview(configuration: configuration, availableModels: viewModel.claudeCompatibilityModels,
                                                configurationPlan: viewModel.claudeCompatibilityPlan)
                            .quotioInsetCard()
                    }
                    ClaudeAdvancedSettingsSection(viewModel: viewModel, onSettingsChange: {})
                }

                if isManualMode {
                    manualPreviewSection
                }

                if let validation = viewModel.configurationValidationMessage {
                    Label(validation, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                testConnectionSection
            } else {
                defaultModeInfoSection
            }
            
            if !viewModel.availableBackups.isEmpty {
                AgentBackupSection(viewModel: viewModel, configurationSessionID: configurationSessionID)
            }
        }
    }
    
    // MARK: - Setup Mode Section
    
    private var setupModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("agents.setupMode".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                if let saved = viewModel.savedConfig {
                    Label(
                        saved.isProxyConfigured ? "agents.currentlyProxy".localized() : "agents.currentlyDefault".localized(),
                        systemImage: saved.isProxyConfigured ? "checkmark.circle.fill" : "circle"
                    )
                    .font(.caption)
                    .foregroundStyle(saved.isProxyConfigured ? .green : .secondary)
                }
            }
            
            HStack(spacing: 12) {
                ForEach(ConfigurationSetup.allCases) { setup in
                    SetupModeButton(
                        setup: setup,
                        isSelected: viewModel.selectedSetupMode == setup,
                        action: {
                            viewModel.selectedSetupMode = setup
                            viewModel.currentConfiguration?.setupMode = setup
                        }
                    )
                }
            }
            
            Text(viewModel.selectedSetupMode.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .quotioInsetCard()
    }

    private var defaultModeInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("agents.defaultSetup".localized())
                .font(.subheadline)
                .fontWeight(.medium)

            Text("agents.defaultSetup.info".localized())
                .font(.caption)
                .foregroundStyle(.secondary)

            if let saved = viewModel.savedConfig, saved.isProxyConfigured {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("agents.proxyRemovalWarning".localized())
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous))
            }
        }
        .quotioInsetCard()
    }

    private var modeSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("agents.configMode".localized())
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 12) {
                ForEach(ConfigurationMode.allCases) { mode in
                    ModeButton(
                        mode: mode,
                        isSelected: viewModel.configurationMode == mode,
                        action: { viewModel.configurationMode = mode }
                    )
                }
            }
        }
        .quotioInsetCard()
    }

    private var storageOptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("agents.storageOption".localized())
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 12) {
                ForEach(ConfigStorageOption.allCases) { option in
                    StorageOptionButton(
                        option: option,
                        isSelected: viewModel.configStorageOption == option,
                        action: { viewModel.configStorageOption = option }
                    )
                }
            }
        }
        .quotioInsetCard()
    }

    @ViewBuilder
    private var proxyAndCatalogStatusSection: some View {
        // 若 CPA 代理未启动，且为 Claude Code 页面（connectionInfoSection 已省略），顶部展示醒目警告与启动按钮
        if agent == .claudeCode, viewModel.proxyManager?.proxyStatus.running == false {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.body)

                Text("agents.proxyNotRunning.message".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                Button {
                    Task { try? await viewModel.proxyManager?.start() }
                } label: {
                    Text("agents.proxy.start".localized())
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.quotioPrimaryMicroCapsule(height: 24, tint: .orange))
            }
            .padding(10)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous))
        }

        if let error = aliasStore.errorMessage, agent == .claudeCode || agent == .codexCLI || agent == .pi {
            Label(error, systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }

        // 失败／空目录仅提示，不替换模型槽；刷新入口与手动输入继续使用原选择器。
        if let message = viewModel.modelLoadMessage {
            HStack(alignment: .center, spacing: 8) {
                Label(message, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("agents.models.refresh".localized()) {
                    Task { await viewModel.loadModels(forceRefresh: true, sessionID: configurationSessionID) }
                }
                .buttonStyle(.quotioMicroCapsule)
                .disabled(viewModel.isFetchingModels)
            }
            .padding(8)
            .background(QuotioTheme.Colors.cardInset(for: colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous))
        }
    }

    private var connectionInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("agents.connectionInfo".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                if let isRunning = viewModel.proxyManager?.proxyStatus.running {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(isRunning ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(isRunning ? String(format: "agents.proxy.running".localized(), viewModel.proxyManager?.port ?? 8080) : "agents.proxyNotRunning.title".localized())
                            .font(.caption2)
                            .foregroundStyle(isRunning ? .green : .orange)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((isRunning ? Color.green : Color.orange).opacity(0.1))
                    .clipShape(Capsule())
                }
            }

            // 若 CPA 代理未启动，显示启动引导与一键启动
            if viewModel.proxyManager?.proxyStatus.running == false {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.body)

                    Text("agents.proxyNotRunning.message".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    Button {
                        Task { try? await viewModel.proxyManager?.start() }
                    } label: {
                        Text("agents.proxy.start".localized())
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.quotioPrimaryMicroCapsule(height: 24, tint: .orange))
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous))
            }

            VStack(spacing: 6) {
                InfoRow(
                    label: "agents.proxyURL".localized(),
                    value: viewModel.currentConfiguration?.proxyURL ?? "",
                    copyableValue: viewModel.currentConfiguration?.proxyURL
                )
                InfoRow(
                    label: "agents.apiKey".localized(),
                    value: maskedAPIKey,
                    isMasked: true,
                    copyableValue: viewModel.currentConfiguration?.apiKey
                )
            }
        }
        .quotioInsetCard()
    }
    
    private var maskedAPIKey: String {
        guard let key = viewModel.currentConfiguration?.apiKey, key.count > 8 else {
            return "••••••••"
        }
        return String(key.prefix(4)) + "••••" + String(key.suffix(4))
    }
    

    private var manualPreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("agents.rawConfigs".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                if let config = previewConfig, !config.rawConfigs.isEmpty {
                    Button {
                        copyPreviewToClipboard()
                    } label: {
                        Label("action.copyAll".localized(), systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.quotioMicroCapsule)
                    .controlSize(.small)
                }
            }

            if let config = previewConfig, !config.rawConfigs.isEmpty {
                if config.rawConfigs.count > 1 {
                    // JSON／Shell 预览沿用项目分段控件，保持原来的索引选择与复制逻辑。
                    QuotioCapsuleSegmentedControl(
                        Array(config.rawConfigs.indices), selection: $viewModel.selectedRawConfigIndex,
                        size: .small, tint: agent.color, isEqualWidth: false,
                        title: { config.rawConfigs[$0].filename ?? "Config \($0 + 1)" }
                    )
                    .accessibilityLabel("agents.rawConfigs".localized())
                }

                if viewModel.selectedRawConfigIndex < config.rawConfigs.count {
                    RawConfigView(config: config.rawConfigs[viewModel.selectedRawConfigIndex]) {
                        copyPreviewToClipboard(index: viewModel.selectedRawConfigIndex)
                    }
                }
            } else if let config = previewConfig, !config.success {
                // 已结束的失败不是“仍在生成”；保留具体错误，用户可修改／重试后重建同一预览。
                Label(config.error ?? "agents.configFailed".localized(), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    SmallProgressView()
                    Text("Generating preview...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
            }
        }
        .quotioInsetCard()
    }

    private func copyPreviewToClipboard(index: Int? = nil) {
        guard let config = previewConfig else { return }

        let content: String
        if let idx = index, idx < config.rawConfigs.count {
            content = config.rawConfigs[idx].content
        } else {
            content = config.rawConfigs.map { $0.content }.joined(separator: "\n\n---\n\n")
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    private var testConnectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Label("agents.testConnection".localized(), systemImage: "network")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                // 定态连接状态反馈（测试中 / 成功带耗时 / 失败）
                if viewModel.isTesting {
                    HStack(spacing: 5) {
                        SmallProgressView()
                        Text("customProviders.testing".localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
                } else if let result = viewModel.testResult {
                    HStack(spacing: 5) {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(result.success ? .green : .red)
                        Text(result.success ? "remote.test.success".localized() : "remote.test.failed".localized())
                            .font(.caption.weight(.medium))
                            .foregroundStyle(result.success ? .green : .red)
                        if let latency = result.latencyMs {
                            Text("\(latency)ms")
                                .font(.caption2.monospaced())
                                .foregroundStyle(result.success ? .green.opacity(0.8) : .red.opacity(0.8))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((result.success ? Color.green : Color.red).opacity(0.12))
                    .clipShape(Capsule())
                }

                Button {
                    Task { await viewModel.testConnection(sessionID: configurationSessionID) }
                } label: {
                    HStack(spacing: 4) {
                        if viewModel.isTesting {
                            SmallProgressView()
                        } else {
                            Image(systemName: viewModel.testResult == nil ? "bolt.fill" : "arrow.clockwise")
                        }
                        Text(viewModel.testResult == nil ? "agents.test".localized() : "action.retry".localized())
                    }
                    .font(.caption)
                }
                .buttonStyle(.quotioMicroCapsule)
                .controlSize(.small)
                .disabled(viewModel.isTesting)
                .opacity(viewModel.isTesting ? 0.5 : 1)
            }

            // 测试失败时展开详细原因诊断条
            if let result = viewModel.testResult, !result.success {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.top, 2)
                    Text(result.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous))
            } else if let result = viewModel.testResult, result.success, !result.message.isEmpty, result.message != "OK" {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(result.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous))
            }
        }
        .quotioInsetCard()
    }
    
    @ViewBuilder
    private var resultView: some View {
        if isSuccess {
            successResultView
        } else {
            errorResultView
        }
    }
    
    private var successResultView: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                
                Text("agents.configSuccess".localized())
                    .font(.headline)
                    .foregroundStyle(.green)
            }
            
            if let result = viewModel.configResult {
                Text(result.instructions)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .quotioInsetCard(padding: 12)

                if result.mode == .automatic {
                    automaticModeResult(result)
                }

                if result.mode == .manual && !result.rawConfigs.isEmpty {
                    manualModeResult(result)
                }
            }
        }
    }

    private func automaticModeResult(_ result: AgentConfigResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("agents.filesModified".localized())
                .font(.subheadline)
                .fontWeight(.medium)

            VStack(alignment: .leading, spacing: 6) {
                if let configPath = result.configPath {
                    FilePathRow(icon: "doc.fill", label: "Config", path: configPath)
                }

                if let authPath = result.authPath {
                    FilePathRow(icon: "key.fill", label: "Auth", path: authPath)
                }

                if result.shellConfig != nil {
                    FilePathRow(icon: "terminal", label: "Shell", path: viewModel.detectedShell.profilePath)
                }

                if let backupPath = result.backupPath {
                    FilePathRow(icon: "clock.arrow.circlepath", label: "Backup", path: backupPath)
                }
            }
        }
        .quotioInsetCard()
    }

    private func manualModeResult(_ result: AgentConfigResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("agents.rawConfigs".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Button {
                    viewModel.copyAllRawConfigsToClipboard()
                } label: {
                    Label("action.copyAll".localized(), systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.quotioMicroCapsule)
                .controlSize(.small)
            }

            if result.rawConfigs.count > 1 {
                // 生成结果中的格式 Tab 与编辑时的预览使用同一控件，避免前后样式不一致。
                QuotioCapsuleSegmentedControl(
                    Array(result.rawConfigs.indices), selection: $viewModel.selectedRawConfigIndex,
                    size: .small, tint: agent.color, isEqualWidth: false,
                    title: { result.rawConfigs[$0].filename ?? "Config \($0 + 1)" }
                )
                .accessibilityLabel("agents.rawConfigs".localized())
            }

            if viewModel.selectedRawConfigIndex < result.rawConfigs.count {
                RawConfigView(config: result.rawConfigs[viewModel.selectedRawConfigIndex]) {
                    viewModel.copyRawConfigToClipboard(index: viewModel.selectedRawConfigIndex)
                }
            }
        }
        .quotioInsetCard()
    }
    
    private var errorResultView: some View {
        VStack(spacing: 14) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.red)
            
            Text("agents.configFailed".localized())
                .font(.headline)
                .foregroundStyle(.red)
            
            if let error = viewModel.configResult?.error {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .quotioInsetCard(padding: 12)
            }
        }
    }
    
    private var footerView: some View {
        HStack {
            if hasResult {
                if !isSuccess {
                    Button("action.retry".localized()) {
                        viewModel.retryConfiguration(sessionID: configurationSessionID)
                    }
                    .buttonStyle(.quotioSecondaryCapsule)
                }
                Spacer()
                
                Button("action.done".localized()) {
                    viewModel.dismissConfiguration(sessionID: configurationSessionID)
                    dismiss()
                }
                .buttonStyle(.quotioPrimaryCapsule)
                .keyboardShortcut(.return)
            } else {
                Button("action.cancel".localized(), role: .cancel) {
                    viewModel.dismissConfiguration(sessionID: configurationSessionID)
                    dismiss()
                }
                .buttonStyle(.quotioSecondaryCapsule)
                .keyboardShortcut(.escape)
                
                Spacer()
                
                Button {
                    Task { await viewModel.applyConfiguration(sessionID: configurationSessionID) }
                } label: {
                    HStack(spacing: 4) {
                        if viewModel.isConfiguring {
                            SmallProgressView()
                        } else {
                            Image(systemName: viewModel.configurationMode == .automatic ? "gearshape.2" : "square.and.arrow.down")
                        }
                        // 保存入口统一显示“应用”。备份、目录核对和旧配置兼容仍在原保存事务内部完成，
                        // 不因磁盘是否带有受管菜单标记而要求用户理解或执行额外的迁移操作。
                        Text(viewModel.configurationMode == .automatic ? "agents.apply".localized() : "agents.saveConfig".localized())
                    }
                }
                .buttonStyle(.quotioPrimaryCapsule)
                .tint(agent.color)
                .accentColor(agent.color)
                .disabled(viewModel.isConfiguring || viewModel.isLoadingConfiguration || viewModel.isDeletingBackups
                          || viewModel.configurationValidationMessage != nil)
                .opacity(viewModel.isConfiguring || viewModel.isLoadingConfiguration || viewModel.isDeletingBackups ? 0.5 : 1)
                .keyboardShortcut(.return)
            }
        }
        .padding(16)
    }
}

struct ClaudeAdvancedSettingsSection: View {
    @Bindable var viewModel: AgentSetupViewModel
    let onSettingsChange: () -> Void
    /// 仅管理本组件的折叠外观；新旧配置均默认收起，不因回填值而擅自展开或修改草稿。
    @State private var isExpanded = false

    private enum ContextMode: String, CaseIterable {
        case automatic, custom
        var title: String { "agents.claude.advanced.context.\(rawValue)".localized() }
    }

    private var contextMode: ContextMode {
        viewModel.currentConfiguration?.claudeMaxContextTokens == nil ? .automatic : .custom
    }

    private var contextModeBinding: Binding<ContextMode> {
        Binding(get: { contextMode }, set: { mode in
            guard mode != contextMode else { return }
            // 切到自定义只建立空输入，不猜一个模型容量；0 是尚未填写的本轮草稿，保存前必须通过校验。
            viewModel.updateClaudeMaxContextTokens(mode == .automatic ? nil : 0)
            onSettingsChange()
        })
    }

    private var uses1MContext: Bool {
        guard let configuration = viewModel.currentConfiguration else { return false }
        // 默认行可独立开启 1M；提示覆盖四种用途，不表示所有模型或全局普通窗口都已变成 1M。
        return configuration.claudeDefaultUses1MContext
            || ModelSlot.allCases.contains { configuration.usesClaude1MContext(for: $0) }
    }

    private var maxContextBinding: Binding<String> {
        Binding(
            get: {
                guard let tokens = viewModel.currentConfiguration?.claudeMaxContextTokens, tokens != 0 else { return "" }
                return String(tokens)
            },
            set: {
                // 切回跟随后 SwiftUI 会撤下输入框，原生 field editor 此时仍可能回写空文本。
                // 不能让这个迟到的结束编辑把 nil 重新改成 0，恢复用户刚刚关闭的自定义模式。
                guard contextMode == .custom else { return }
                let value = $0.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                viewModel.updateClaudeMaxContextTokens(Int(value) ?? 0)
                onSettingsChange()
            }
        )
    }

    private var autoCompactBinding: Binding<Int> {
        Binding(
            get: {
                viewModel.currentConfiguration?.claudeAutoCompactPercentage
                    ?? AgentConfiguration.defaultClaudeAutoCompactPercentage
            },
            set: {
                viewModel.updateClaudeAutoCompactPercentage($0)
                onSettingsChange()
            }
        )
    }

    private var disableAutoCompactBinding: Binding<Bool> {
        Binding(
            get: { viewModel.currentConfiguration?.claudeDisableAutoCompact ?? false },
            set: {
                viewModel.updateClaudeDisableAutoCompact($0)
                onSettingsChange()
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 沿用本页菜单预览的整行折叠按钮，标题、空白和箭头都能展开，避免 macOS 仅小箭头可点。
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    header
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("claude.advanced.toggle")
            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    QuotioCapsuleSegmentedControl(ContextMode.allCases, selection: contextModeBinding,
                        size: .small, tint: .accentColor, isEqualWidth: false, title: { $0.title })
                        .accessibilityLabel("agents.claude.advanced.context".localized())
                    Text("agents.claude.advanced.context.info".localized())
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if contextMode == .custom { contextField }
                    autoCompactField
                    disableAutoCompactToggle
                    // 高级区仅保留原网关发现开关；菜单预览已作为上方独立区块展示。
                    // 替换菜单仍隐藏发现选项，不能因布局移动改变存量开关或网关运行语义。
                    if let configuration = viewModel.currentConfiguration, !configuration.claudeCatalogManaged,
                       configuration.claudeModelPicker.mode == .native || configuration.claudeModelPicker.mode == .append {
                        Divider()
                        Toggle("agents.modelMapping.gatewayModels".localized(), isOn: Binding(
                            get: { viewModel.currentConfiguration?.claudeGatewayModelDiscovery ?? false },
                            set: { viewModel.updateClaudeGatewayModelDiscovery($0); onSettingsChange() }
                        ))
                        .toggleStyle(.switch).controlSize(.small).font(.caption)
                    }
                }
                .padding(.top, 10)
            }
        }
        .quotioInsetCard()
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(QuotioTheme.Colors.claudeOrange.opacity(0.15))
                    .frame(width: 24, height: 24)
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(QuotioTheme.Colors.claudeOrange)
            }

            Text("agents.claude.advanced".localized())
                .font(.subheadline.weight(.semibold))

            Spacer()

            // 折叠时仍能看出已有显式覆盖，避免用户误以为旧自定义值已被清除。
            Text(contextMode.title).font(.caption2).foregroundStyle(.secondary)

            if uses1MContext {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.circle.fill")
                        .font(.system(size: 10))
                    Text("agents.claude.advanced.context.effective1M".localized())
                        .font(.caption2.weight(.medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var contextField: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("agents.claude.advanced.context".localized())
                    .font(.subheadline.weight(.medium))
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                TextField(
                    "agents.claude.advanced.context.placeholder".localized(),
                    text: maxContextBinding
                )
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12, design: .monospaced))
                .modifier(AgentConfigNumericFieldStyle())
                .frame(width: 120)
                .accessibilityLabel("agents.claude.advanced.context".localized())

                Text("agents.claude.advanced.tokens".localized())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
            }
            // 两个数值项占用相同的右侧控制列，输入框与单位在各行保持同一位置。
            .frame(width: 170, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    private var autoCompactField: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("agents.claude.advanced.compaction".localized())
                    .font(.subheadline.weight(.medium))
                Text("agents.claude.advanced.compaction.info".localized())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                TextField(
                    "agents.claude.advanced.compaction".localized(),
                    value: autoCompactBinding,
                    format: .number
                )
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12, design: .monospaced))
                .modifier(AgentConfigNumericFieldStyle())
                .frame(width: 120)
                .accessibilityLabel("agents.claude.advanced.compaction".localized())

                Text("%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
            }
            .frame(width: 170, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    private var disableAutoCompactToggle: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("agents.claude.advanced.disableAutoCompact".localized())
                    .font(.subheadline.weight(.medium))
                Text("agents.claude.advanced.disableAutoCompact.info".localized())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            // 标签和开关分开布局，避免系统 Toggle 的固有宽度把开关挤到说明文字旁。
            Toggle("agents.claude.advanced.disableAutoCompact".localized(), isOn: disableAutoCompactBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(width: 44, alignment: .trailing)
                .accessibilityHint("agents.claude.advanced.disableAutoCompact.info".localized())
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AgentConfigNumericFieldStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($isFocused)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .background(Capsule().fill(QuotioTheme.Colors.cardTag(for: colorScheme)))
            .overlay(
                Capsule().strokeBorder(
                    isFocused ? Color.accentColor : QuotioTheme.Colors.sidebarBorder(for: colorScheme),
                    lineWidth: isFocused ? 1.5 : 0.5
                )
            )
    }
}

private struct ModeButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    let mode: ConfigurationMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: mode.icon)
                    .font(.callout)
                Text(mode.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(isSelected ? Color.accentColor.opacity(0.15) : QuotioTheme.Colors.cardTag(for: colorScheme))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.accentColor : QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: isSelected ? 1.5 : 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SetupModeButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    let setup: ConfigurationSetup
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: setup.icon)
                    .font(.callout)
                Text(setup.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(isSelected ? Color.accentColor.opacity(0.15) : QuotioTheme.Colors.cardTag(for: colorScheme))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.accentColor : QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: isSelected ? 1.5 : 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct StorageOptionButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    let option: ConfigStorageOption
    let isSelected: Bool
    let action: () -> Void

    private var displayName: String {
        switch option {
        case .jsonOnly: return "agents.storage.jsonOnly".localized()
        case .shellOnly: return "agents.storage.shellOnly".localized()
        case .both: return "agents.storage.both".localized()
        }
    }

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: option.icon)
                    .font(.callout)
                Text(displayName)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(isSelected ? Color.accentColor.opacity(0.15) : QuotioTheme.Colors.cardTag(for: colorScheme))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.accentColor : QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: isSelected ? 1.5 : 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var isMasked: Bool = false
    var copyableValue: String? = nil
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(isMasked ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let copyable = copyableValue, !copyable.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyable, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("action.copy".localized())
            }
        }
    }
}

private struct TestResultView: View {
    let result: ConnectionTestResult
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.success ? .green : .red)
            
            Text(result.message)
                .font(.caption)
                .foregroundStyle(result.success ? .green : .red)
            
            Spacer()
            
            if let latency = result.latencyMs {
                Text("\(latency)ms")
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(result.success ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous))
    }
}

private struct FilePathRow: View {
    let icon: String
    let label: String
    let path: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 45, alignment: .leading)
            
            Text(path)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct RawConfigView: View {
    @Environment(\.colorScheme) private var colorScheme
    let config: RawConfigOutput
    let onCopy: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let targetPath = config.targetPath {
                    Text(targetPath)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                Spacer()
                
                Text(config.format.rawValue.uppercased())
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
                
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.quotioMicroCapsule)
                .accessibilityLabel("action.copy".localized())
                .help("action.copy".localized())
            }
            
            ScrollView {
                Text(config.content)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic, axes: .vertical)
            .frame(minHeight: 150, maxHeight: 320)
            .padding(10)
            .background(QuotioTheme.Colors.cardInset(for: colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous))
        }
    }
}

// MARK: - Codex Model & Reasoning Effort Section

/// Codex CLI 专用的模型与思考强度配置卡片。
/// 消除与模型槽概念的混淆，将默认模型选择器与思考强度策略整合进同一个结构严密的卡片中，
/// 并支持 CPA 思考策略自动继承与受管状态指示。
struct CodexModelConfigSection: View {
    @Bindable var viewModel: AgentSetupViewModel
    var configurationSessionID: UUID? = nil
    var aliases: [CPAModelAlias] = []
    var onManageAliases: () -> Void = {}
    let onModelOrEffortChange: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var selectedModel: String {
        viewModel.currentConfiguration?.codexModel ?? ""
    }

    private var matchingAlias: CPAModelAlias? {
        aliases.first { $0.alias.caseInsensitiveCompare(selectedModel) == .orderedSame }
    }

    private var fixedEffort: String? {
        CPAModelAliasPolicy.fixedEffort(for: selectedModel, in: aliases)
    }

    private var hasServerEffortOverride: Bool {
        CPAModelAliasPolicy.entries(for: selectedModel, in: aliases).contains(where: { $0.effort != nil })
    }

    private var currentEffort: CodexReasoningEffort {
        viewModel.currentConfiguration?.codexReasoningEffort ?? .defaultEffort
    }

    private var reasoningEffortOptions: [CodexReasoningEffort] {
        let current = currentEffort
        var options = CodexReasoningEffort.allCases
        if !options.contains(current) {
            options.append(current)
        }
        return options
    }

    private var lockedEffortDisplayName: String {
        if let fixedEffort, let effort = CodexReasoningEffort(rawValue: fixedEffort) {
            return effort.displayName
        }
        return (fixedEffort ?? currentEffort.rawValue).capitalized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar

            // 核心双列垂直对齐布局（Column-based：确保标题与对应控件同轴 100% 垂直像素对齐）
            HStack(alignment: .top, spacing: 12) {
                // 左列：默认模型
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("agents.defaultModel".localized())
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        if matchingAlias != nil {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 8))
                                Text("cpaAliases.title".localized())
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                    .frame(height: 16, alignment: .leading)

                    AgentDefaultModelPicker(
                        agent: .codexCLI,
                        selectedModel: Binding(
                            get: { selectedModel },
                            set: { model in
                                viewModel.updateDefaultModel(model)
                                onModelOrEffortChange()
                            }
                        ),
                        availableModels: viewModel.currentModelCandidates,
                        isFetchingModels: viewModel.isFetchingModels,
                        onRefresh: { Task { await viewModel.loadModels(forceRefresh: true, sessionID: configurationSessionID) } },
                        aliases: aliases,
                        showsHeader: false
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 右列：推理强度（固定宽度 140pt，标题与胶囊控件同轴垂直对齐）
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("agents.reasoningEffort".localized())
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        if hasServerEffortOverride {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 16, alignment: .leading)

                    if hasServerEffortOverride {
                        serverEffortLockedBadge
                    } else {
                        clientReasoningEffortPicker
                    }
                }
                .frame(width: 140, alignment: .leading)
            }

            // 辅助提示说明
            if hasServerEffortOverride {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 1)

                    Text(String(format: "cpaAliases.fixedSummary".localized(), fixedEffort ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }

            // 启动模型和 /model 目录分别配置；即使别名已绑定服务端思考策略，也需保留此说明。
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)

                Text("agents.defaultModel.codexInfo".localized())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
        .quotioInsetCard()
    }

    private var headerBar: some View {
        HStack {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(QuotioTheme.Colors.codexGreen.opacity(0.15))
                        .frame(width: 24, height: 24)
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(QuotioTheme.Colors.codexGreen)
                }

                Text(String(format: "%@ & %@", "agents.defaultModel".localized(), "agents.reasoningEffort".localized()))
                    .font(.subheadline.weight(.semibold))
            }

            Spacer()

            Button("cpaAliases.manage".localized(), action: onManageAliases)
                .buttonStyle(.quotioMicroCapsule)

            Button {
                Task { await viewModel.loadModels(forceRefresh: true, sessionID: configurationSessionID) }
            } label: {
                if viewModel.isFetchingModels {
                    SmallProgressView()
                } else {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
            }
            .buttonStyle(.quotioMicroCapsule)
            .disabled(viewModel.isFetchingModels)
            .help("agents.models.refresh".localized())
            .accessibilityLabel("agents.models.refresh".localized())
        }
    }

    private var serverEffortLockedBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)

            Text(lockedEffortDisplayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Image(systemName: "lock.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 36)
        .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5)
        )
        .help(String(format: "cpaAliases.fixedSummary".localized(), fixedEffort ?? ""))
        .accessibilityLabel(String(format: "cpaAliases.fixedSummary".localized(), fixedEffort ?? ""))
    }

    private var clientReasoningEffortPicker: some View {
        Menu {
            ForEach(reasoningEffortOptions) { effort in
                Button {
                    viewModel.updateReasoningEffort(effort)
                    onModelOrEffortChange()
                } label: {
                    HStack {
                        Text(effort.displayName)
                        if currentEffort == effort {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .font(.system(size: 11))
                    .foregroundStyle(QuotioTheme.Colors.codexGreen)

                Text(currentEffort.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
            .overlay(
                Capsule().strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("agents.reasoningEffort".localized())
        .help(String(format: "%@: %@", "agents.reasoningEffort".localized(), currentEffort.displayName))
    }
}

#Preview {
    AgentConfigSheet(
        viewModel: AgentSetupViewModel(),
        agent: .claudeCode
    )
}
