//
//  MainstreamProviderAPIKeySheet.swift
//  Quotio
//
//  API key configuration sheet for mainstream AI platforms (DeepSeek, Moonshot/Kimi, MiniMax)
//  matching Magpie preset conventions and Quotio's Capsule design system.
//

import SwiftUI

struct MainstreamProviderAPIKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme

    let targetProvider: AIProvider
    let provider: CustomProvider?
    let onSave: (CustomProvider) -> Void

    // MARK: - Form State

    @State private var connectionName: String = ""
    @State private var apiKey: String = ""
    @State private var selectedBaseURL: String = ""
    @State private var weightEntries = [CustomAPIKeyEntry(apiKey: "")]
    @State private var weightDrafts: [UUID: String] = [:]
    @State private var observedWeights: [UUID: Int] = [:]
    /// 模型映射仍是本连接表单的草稿，刷新失败和切换节点均不清空用户已有的模型或别名。
    @State private var models: [ModelMapping] = []
    @State private var modelRequest: ProviderConnectionTestState.Request?
    @State private var modelFetchError: String?


    // 测试状态仍归本弹窗，两个弹窗只复用纯值提交规则，避免迟到响应覆盖新输入。
    @State private var connectionTest = ProviderConnectionTestState()
    private var isTesting: Bool { connectionTest.isTesting }
    private var testResult: ProviderConnectionTestState.Result? { connectionTest.result }

    @State private var validationError: String?
    @State private var showValidationAlert = false

    private var isEditing: Bool {
        provider != nil
    }

    private var customType: CustomProviderType {
        switch targetProvider {
        case .deepseek: return .deepseekCompatibility
        case .moonshot: return .moonshotCompatibility
        case .minimax: return .minimaxCompatibility
        default: return .deepseekCompatibility
        }
    }

    private var effectiveBaseURL: String {
        selectedBaseURL.isEmpty ? (customType.defaultBaseURL ?? "") : selectedBaseURL
    }

    private var availableEndpoints: [(name: String, url: String)] {
        switch targetProvider {
        case .deepseek:
            return [("api.deepseek.com", "https://api.deepseek.com")]
        case .moonshot:
            return [
                ("api.moonshot.cn (国内)", "https://api.moonshot.cn/v1"),
                ("api.moonshot.ai (Global)", "https://api.moonshot.ai/v1")
            ]
        case .minimax:
            return [
                ("api.minimaxi.com (国内)", "https://api.minimaxi.com/v1"),
                ("api.minimax.chat (Global)", "https://api.minimax.chat/v1")
            ]
        default:
            return [(customType.defaultBaseURL ?? "", customType.defaultBaseURL ?? "")]
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nameSection
                    apiKeySection
                    if availableEndpoints.count > 1 {
                        endpointSection
                    }
                    modelMappingSection
                    testConnectionSection
                    CPAProviderWeightsSection(keys: weightEntries, observed: observedWeights, drafts: $weightDrafts)
                }
                .padding(20)
            }

            footerView
        }
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
        .frame(width: 500, height: 540)
        .onAppear {
            loadProviderData()
        }
        .onDisappear {
            connectionTest.invalidate()
            modelRequest = nil
        }
        .alert("customProviders.validationError".localized(), isPresented: $showValidationAlert) {
            Button("action.ok".localized(), role: .cancel) {}
        } message: {
            if let error = validationError {
                Text(error)
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 16) {
            ProviderIcon(provider: targetProvider, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "编辑 \(targetProvider.displayName) 账号" : "添加 \(targetProvider.displayName) 账号")
                    .font(.headline)

                Text(customType.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            QuotioCircularIconButton(systemImage: "xmark") {
                dismiss()
            }
            .accessibilityLabel("action.cancel".localized())
        }
        .padding(20)
    }

    // MARK: - Name Section

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("连接名称")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("用于在账号列表和菜单栏中标识该服务商连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                QuotioCapsuleTextField("例如: \(targetProvider.displayName) 主账号", text: $connectionName, systemImage: "tag")
            }
        }
        .quotioInsetCard()
    }

    // MARK: - API Key Section

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("API 密钥 (API Key)")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("输入该服务商开放平台生成的 API Key")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                QuotioCapsuleSecureField("输入 API 密钥...", text: $apiKey, systemImage: "key")
                    .onChange(of: apiKey) {
                        connectionTest.invalidate()
                        modelRequest = nil
                    }
            }
        }
        .quotioInsetCard()
    }

    // MARK: - Endpoint Section

    private var endpointSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("服务节点 / Endpoint")
                .font(.headline)

            Text("选择 API 请求的基础接入地址")
                .font(.caption)
                .foregroundStyle(.secondary)

            QuotioCapsuleSegmentedControl(
                availableEndpoints.map(\.url),
                selection: $selectedBaseURL,
                size: .medium,
                tint: QuotioTheme.Colors.claudeOrange,
                isEqualWidth: true,
                title: { url in
                    availableEndpoints.first(where: { $0.url == url })?.name ?? url
                }
            )
            .accessibilityLabel("服务节点")
            .onChange(of: selectedBaseURL) {
                connectionTest.invalidate()
                modelRequest = nil
            }
        }
        .quotioInsetCard()
    }

    /// 账号连接必须携带实际模型映射才能注册到 CPA。目录与手填共用原 ModelMapping，
    /// 不猜测固定型号，不重建 provider，已有前缀、密钥、别名和高级字段继续沿用原对象。
    private var modelMappingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("customProviders.modelMapping".localized()).font(.headline)
                Spacer()
                Button {
                    fetchProviderModels()
                } label: {
                    if modelRequest != nil { SmallProgressView() }
                    else { Label("customProviders.fetchModels".localized(), systemImage: "arrow.clockwise") }
                }
                .buttonStyle(.quotioMicroCapsule)
                .disabled(modelRequest != nil || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("customProviders.modelMappingDesc".localized())
                .font(.caption).foregroundStyle(.secondary)
            if let modelFetchError {
                Text(modelFetchError).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach($models) { $model in
                HStack(spacing: 6) {
                    QuotioCapsuleTextField("customProviders.upstreamModel".localized(), text: $model.name)
                    QuotioCapsuleTextField("customProviders.localAlias".localized(), text: $model.alias)
                    Button(role: .destructive) { models.removeAll { $0.id == model.id } } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("action.delete".localized())
                }
            }
            Button {
                models.append(ModelMapping(name: "", alias: ""))
            } label: {
                Label("customProviders.addMapping".localized(), systemImage: "plus")
            }
            .buttonStyle(.quotioMicroCapsule)
        }
        .quotioInsetCard()
    }

    private func fetchProviderModels() {
        let request = ProviderConnectionTestState.Request(baseURL: effectiveBaseURL, apiKey: apiKey)
        guard !request.apiKey.isEmpty else { return }
        modelRequest = request
        modelFetchError = nil
        Task {
            do {
                let catalog = try await CustomProviderService.fetchProviderModels(
                    providerType: customType, baseURL: request.baseURL, apiKey: request.apiKey)
                // 编辑、关闭或重新读取后，旧响应既不能追加模型，也不能释放新请求的加载状态。
                guard modelRequest == request else { return }
                modelRequest = nil
                guard request.matches(baseURL: effectiveBaseURL, apiKey: apiKey), !Task.isCancelled else { return }
                models = CustomProviderService.mergingProviderModels(models, catalog: catalog)
                if catalog.isEmpty { modelFetchError = "agents.models.empty".localized() }
            } catch {
                guard modelRequest == request else { return }
                modelRequest = nil
                guard request.matches(baseURL: effectiveBaseURL, apiKey: apiKey), !Task.isCancelled else { return }
                modelFetchError = "agents.models.failed".localized() + " " + error.localizedDescription
            }
        }
    }

    // MARK: - Test Connection Section

    private var testConnectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Label("agents.testConnection".localized(), systemImage: "network")
                    .font(.subheadline.weight(.medium))

                Spacer()

                if isTesting {
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
                } else if let result = testResult {
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
                    runConnectionTest()
                } label: {
                    HStack(spacing: 4) {
                        if isTesting {
                            SmallProgressView()
                        } else {
                            Image(systemName: testResult == nil ? "bolt.fill" : "arrow.clockwise")
                        }
                        Text(testResult == nil ? "agents.test".localized() : "action.retry".localized())
                    }
                    .font(.caption)
                }
                .buttonStyle(.quotioMicroCapsule)
                .controlSize(.small)
                .disabled(isTesting || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(isTesting ? 0.5 : 1)
            }

            if let result = testResult, !result.success {
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
            }
        }
        .quotioInsetCard()
    }

    private func runConnectionTest() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            validationError = "API 密钥不能为空"
            showValidationAlert = true
            return
        }

        let request = connectionTest.begin(baseURL: effectiveBaseURL, apiKey: trimmedKey)
        Task {
            do {
                let outcome = try await CustomProviderService.testConnection(
                    providerType: customType, baseURL: request.baseURL, apiKey: request.apiKey)
                connectionTest.complete(request, baseURL: effectiveBaseURL, apiKey: apiKey,
                    result: .init(success: outcome.success, latencyMs: outcome.latencyMs, message: "OK"))
            } catch {
                connectionTest.complete(request, baseURL: effectiveBaseURL, apiKey: apiKey,
                    result: .init(success: false, latencyMs: nil, message: error.localizedDescription))
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("action.cancel".localized()) {
                dismiss()
            }
            .buttonStyle(.quotioSecondaryCapsule)
            .keyboardShortcut(.escape)

            Spacer()

            Button(isEditing ? "action.save".localized() : "action.add".localized()) {
                saveProvider()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.quotioPrimaryCapsule)
        }
        .padding(20)
    }

    // MARK: - Actions

    private func loadProviderData() {
        if let provider {
            models = provider.models
            connectionName = provider.name
            selectedBaseURL = provider.baseURL.isEmpty ? (customType.defaultBaseURL ?? "") : provider.baseURL
            weightEntries = provider.apiKeys.isEmpty ? weightEntries : provider.apiKeys
            observedWeights = CustomProviderService.shared.routingWeights(for: provider,
                configPath: viewModel.proxyManager.configPath)
            if let firstKey = provider.apiKeys.first {
                apiKey = firstKey.apiKey
            }
        } else {
            connectionName = targetProvider.displayName
            selectedBaseURL = availableEndpoints.first?.url ?? (customType.defaultBaseURL ?? "")
        }
    }

    private func saveProvider() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = connectionName.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedKey.isEmpty {
            validationError = "API 密钥不能为空"
            showValidationAlert = true
            return
        }

        let effectiveName = trimmedName.isEmpty ? targetProvider.displayName : trimmedName
        let effectiveURL = selectedBaseURL.isEmpty ? (customType.defaultBaseURL ?? "") : selectedBaseURL

        // 新连接不得保存成 CPA 无法注册的空模型组。旧条目只规范化本次可编辑字段，
        // alias 留空时沿用上游 ID；目录失败仍可明确手填，不以静态型号掩盖失败。
        let mappings = models.map { model in
            var value = model
            value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            value.alias = value.alias.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.alias.isEmpty { value.alias = value.name }
            return value
        }
        guard !mappings.isEmpty, mappings.allSatisfy({ !$0.name.isEmpty }) else {
            validationError = "customProviders.models.required".localized()
            showValidationAlert = true
            return
        }

        let now = Date()
        var updated = provider ?? CustomProvider(
            name: effectiveName,
            type: customType,
            baseURL: effectiveURL,
            apiKeys: [CustomAPIKeyEntry(apiKey: trimmedKey)],
            createdAt: now,
            updatedAt: now
        )

        updated.models = mappings
        updated.name = effectiveName
        updated.baseURL = effectiveURL
        if updated.apiKeys.isEmpty {
            updated.apiKeys = [CustomAPIKeyEntry(apiKey: trimmedKey)]
        } else {
            updated.apiKeys[0].apiKey = trimmedKey
        }
        updated.updatedAt = now

        do {
            let weighted = try CustomAPIKeyEntry.applyingRoutingWeights(weightEntries, drafts: weightDrafts, observed: observedWeights)
            for index in updated.apiKeys.indices {
                let entry = weighted.first { $0.id == updated.apiKeys[index].id }
                    ?? (index == 0 ? weighted.first : nil)
                if let entry {
                    updated.apiKeys[index].weight = entry.weight
                    updated.apiKeys[index].weightRevision = entry.weightRevision
                }
            }
        } catch {
            validationError = error.localizedDescription
            showValidationAlert = true
            return
        }

        onSave(updated)
        dismiss()
    }
}
