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
        .frame(width: 580, height: 620)
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
                
                if agent == .codexCLI {
                    CodexModelConfigSection(
                        viewModel: viewModel,
                        aliases: aliasStore.aliases,
                        onManageAliases: { showModelAliases = true },
                        onModelOrEffortChange: {
                            if isManualMode { generatePreview() }
                        }
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
                                    if isManualMode { generatePreview() }
                                }
                            ),
                            availableModels: viewModel.availableModels,
                            isFetchingModels: viewModel.isFetchingModels,
                            onRefresh: { Task { await viewModel.loadModels(forceRefresh: true) } },
                            aliases: aliasStore.aliases,
                            showsHeader: false
                        )
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
        // 默认行可独立开启 1M；提示覆盖四种用途，不表示所有模型或全局普通窗口都已变成 1M。
        return configuration.claudeDefaultUses1MContext
            || ModelSlot.allCases.contains { configuration.usesClaude1MContext(for: $0) }
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
        VStack(alignment: .leading, spacing: 14) {
            header
            contextField
            autoCompactField
            disableAutoCompactToggle
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
                Text("agents.claude.advanced.context.info".localized())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                TextField(
                    "agents.claude.advanced.context".localized(),
                    value: maxContextBinding,
                    format: .number
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
        }
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
                .frame(width: 74)
                .accessibilityLabel("agents.claude.advanced.compaction".localized())

                Text("%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
            }
        }
    }

    private var disableAutoCompactToggle: some View {
        Toggle(isOn: disableAutoCompactBinding) {
            VStack(alignment: .leading, spacing: 2) {
                Text("agents.claude.advanced.disableAutoCompact".localized())
                    .font(.subheadline.weight(.medium))
                Text("agents.claude.advanced.disableAutoCompact.info".localized())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
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

// MARK: - Codex Model & Reasoning Effort Section

/// Codex CLI 专用的模型与思考强度配置卡片。
/// 消除与模型槽概念的混淆，将默认模型选择器与思考强度策略整合进同一个结构严密的卡片中，
/// 并支持 CPA 思考策略自动继承与受管状态指示。
struct CodexModelConfigSection: View {
    @Bindable var viewModel: AgentSetupViewModel
    var aliases: [CPAModelAlias] = []
    var onManageAliases: () -> Void = {}
    let onModelOrEffortChange: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var selectedModel: String {
        viewModel.currentConfiguration?.codexModel ?? AgentConfiguration.defaultCodexModel
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
                        availableModels: viewModel.availableModels,
                        isFetchingModels: viewModel.isFetchingModels,
                        onRefresh: { Task { await viewModel.loadModels(forceRefresh: true) } },
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
                Task { await viewModel.loadModels(forceRefresh: true) }
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
