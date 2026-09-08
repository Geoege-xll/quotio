//
//  AgentConfigSheet.swift
//  Quotio - Agent configuration modal with automatic/manual modes
//

import SwiftUI

struct AgentConfigSheet: View {
    @Bindable var viewModel: AgentSetupViewModel
    let agent: CLIAgent
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var previewConfig: AgentConfigResult?
    @State private var aliasStore = CPAModelAliasesViewModel()
    @State private var showModelAliases = false
    @FocusState private var isCloseFocused: Bool
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
                            .disabled(viewModel.isLoadingConfiguration)
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.automatic, axes: .vertical)
            
            footerView
        }
        .frame(width: 720, height: 600)
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
        .task { await aliasStore.load(client: viewModel.quotaViewModel?.apiClient) }
        .sheet(isPresented: $showModelAliases, onDismiss: {
            // 关闭管理窗口后读取 CPA 最新目录，保留用户尚未保存的槽位和默认模型选择。
            Task {
                await viewModel.loadModels(forceRefresh: true)
                await aliasStore.load(client: viewModel.quotaViewModel?.apiClient)
            }
        }) {
            CPAModelAliasManagerSheet(store: aliasStore, client: viewModel.quotaViewModel?.apiClient)
        }
        .onAppear {
            viewModel.resetSheetState()
            if isManualMode {
                generatePreview()
            }
        }
        .onChange(of: viewModel.isLoadingConfiguration) { _, isLoading in
            // 回填完成后重建手动预览，避免把加载前的默认模型展示成已有配置。
            if !isLoading && isManualMode { generatePreview() }
        }
        .onChange(of: viewModel.currentConfiguration?.modelSlots) {
            if isManualMode { generatePreview() }
        }
        .onChange(of: viewModel.currentConfiguration?.claudeModelDisplayNames) {
            if isManualMode { generatePreview() }
        }
        .onChange(of: viewModel.configurationMode) { _, newMode in
            if newMode == .manual {
                generatePreview()
            } else {
                previewConfig = nil
            }
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }
    
    private func generatePreview() {
        Task {
            previewConfig = await viewModel.generatePreviewConfig()
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
                viewModel.dismissConfiguration()
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
                connectionInfoSection
                
                if agent == .codexCLI || agent == .pi {
                    VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("agents.modelSlots".localized()).font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("cpaAliases.manage".localized()) { showModelAliases = true }
                            .buttonStyle(.quotioMicroCapsule)
                    }
                    AgentDefaultModelPicker(
                        agent: agent,
                        selectedModel: Binding(
                            get: {
                                agent == .pi
                                    ? (viewModel.currentConfiguration?.modelSlots[.sonnet] ?? "")
                                    : (viewModel.currentConfiguration?.codexModel ?? AgentConfiguration.defaultCodexModel)
                            },
                            set: { model in
                                viewModel.updateDefaultModel(model)
                                if isManualMode { generatePreview() }
                            }
                        ),
                        availableModels: viewModel.availableModels,
                        isFetchingModels: viewModel.isFetchingModels,
                        onRefresh: { Task { await viewModel.loadModels(forceRefresh: true) } },
                        aliases: aliasStore.aliases
                    )
                    // CPA 固定别名会覆盖客户端强度，界面不能再展示一个看似能生效的编辑器。
                    let model = viewModel.currentConfiguration?.codexModel ?? AgentConfiguration.defaultCodexModel
                    if agent == .codexCLI && !CPAModelAliasPolicy.entries(for: model, in: aliasStore.aliases).contains(where: { $0.effort != nil }) {
                        reasoningEffortSection
                    }
                    }
                    .quotioInsetCard()
                }

                if agent == .claudeCode {
                    ClaudeModelMappingView(viewModel: viewModel, aliases: aliasStore.aliases, onManageAliases: { showModelAliases = true }) {
                        if isManualMode { generatePreview() }
                    }
                    ClaudeAdvancedSettingsSection(viewModel: viewModel) {
                        if isManualMode { generatePreview() }
                    }
                }

                if let error = aliasStore.errorMessage, agent == .claudeCode || agent == .codexCLI || agent == .pi {
                    Label(error, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if isManualMode {
                    manualPreviewSection
                }
                
                testConnectionSection
            } else {
                defaultModeInfoSection
            }
            
            if !viewModel.availableBackups.isEmpty {
                AgentBackupSection(viewModel: viewModel)
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

    private var connectionInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("agents.connectionInfo".localized())
                .font(.subheadline)
                .fontWeight(.medium)

            VStack(spacing: 6) {
                InfoRow(label: "agents.proxyURL".localized(), value: viewModel.currentConfiguration?.proxyURL ?? "")
                InfoRow(label: "agents.apiKey".localized(), value: maskedAPIKey, isMasked: true)
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
    
    /// Named efforts plus, when the existing config holds a value Quotio does
    /// not name, that value — so it stays selected and survives a save.
    private var reasoningEffortOptions: [CodexReasoningEffort] {
        let current = viewModel.currentConfiguration?.codexReasoningEffort ?? .defaultEffort
        var options = CodexReasoningEffort.allCases
        if !options.contains(current) {
            options.append(current)
        }
        return options
    }

    private var reasoningEffortSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("agents.reasoningEffort".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer(minLength: 12)

                Picker("", selection: Binding(
                    get: { viewModel.currentConfiguration?.codexReasoningEffort ?? .defaultEffort },
                    set: { effort in
                        viewModel.updateReasoningEffort(effort)
                        if isManualMode {
                            generatePreview()
                        }
                    }
                )) {
                    ForEach(reasoningEffortOptions) { effort in
                        Text(effort.displayName)
                            .tag(effort)
                    }
                }
                .pickerStyle(.menu)
                .modifier(AgentConfigMenuStyle())
                .frame(maxWidth: 280)
                .accessibilityLabel("agents.reasoningEffort".localized())
            }

            Text("agents.reasoningEffort.info".localized())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var oauthToggleSection: some View {
        Toggle(isOn: Binding(
            get: { viewModel.currentConfiguration?.useOAuth ?? true },
            set: { viewModel.currentConfiguration?.useOAuth = $0 }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("agents.useOAuth".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("agents.useOAuthDesc".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .quotioInsetCard()
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
                    Picker("Config", selection: $viewModel.selectedRawConfigIndex) {
                        ForEach(config.rawConfigs.indices, id: \.self) { index in
                            Text(config.rawConfigs[index].filename ?? "Config \(index + 1)")
                                .tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if viewModel.selectedRawConfigIndex < config.rawConfigs.count {
                    RawConfigView(config: config.rawConfigs[viewModel.selectedRawConfigIndex]) {
                        copyPreviewToClipboard(index: viewModel.selectedRawConfigIndex)
                    }
                }
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
            HStack {
                Text("agents.testConnection".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Button {
                    Task { await viewModel.testConnection() }
                } label: {
                    HStack(spacing: 4) {
                        if viewModel.isTesting {
                            SmallProgressView()
                        } else {
                            Image(systemName: "bolt.fill")
                        }
                        Text("agents.test".localized())
                    }
                    .font(.caption)
                }
                .buttonStyle(.quotioMicroCapsule)
                .controlSize(.small)
                .disabled(viewModel.isTesting)
                .opacity(viewModel.isTesting ? 0.5 : 1)
            }

            if let result = viewModel.testResult {
                TestResultView(result: result)
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
                Picker("Config", selection: $viewModel.selectedRawConfigIndex) {
                    ForEach(result.rawConfigs.indices, id: \.self) { index in
                        Text(result.rawConfigs[index].filename ?? "Config \(index + 1)")
                            .tag(index)
                    }
                }
                .pickerStyle(.segmented)
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
                Spacer()
                
                Button("action.done".localized()) {
                    viewModel.dismissConfiguration()
                    dismiss()
                }
                .buttonStyle(.quotioPrimaryCapsule)
                .keyboardShortcut(.return)
            } else {
                Button("action.cancel".localized(), role: .cancel) {
                    viewModel.dismissConfiguration()
                    dismiss()
                }
                .buttonStyle(.quotioSecondaryCapsule)
                .keyboardShortcut(.escape)
                
                Spacer()
                
                Button {
                    Task { await viewModel.applyConfiguration() }
                } label: {
                    HStack(spacing: 4) {
                        if viewModel.isConfiguring {
                            SmallProgressView()
                        } else {
                            Image(systemName: viewModel.configurationMode == .automatic ? "gearshape.2" : "square.and.arrow.down")
                        }
                        Text(viewModel.configurationMode == .automatic ? "agents.apply".localized() : "agents.saveConfig".localized())
                    }
                }
                .buttonStyle(.quotioPrimaryCapsule)
                .tint(agent.color)
                .accentColor(agent.color)
                .disabled(viewModel.isConfiguring || viewModel.isLoadingConfiguration || viewModel.isDeletingBackups)
                .opacity(viewModel.isConfiguring || viewModel.isLoadingConfiguration || viewModel.isDeletingBackups ? 0.5 : 1)
                .keyboardShortcut(.return)
            }
        }
        .padding(16)
    }
}

private struct ClaudeAdvancedSettingsSection: View {
    @Bindable var viewModel: AgentSetupViewModel
    let onSettingsChange: () -> Void

    private var uses1MContext: Bool {
        guard let configuration = viewModel.currentConfiguration else { return false }
        return ModelSlot.allCases.contains { configuration.usesClaude1MContext(for: $0) }
    }

    private var maxContextBinding: Binding<Int> {
        Binding(
            get: {
                viewModel.currentConfiguration?.claudeMaxContextTokens
                    ?? AgentConfiguration.defaultClaudeMaxContextTokens
            },
            set: {
                viewModel.updateClaudeMaxContextTokens($0)
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
        VStack(alignment: .leading, spacing: 12) {
            header
            contextField
            autoCompactField
            disableAutoCompactToggle
        }
        .quotioInsetCard()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("agents.claude.advanced".localized())
                .font(.subheadline)
                .fontWeight(.medium)
            Spacer()
            if uses1MContext {
                Label(
                    "agents.claude.advanced.context.effective1M".localized(),
                    systemImage: "arrow.up.right.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var contextField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("agents.claude.advanced.context".localized())
                    .font(.subheadline)
                Text("agents.claude.advanced.context.info".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            TextField(
                "agents.claude.advanced.context".localized(),
                value: maxContextBinding,
                format: .number
            )
            .multilineTextAlignment(.trailing)
            .modifier(AgentConfigNumericFieldStyle())
            .frame(width: 126)
            .accessibilityLabel("agents.claude.advanced.context".localized())
            Text("agents.claude.advanced.tokens".localized())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var autoCompactField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("agents.claude.advanced.compaction".localized())
                    .font(.subheadline)
                Text("agents.claude.advanced.compaction.info".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            TextField(
                "agents.claude.advanced.compaction".localized(),
                value: autoCompactBinding,
                format: .number
            )
            .multilineTextAlignment(.trailing)
            .modifier(AgentConfigNumericFieldStyle())
            .frame(width: 74)
            .accessibilityLabel("agents.claude.advanced.compaction".localized())
            Text("%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var disableAutoCompactToggle: some View {
        Toggle(isOn: disableAutoCompactBinding) {
            VStack(alignment: .leading, spacing: 2) {
                Text("agents.claude.advanced.disableAutoCompact".localized())
                    .font(.subheadline)
                Text("agents.claude.advanced.disableAutoCompact.info".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHint("agents.claude.advanced.disableAutoCompact.info".localized())
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
    
    var body: some View {
        HStack {
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

#Preview {
    AgentConfigSheet(
        viewModel: AgentSetupViewModel(),
        agent: .claudeCode
    )
}
