//
//  CustomProviderSheet.swift
//  Quotio - Custom AI provider add/edit modal
//

import SwiftUI

struct CustomProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let provider: CustomProvider?
    let initialProviderType: CustomProviderType
    private let isAddingOfficialOpenAI: Bool
    let onSave: (CustomProvider) -> Void

    init(
        provider: CustomProvider?,
        initialProviderType: CustomProviderType = .openaiCompatibility,
        isAddingOfficialOpenAI: Bool = false,
        onSave: @escaping (CustomProvider) -> Void
    ) {
        self.provider = provider
        self.initialProviderType = initialProviderType
        // 预设只约束新建流程。稍后通过现有入口编辑已保存的供应商时，仍加载它自己的配置。
        self.isAddingOfficialOpenAI = provider == nil && isAddingOfficialOpenAI
        self.onSave = onSave
        if self.isAddingOfficialOpenAI {
            _name = State(initialValue: "OpenAI")
        }
    }
    
    // MARK: - Form State
    
    @State private var name: String = ""
    @State private var providerType: CustomProviderType = .openaiCompatibility
    @State private var baseURL: String = ""
    /// 协议选择属于原表单草稿，保存仍走原服务和 CPA 同步事务；不另建连接状态或请求任务。
    @State private var apiProtocol: CustomProviderAPIProtocol = .automatic
    @State private var prefix: String = ""
    @State private var apiKeys: [CustomAPIKeyEntry] = [CustomAPIKeyEntry(apiKey: "")]
    @State private var weightDrafts: [UUID: String] = [:]
    @State private var observedWeights: [UUID: Int] = [:]
    @State private var models: [ModelMapping] = []
    @State private var headers: [CustomHeader] = []
    @State private var isEnabled: Bool = true
    
    @State private var validationErrors: [String] = []
    @State private var showValidationAlert = false
    @State private var isTestingConnection = false
    @State private var testError: String?
    // 取消后可能仍收到此前请求的结果，关闭标记让旧表单失去保存资格。
    @State private var didCloseOfficialOpenAIAddition = false
    // 目录读取和保存验证同用一个任务，由现有表单在关闭时取消并释放。
    @State private var officialOpenAICatalogTask: Task<Void, Never>?
    
    // Model fetching state
    @State private var availableModels: [AvailableModel] = []
    @State private var selectedModelIds: Set<String> = []
    @State private var modelSearchText: String = ""
    @State private var isLoadingModels: Bool = false
    @State private var modelFetchError: String?
    @State private var limitToSelectedModels: Bool = true

    private static let selectableProviderTypes = CustomProviderType.allCases.filter {
        $0 != .clinePass
            && $0 != .deepseekCompatibility
            && $0 != .moonshotCompatibility
            && $0 != .minimaxCompatibility
    }

    private static let clinePassModels = [
        AvailableModel(id: "cline-pass/glm-5.2", name: "GLM-5.2", provider: "clinepass", isDefault: false),
        AvailableModel(id: "cline-pass/kimi-k3", name: "Kimi K3", provider: "clinepass", isDefault: false),
        AvailableModel(id: "cline-pass/kimi-k2.7-code", name: "Kimi K2.7 Code", provider: "clinepass", isDefault: false),
        AvailableModel(id: "cline-pass/kimi-k2.6", name: "Kimi K2.6", provider: "clinepass", isDefault: false),
        AvailableModel(id: "cline-pass/deepseek-v4-pro", name: "DeepSeek V4 Pro", provider: "clinepass", isDefault: false),
        AvailableModel(id: "cline-pass/deepseek-v4-flash", name: "DeepSeek V4 Flash", provider: "clinepass", isDefault: false),
        AvailableModel(id: "cline-pass/mimo-v2.5", name: "MiMo-V2.5", provider: "clinepass", isDefault: false),
        AvailableModel(id: "cline-pass/mimo-v2.5-pro", name: "MiMo-V2.5-Pro", provider: "clinepass", isDefault: false),
        AvailableModel(id: "cline-pass/minimax-m3", name: "MiniMax M3", provider: "clinepass", isDefault: false),
        AvailableModel(id: "cline-pass/qwen3.7-max", name: "Qwen3.7 Max", provider: "clinepass", isDefault: false),
        AvailableModel(id: "cline-pass/qwen3.7-plus", name: "Qwen3.7 Plus", provider: "clinepass", isDefault: false),
    ]
    
    private var isEditing: Bool {
        provider != nil
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Step 1: Provider name and type
                    if providerType != .clinePass {
                        basicInfoSection
                    }

                    if providerType == .openaiCompatibility {
                        // 默认收起，普通用户无需理解通道；保留显式 Chat 选择以兼容尚不支持 Responses 的旧型号。
                        DisclosureGroup("customProviders.protocol.advanced".localized()) {
                            VStack(alignment: .leading, spacing: 8) {
                                QuotioCapsuleSegmentedControl(options: CustomProviderAPIProtocol.allCases,
                                    selection: $apiProtocol, size: .small) { item, _ in
                                    Text(item.title)
                                }
                                Text("customProviders.protocol.info".localized())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.top, 8)
                        }
                    }

                    // Step 2: API Keys (needed before fetching models)
                    apiKeysSection

                    // Step 3: Model selection (requires API key to fetch)
                    if providerType.supportsModelMapping {
                        modelMappingSection
                    }

                    // Step 4: Custom headers (optional)
                    if providerType.supportsCustomHeaders && !isAddingOfficialOpenAI {
                        customHeadersSection
                    }

                    // Step 5: Enable toggle
                    if providerType != .clinePass {
                        enabledSection
                    }
                }
                .padding(20)
            }
            .disabled(isAddingOfficialOpenAI && isTestingConnection)

            footerView
        }
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
        .frame(width: 600, height: 700)
        .onAppear {
            loadProviderData()
        }
        .onDisappear {
            cancelOfficialOpenAIAddition()
        }
        .alert("customProviders.validationError".localized(), isPresented: $showValidationAlert) {
            Button("action.ok".localized(), role: .cancel) {
                testError = nil
            }
        } message: {
            if let error = testError {
                Text(error)
            } else {
                Text(validationErrors.joined(separator: "\n"))
            }
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(spacing: 16) {
            if providerType == .clinePass {
                ProviderIcon(provider: .clinePass, size: 24)
            } else {
                Image(providerType.menuBarIconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(isAddingOfficialOpenAI ? "customProviders.openAIOfficial".localized()
                    : isEditing ? "customProviders.edit".localized() : "customProviders.add".localized())
                    .font(.headline)
                
                Text(providerType.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            
            Spacer()

            // Close (26pt circular target per design spec)
            QuotioCircularIconButton(systemImage: "xmark") {
                closeSheet()
            }
            .accessibilityLabel("action.cancel".localized())
        }
        .padding(20)
    }

    // MARK: - Step Pill

    /// Compact capsule step badge (des-pill-002: 18pt height, 11pt semibold).
    private func stepPill(_ number: Int) -> some View {
        Text("Step \(number)")
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 18)
            .background(
                Capsule().fill(QuotioTheme.Colors.cardTag(for: colorScheme))
            )
    }
    
    // MARK: - Basic Info Section
    
    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("customProviders.basicInfo".localized())
                    .font(.headline)
                stepPill(1)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("customProviders.providerName".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                QuotioCapsuleTextField("e.g., OpenRouter, Ollama Local", text: $name)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("customProviders.providerType".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Menu {
                    ForEach(Self.selectableProviderTypes) { type in
                        Button {
                            providerType = type
                            if baseURL.isEmpty, let defaultURL = type.defaultBaseURL {
                                baseURL = defaultURL
                            }
                        } label: {
                            HStack {
                                Image(type.menuBarIconName)
                                Text(type.localizedDisplayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(providerType.menuBarIconName)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)

                        Text(providerType.localizedDisplayName)
                            .font(.body)
                            .foregroundStyle(.primary)

                        Spacer()

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(
                        Capsule().fill(QuotioTheme.Colors.cardInset(for: colorScheme))
                    )
                    .overlay(
                        Capsule().strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
                    )
                }
                .menuStyle(.borderlessButton)
                .disabled(isAddingOfficialOpenAI)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("customProviders.baseURL".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    if !providerType.requiresBaseURL, let defaultURL = providerType.defaultBaseURL {
                        Text("(default: \(defaultURL))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                
                if isAddingOfficialOpenAI {
                    // 官方地址以可读文本呈现。请求与保存从同一常量取值，表单草稿不参与寻址。
                    Text(CustomProvider.officialOpenAIBaseURL)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                } else {
                    QuotioCapsuleTextField(
                        providerType.defaultBaseURL ?? "https://api.example.com",
                        text: $baseURL,
                        systemImage: "network",
                        monospaced: true
                    )
                    .disabled(providerType == .clinePass)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("customProviders.prefix".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("(\("customProviders.optional".localized()))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                QuotioCapsuleTextField("customProviders.prefixHint".localized(), text: $prefix, systemImage: "tag")
            }
        }
        .quotioInsetCard()
    }

    // MARK: - API Keys Section

    private var apiKeysSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("customProviders.apiKeys".localized())
                    .font(.headline)
                stepPill(providerType == .clinePass ? 1 : 2)

                Spacer()

                if providerType != .clinePass && !isAddingOfficialOpenAI {
                    Button {
                        apiKeys.append(CustomAPIKeyEntry(apiKey: ""))
                    } label: {
                        Label("customProviders.addKey".localized(), systemImage: "plus")
                    }
                    .buttonStyle(.quotioMicroCapsule)
                }
            }

            ForEach(Array(apiKeys.enumerated()), id: \.offset) { index, _ in
                apiKeyRow(index: index)
            }
            Divider().opacity(0.3)
            CPAProviderWeightsSection(keys: apiKeys, observed: observedWeights, drafts: $weightDrafts, isCard: false)
        }
        .quotioInsetCard()
    }

    private func apiKeyRow(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("API Key #\(index + 1)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                if apiKeys.count > 1 {
                    QuotioCircularIconButton(systemImage: "trash", tint: .red, backgroundTint: .red) {
                        apiKeys.remove(at: index)
                    }
                }
            }

            QuotioCapsuleSecureField("customProviders.apiKeys".localized(), text: Binding(
                get: { apiKeys[safe: index]?.apiKey ?? "" },
                set: { key in
                    guard index < apiKeys.count else { return }
                    if isAddingOfficialOpenAI, apiKeys[index].apiKey != key {
                        // 模型权限随密钥变化。清除旧目录与选择，迟到的查询只在密钥仍匹配时回填。
                        availableModels = []
                        selectedModelIds = []
                        modelFetchError = nil
                    }
                    apiKeys[index].apiKey = key
                }
            ), systemImage: "key")

            if !isAddingOfficialOpenAI {
                QuotioCapsuleTextField("customProviders.proxyURL".localized(), text: Binding(
                    get: { apiKeys[safe: index]?.proxyURL ?? "" },
                    set: { if index < apiKeys.count { apiKeys[index].proxyURL = $0.isEmpty ? nil : $0 } }
                ), systemImage: "globe", monospaced: true)
            }
        }
        .padding(12)
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
        )
    }
    
    // MARK: - Model Mapping Section
    
    /// 只搜索当前接口实际返回的目录，不再维护“热门型号”白名单或注入静态候选。
    /// 保留服务返回的自定义／历史别名及所有条目；搜索覆盖完整目录，不会因热门区而隐藏剩余模型。
    nonisolated static func matchingModels(from models: [AvailableModel], search: String) -> [AvailableModel] {
        models.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search)
        }
    }

    private var modelMappingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("customProviders.modelMapping".localized())
                            .font(.headline)
                        stepPill(providerType == .clinePass ? 2 : 3)
                    }
                    
                    Text((isAddingOfficialOpenAI
                        ? "customProviders.selectModelsHint"
                        : "customProviders.modelMappingDesc").localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                if providerType != .clinePass {
                    if isLoadingModels {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Button {
                            fetchModelsFromAPI()
                        } label: {
                            Label("customProviders.fetchModels".localized(), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.quotioMicroCapsule)
                        .disabled(apiKeys.first?.apiKey.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
                    }
                }
            }
            
            // Limit models toggle
            if !isAddingOfficialOpenAI && !availableModels.isEmpty {
                Toggle(isOn: $limitToSelectedModels) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("customProviders.limitModels".localized())
                            .font(.subheadline)
                        Text("customProviders.limitModelsDesc".localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(providerType == .clinePass)
                
                if limitToSelectedModels && selectedModelIds.isEmpty {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                        Text("customProviders.selectModelsHint".localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // Show fetch error if any
            if let error = modelFetchError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Model selection interface
            if !availableModels.isEmpty {
                modelSelectionList
            } else if !isLoadingModels && !isAddingOfficialOpenAI {
                // Manual entry fallback
                manualModelEntry
            }
        }
        .quotioInsetCard()
    }

    private var modelSelectionList: some View {
        let models = Self.matchingModels(from: availableModels, search: modelSearchText)
        return VStack(alignment: .leading, spacing: 8) {
            // Search box
            QuotioCapsuleTextField("customProviders.searchModels".localized(), text: $modelSearchText, systemImage: "magnifyingglass")
            
            // All models (searchable)
            if !models.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if modelSearchText.isEmpty && !isAddingOfficialOpenAI {
                        Text("customProviders.allModels".localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(models) { model in
                                modelSelectionRow(model: model)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
            
            // Selected models count and actions
            if !selectedModelIds.isEmpty {
                HStack {
                    Text(String(format: "customProviders.selectedModels".localized(), selectedModelIds.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("customProviders.clearSelection".localized()) {
                        selectedModelIds.removeAll()
                    }
                    .buttonStyle(.quotioMicroCapsule)
                }
            }

            // Select All / Deselect All buttons
            if !availableModels.isEmpty {
                HStack(spacing: 8) {
                    Button("customProviders.selectAll".localized()) {
                        selectedModelIds = Set(availableModels.map { $0.id })
                    }
                    .buttonStyle(.quotioMicroCapsule)

                    Button("customProviders.deselectAll".localized()) {
                        selectedModelIds.removeAll()
                    }
                    .buttonStyle(.quotioMicroCapsule)
                }
            }
        }
    }

    private func modelSelectionRow(model: AvailableModel) -> some View {
        ModelSelectionRowView(
            model: model,
            isSelected: selectedModelIds.contains(model.id),
            onToggle: {
                if selectedModelIds.contains(model.id) {
                    selectedModelIds.remove(model.id)
                } else {
                    selectedModelIds.insert(model.id)
                }
            }
        )
    }

    private var manualModelEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("customProviders.enterManually".localized())
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button {
                models.append(ModelMapping(name: "", alias: ""))
            } label: {
                Label("customProviders.addMapping".localized(), systemImage: "plus")
            }
            .buttonStyle(.quotioMicroCapsule)

            if models.isEmpty {
                Text("customProviders.noMappings".localized())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(models.enumerated()), id: \.offset) { index, _ in
                    modelMappingRow(index: index)
                }
            }
        }
    }

    private func modelMappingRow(index: Int) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                QuotioCapsuleTextField("customProviders.upstreamModel".localized(), text: Binding(
                    get: { models[safe: index]?.name ?? "" },
                    set: { if index < models.count { models[index].name = $0 } }
                ))

                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)

                QuotioCapsuleTextField("customProviders.localAlias".localized(), text: Binding(
                    get: { models[safe: index]?.alias ?? "" },
                    set: { if index < models.count { models[index].alias = $0 } }
                ))

                QuotioCircularIconButton(systemImage: "trash", tint: .red, backgroundTint: .red) {
                    models.remove(at: index)
                }
            }

            HStack(spacing: 8) {
                Text("customProviders.thinkingBudget".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)

                QuotioCapsuleTextField("customProviders.thinkingBudgetHint".localized(), text: Binding(
                    get: { models[safe: index]?.thinkingBudget ?? "" },
                    set: { if index < models.count { models[index].thinkingBudget = $0.isEmpty ? nil : $0 } }
                ), showsClearButton: false)
                .frame(maxWidth: 200)

                Spacer()
            }
            .padding(.leading, 4)
        }
        .padding(12)
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
        )
    }

    // MARK: - Custom Headers Section

    private var customHeadersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("customProviders.customHeaders".localized())
                        .font(.headline)

                    Text("customProviders.customHeadersDesc".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    headers.append(CustomHeader(key: "", value: ""))
                } label: {
                    Label("customProviders.addHeader".localized(), systemImage: "plus")
                }
                .buttonStyle(.quotioMicroCapsule)
            }

            if headers.isEmpty {
                Text("customProviders.noHeaders".localized())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, _ in
                    customHeaderRow(index: index)
                }
            }
        }
        .quotioInsetCard()
    }

    private func customHeaderRow(index: Int) -> some View {
        HStack(spacing: 12) {
            QuotioCapsuleTextField("customProviders.headerName".localized(), text: Binding(
                get: { headers[safe: index]?.key ?? "" },
                set: { if index < headers.count { headers[index].key = $0 } }
            ), showsClearButton: false)

            Text(":")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)

            QuotioCapsuleTextField("customProviders.headerValue".localized(), text: Binding(
                get: { headers[safe: index]?.value ?? "" },
                set: { if index < headers.count { headers[index].value = $0 } }
            ), showsClearButton: false)

            QuotioCircularIconButton(systemImage: "trash", tint: .red, backgroundTint: .red) {
                headers.remove(at: index)
            }
        }
        .padding(10)
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
        )
    }

    // MARK: - Enabled Section

    private var enabledSection: some View {
        HStack {
            Toggle("customProviders.enableProvider".localized(), isOn: $isEnabled)
                .toggleStyle(.switch)
                .disabled(providerType == .clinePass)

            Spacer()

            if !isEnabled {
                Text("customProviders.disabledNote".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .quotioInsetCard()
    }
    
    // MARK: - Footer
    
    private var footerView: some View {
        HStack {
            Button("action.cancel".localized()) {
                closeSheet()
            }
            .buttonStyle(.quotioSecondaryCapsule)
            .keyboardShortcut(.escape)
            .disabled(isTestingConnection && !isAddingOfficialOpenAI)
            
            Spacer()
            
            if isTestingConnection {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("customProviders.testing".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            Button(isEditing ? "customProviders.saveChanges".localized() : "customProviders.addProvider".localized()) {
                saveProvider()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.quotioPrimaryCapsule)
            .disabled(isTestingConnection || (isAddingOfficialOpenAI && isLoadingModels))
        }
        .padding(20)
    }
    
    // MARK: - Actions

    private func closeSheet() {
        cancelOfficialOpenAIAddition()
        dismiss()
    }

    private func cancelOfficialOpenAIAddition() {
        guard isAddingOfficialOpenAI else { return }
        // 在弹窗动画或外层卸载前同步失效，防止取消时到达的响应回填表单或触发保存。
        didCloseOfficialOpenAIAddition = true
        officialOpenAICatalogTask?.cancel()
        officialOpenAICatalogTask = nil
    }
    
    private func loadProviderData() {
        guard let provider = provider else {
            if isAddingOfficialOpenAI { return }
            providerType = initialProviderType
            if initialProviderType == .clinePass {
                name = nextAvailableClinePassName()
                baseURL = initialProviderType.defaultBaseURL ?? ""
                apiKeys = [CustomAPIKeyEntry(apiKey: "")]
                availableModels = Self.clinePassModels
                limitToSelectedModels = true
                isEnabled = true
            }
            return
        }
        
        name = provider.type == .clinePass && provider.name.isEmpty
            ? nextAvailableClinePassName()
            : provider.name
        providerType = provider.type
        apiProtocol = provider.apiProtocol
        baseURL = provider.type == .clinePass
            ? (provider.type.defaultBaseURL ?? provider.baseURL)
            : normalizedBaseURL(provider.baseURL, for: provider.type)
        prefix = provider.prefix ?? ""
        apiKeys = provider.type == .clinePass
            ? [provider.apiKeys.first ?? CustomAPIKeyEntry(apiKey: "")]
            : provider.apiKeys
        // 旧本地 JSON 不含权重时，回填唯一匹配的 CPA 配置值；本轮未编辑的权重不会变成 1。
        observedWeights = CustomProviderService.shared.routingWeights(for: provider,
            configPath: CLIProxyManager.shared.configPath)
        models = provider.type == .clinePass ? [] : provider.models
        headers = provider.headers
        limitToSelectedModels = provider.type == .clinePass ? true : provider.limitToSelectedModels
        isEnabled = provider.type == .clinePass ? true : provider.isEnabled

        if provider.type == .clinePass {
            availableModels = Self.clinePassModels
        }
        
        // Set selected models from existing provider
        selectedModelIds = Set(provider.models.map { $0.name })
    }

    private func normalizedBaseURL(_ rawValue: String, for type: CustomProviderType) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (type == .openaiCompatibility || type == .codexCompatibility), !trimmed.isEmpty,
              var components = URLComponents(string: trimmed) else {
            return trimmed
        }

        if baseURLIncludesVersion(components.path) {
            return components.string ?? trimmed
        }

        if components.path.isEmpty || components.path == "/" {
            components.path = "/v1"
        } else if components.path.hasSuffix("/") {
            components.path += "v1"
        } else {
            components.path += "/v1"
        }

        return components.string ?? trimmed
    }

    private func makeModelsURL(baseURL rawBaseURL: String, providerType: CustomProviderType) -> URL? {
        let normalizedBaseURL = normalizedBaseURL(rawBaseURL, for: providerType)
        guard let url = URL(string: normalizedBaseURL) else { return nil }

        let endpoint = baseURLIncludesVersion(url.path) ? "models" : "v1/models"
        return url.appendingPathComponent(endpoint)
    }

    private func baseURLIncludesVersion(_ path: String) -> Bool {
        guard let lastSegment = path.split(separator: "/").last else { return false }
        return isVersionPathSegment(lastSegment)
    }

    private func isVersionPathSegment(_ segment: Substring) -> Bool {
        guard segment.first == "v" else { return false }

        let remainder = segment.dropFirst()
        guard let firstCharacter = remainder.first, firstCharacter.isNumber else {
            return false
        }

        return remainder.allSatisfy { $0.isNumber || $0.isLetter }
    }
    
    private func fetchModelsFromAPI() {
        if isAddingOfficialOpenAI {
            loadOfficialOpenAICatalog()
            return
        }

        if providerType == .clinePass {
            availableModels = Self.clinePassModels
            modelFetchError = nil
            return
        }

        guard let firstKey = apiKeys.first, !firstKey.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            modelFetchError = "Enter an API key first"
            return
        }
        
        let effectiveBaseURL = baseURL.isEmpty
            ? (providerType.defaultBaseURL ?? "")
            : normalizedBaseURL(baseURL, for: providerType)

        guard let modelsURL = makeModelsURL(baseURL: effectiveBaseURL, providerType: providerType) else {
            modelFetchError = "Invalid base URL"
            return
        }

        // Normalize the form's headers once, and validate before any of them touch the
        // request — the same canonical set is what gets persisted and emitted to YAML.
        let customHeaders = providerType.supportsCustomHeaders
            ? CustomHeader.canonicalized(headers)
            : []
        if let headerError = CustomHeader.validationErrors(in: customHeaders).first {
            modelFetchError = headerError
            return
        }

        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        
        // Set authorization header based on provider type
        switch providerType {
        case .openaiCompatibility, .codexCompatibility, .clinePass,
             .deepseekCompatibility, .moonshotCompatibility, .minimaxCompatibility:
            request.setValue("Bearer \(firstKey.apiKey)", forHTTPHeaderField: "Authorization")
        case .claudeCompatibility:
            request.setValue("Bearer \(firstKey.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .geminiCompatibility:
            var components = URLComponents(url: modelsURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "key", value: firstKey.apiKey)]
            if let newURL = components?.url {
                request.url = newURL
            }
        case .glmCompatibility:
            request.setValue("Bearer \(firstKey.apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        // Add custom headers (canonical form, already validated above)
        request.applyCustomHeaders(customHeaders)

        isLoadingModels = true
        modelFetchError = nil
        
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    await MainActor.run {
                        isLoadingModels = false
                        modelFetchError = "Invalid response"
                    }
                    return
                }
                
                guard httpResponse.statusCode == 200 else {
                    await MainActor.run {
                        isLoadingModels = false
                        modelFetchError = "Failed to fetch models: HTTP \(httpResponse.statusCode)"
                    }
                    return
                }
                
                let modelsResponse = try JSONDecoder().decode(ModelsListResponse.self, from: data)
                let fetchedModels = modelsResponse.allModels.map { $0.toAvailableModel() }
                
                await MainActor.run {
                    isLoadingModels = false
                    availableModels = fetchedModels.sorted { $0.name < $1.name }
                }
            } catch {
                await MainActor.run {
                    isLoadingModels = false
                    modelFetchError = "Failed to fetch models: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func saveProvider() {
        // 保存和刷新共用原表单任务的忙碌状态，连续快捷键不能提交两次或竞争更新目录。
        if isAddingOfficialOpenAI && (didCloseOfficialOpenAIAddition || isTestingConnection || isLoadingModels) { return }
        // Clear previous errors
        testError = nil
        let weightedKeys: [CustomAPIKeyEntry]
        do { weightedKeys = try CustomAPIKeyEntry.applyingRoutingWeights(apiKeys, drafts: weightDrafts, observed: observedWeights) }
        catch {
            testError = error.localizedDescription
            showValidationAlert = true
            return
        }
        
        // Convert selected model IDs to ModelMapping
        let selectedModelMappings = selectedModelIds.compactMap { modelId -> ModelMapping? in
            guard let model = availableModels.first(where: { $0.id == modelId }) else { return nil }
            return ModelMapping(name: model.id, alias: model.id)
        }
        
        // Merge with manually added models (deduplicate by name)
        var seenNames = Set<String>()
        var allModels: [ModelMapping] = []
        for model in models.filter({ !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }) + selectedModelMappings {
            if !seenNames.contains(model.name) {
                seenNames.insert(model.name)
                allModels.append(model)
            }
        }
        
        // Build provider
        let keysToSave: [CustomAPIKeyEntry]
        if isAddingOfficialOpenAI {
            // 只保存本轮探测的那把 Key，去掉粘贴时附带的空白，同时排除草稿中的代理配置。
            keysToSave = weightedKeys.prefix(1).compactMap { entry in
                var key = entry
                key.apiKey = key.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                key.proxyURL = nil
                return key.apiKey.isEmpty ? nil : key
            }
        } else {
            keysToSave = weightedKeys.filter { !$0.apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
        }

        let newProvider = CustomProvider(
            id: provider?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            type: isAddingOfficialOpenAI ? .openaiCompatibility : providerType,
            baseURL: isAddingOfficialOpenAI ? CustomProvider.officialOpenAIBaseURL
                : providerType == .clinePass ? (providerType.defaultBaseURL ?? baseURL)
                : normalizedBaseURL(baseURL, for: providerType),
            prefix: prefix.trimmingCharacters(in: .whitespaces).isEmpty ? nil : prefix.trimmingCharacters(in: .whitespaces),
            apiKeys: keysToSave,
            models: !isAddingOfficialOpenAI && limitToSelectedModels ? allModels : [],
            // 自定义头在一般表单可以覆盖 Authorization、Host，官方添加时不让它们进入请求或持久化数据。
            headers: providerType.supportsCustomHeaders && !isAddingOfficialOpenAI
                ? CustomHeader.canonicalized(headers)
                : [],
            limitToSelectedModels: isAddingOfficialOpenAI || limitToSelectedModels,
            isEnabled: isEnabled,
            createdAt: provider?.createdAt ?? Date(),
            updatedAt: Date(),
            apiProtocol: apiProtocol
        )
        
        // Validate basic fields
        validationErrors = CustomProviderService.shared.validateProvider(newProvider)
        
        if !validationErrors.isEmpty {
            showValidationAlert = true
            return
        }

        if isAddingOfficialOpenAI {
            loadOfficialOpenAICatalog(saving: newProvider)
            return
        }
        
        // Test connection before saving
        isTestingConnection = true
        
        Task {
            do {
                let success = try await testConnection(provider: newProvider)
                await MainActor.run {
                    isTestingConnection = false
                    if success {
                        onSave(newProvider)
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    isTestingConnection = false
                    testError = error.localizedDescription
                    showValidationAlert = true
                }
            }
        }
    }

    /// 官方添加只注册这把 Key 的最新目录中明确选中的模型。目录变化时拒绝保存，
    /// 由界面保留仍然可用的选择并提示复核，避免写入空目录或悄悄丢掉已选模型。
    static func verifiedOfficialOpenAIProvider(
        _ draft: CustomProvider,
        selectedIDs: Set<String>,
        catalog: [AvailableModel]
    ) -> CustomProvider? {
        let availableIDs = Set(catalog.map(\.id))
        guard !selectedIDs.isEmpty, selectedIDs.isSubset(of: availableIDs) else { return nil }
        var verified = draft
        verified.models = selectedIDs.sorted().map { ModelMapping(name: $0, alias: $0) }
        return verified
    }

    private func loadOfficialOpenAICatalog(saving draft: CustomProvider? = nil) {
        guard !didCloseOfficialOpenAIAddition, !isLoadingModels, !isTestingConnection,
              let key = apiKeys.first?.apiKey else { return }
        let requestedSelection = selectedModelIds
        let saving = draft != nil
        isTestingConnection = saving
        isLoadingModels = !saving
        modelFetchError = nil

        // 手动查询和点击添加使用同一条鉴权路径。首次直接点添加也会显示真实目录，
        // 但这轮只回填候选，用户选择至少一个模型后才能提交原保存回调。
        officialOpenAICatalogTask = Task {
            defer {
                if !didCloseOfficialOpenAIAddition {
                    officialOpenAICatalogTask = nil
                    isTestingConnection = false
                    isLoadingModels = false
                }
            }
            guard !Task.isCancelled else { return }
            do {
                let fetched = try await CustomProviderService.fetchOfficialOpenAIModels(apiKey: key)
                guard !Task.isCancelled, !didCloseOfficialOpenAIAddition, apiKeys.first?.apiKey == key else { return }
                let catalog = fetched.filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                availableModels = catalog.sorted { $0.name < $1.name }
                selectedModelIds.formIntersection(catalog.map(\.id))
                let emptyMessage = "customProviders.openAIOfficial.emptyModels".localized()
                if let draft {
                    guard let provider = Self.verifiedOfficialOpenAIProvider(
                        draft, selectedIDs: requestedSelection, catalog: catalog
                    ) else {
                        modelSearchText = ""
                        testError = catalog.isEmpty ? emptyMessage : "customProviders.openAIOfficial.selectModel".localized()
                        showValidationAlert = true
                        return
                    }
                    onSave(provider)
                    closeSheet()
                } else if catalog.isEmpty {
                    modelFetchError = emptyMessage
                }
            } catch {
                guard !Task.isCancelled, !didCloseOfficialOpenAIAddition, apiKeys.first?.apiKey == key else { return }
                let message = Self.officialOpenAIErrorMessage(error)
                if saving {
                    testError = message
                    showValidationAlert = true
                } else {
                    modelFetchError = message
                }
            }
        }
    }

    /// 目录读取与保存校验共用提示，保持 HTTP 错误的类型和原自定义表单文案各自独立。
    static func officialOpenAIErrorMessage(_ error: Error) -> String {
        if let connectionError = error as? CustomProviderTestError, case .unauthorized = connectionError {
            return "customProviders.openAIOfficial.unauthorized".localized()
        }
        return error.localizedDescription
    }
    
    private func testConnection(provider: CustomProvider) async throws -> Bool {
        guard let firstKey = provider.apiKeys.first else {
            throw CustomProviderTestError.noAPIKey
        }

        if provider.type == .clinePass {
            let quota = try await ClinePassQuotaFetcher().fetchQuota(apiKey: firstKey.apiKey)
            guard !quota.isForbidden else {
                throw CustomProviderTestError.unauthorized
            }
            return true
        }
        
        let effectiveBaseURL = provider.baseURL.isEmpty 
            ? (provider.type.defaultBaseURL ?? "")
            : provider.baseURL
        
        guard let modelsURL = makeModelsURL(baseURL: effectiveBaseURL, providerType: provider.type) else {
            throw CustomProviderTestError.invalidURL
        }

        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        
        // Set authorization header based on provider type
        switch provider.type {
        case .openaiCompatibility, .codexCompatibility, .clinePass,
             .deepseekCompatibility, .moonshotCompatibility, .minimaxCompatibility:
            request.setValue("Bearer \(firstKey.apiKey)", forHTTPHeaderField: "Authorization")
        case .claudeCompatibility:
            request.setValue("Bearer \(firstKey.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .geminiCompatibility:
            // Gemini uses query parameter for API key
            var components = URLComponents(url: modelsURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "key", value: firstKey.apiKey)]
            if let newURL = components?.url {
                request.url = newURL
            }
        case .glmCompatibility:
            request.setValue("Bearer \(firstKey.apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        // Add custom headers if any — the same canonical set that is written to the
        // generated CLIProxyAPI config, so the connection test exercises the real headers.
        request.applyCustomHeaders(provider.effectiveHeaders)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CustomProviderTestError.invalidResponse
        }
        
        switch httpResponse.statusCode {
        case 200..<300:
            return true
        case 401, 403:
            throw CustomProviderTestError.unauthorized
        case 404:
            throw CustomProviderTestError.endpointNotFound
        default:
            if let errorMessage = String(data: data, encoding: .utf8) {
                throw CustomProviderTestError.serverError(httpResponse.statusCode, errorMessage)
            }
            throw CustomProviderTestError.serverError(httpResponse.statusCode, "Unknown error")
        }
    }

    private func nextAvailableClinePassName() -> String {
        let baseName = "ClinePass"
        let existingNames = Set(CustomProviderService.shared.providers.map { $0.name.lowercased() })

        guard existingNames.contains(baseName.lowercased()) else {
            return baseName
        }

        var suffix = 2
        while existingNames.contains("\(baseName) \(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(baseName) \(suffix)"
    }
}

// MARK: - Models Response Parsing

private struct ModelsListResponse: Codable {
    let data: [ModelData]?
    let models: [ModelData]?
    
    var allModels: [ModelData] {
        data ?? models ?? []
    }
}

private struct ModelData: Codable {
    let id: String
    let name: String?
    let ownedBy: String?
    
    enum CodingKeys: String, CodingKey {
        case id, name
        case ownedBy = "owned_by"
    }
    
    func toAvailableModel() -> AvailableModel {
        AvailableModel(id: id, name: name ?? id, provider: ownedBy ?? "unknown", isDefault: false)
    }
}

// MARK: - Array Safe Subscript Extension

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Model Selection Row View

private struct ModelSelectionRowView: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: AvailableModel
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary.opacity(0.6))

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    if model.id != model.name {
                        Text(model.id)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
                    .fill(isHovered ? QuotioTheme.Colors.cardElevated(for: colorScheme).opacity(0.6) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 选中状态同时交给系统辅助功能，读屏不依赖圆形图标或强调色。
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Preview

#Preview {
    CustomProviderSheet(provider: nil) { provider in
        print("Saved: \(provider.name)")
    }
}
