//
//  GLMAPIKeySheet.swift
//  Quotio
//
//  Simplified API key configuration sheet for GLM (BigModel.cn / Z.ai)
//  with Capsule controls and persistent test connection state.
//

import SwiftUI

struct GLMAPIKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme

    let provider: CustomProvider?
    let onSave: (CustomProvider) -> Void

    // MARK: - Form State

    @State private var apiKey: String = ""
    @State private var endpoint: GLMEndpoint = .zai
    @State private var weightEntries = [CustomAPIKeyEntry(apiKey: "")]
    @State private var weightDrafts: [UUID: String] = [:]
    @State private var observedWeights: [UUID: Int] = [:]

    // 测试状态仍归本弹窗，两个弹窗只复用纯值提交规则，避免迟到响应覆盖新输入。
    @State private var connectionTest = ProviderConnectionTestState()
    private var isTesting: Bool { connectionTest.isTesting }
    private var testResult: ProviderConnectionTestState.Result? { connectionTest.result }

    @State private var validationError: String?
    @State private var showValidationAlert = false

    private var isEditing: Bool {
        provider != nil
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    apiKeySection
                    endpointSection
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
        .onDisappear { connectionTest.invalidate() }
        .alert("glm.validationError".localized(), isPresented: $showValidationAlert) {
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
            Image("glm")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "glm.edit".localized() : "glm.add".localized())
                    .font(.headline)

                Text("glm.description".localized())
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

    // MARK: - API Key Section

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("glm.apiKey".localized())
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("glm.apiKeyHint".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)

                QuotioCapsuleSecureField("glm.apiKeyPlaceholder".localized(), text: $apiKey, systemImage: "key")
                    .onChange(of: apiKey) {
                        connectionTest.invalidate()
                    }
            }
        }
        .quotioInsetCard()
    }

    // MARK: - Endpoint Section

    private var endpointSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("glm.endpoint".localized())
                .font(.headline)

            Text("glm.endpointHint".localized())
                .font(.caption)
                .foregroundStyle(.secondary)

            QuotioCapsuleSegmentedControl(
                GLMEndpoint.allCases,
                selection: $endpoint,
                size: .medium,
                tint: QuotioTheme.Colors.claudeOrange,
                isEqualWidth: true,
                title: { $0.displayName }
            )
            .accessibilityLabel("glm.endpoint".localized())
            .onChange(of: endpoint) {
                connectionTest.invalidate()
            }
        }
        .quotioInsetCard()
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
            validationError = "glm.error.emptyApiKey".localized()
            showValidationAlert = true
            return
        }

        let request = connectionTest.begin(baseURL: endpoint.baseURL, apiKey: trimmedKey)
        Task {
            do {
                let outcome = try await CustomProviderService.testConnection(
                    providerType: .glmCompatibility, baseURL: request.baseURL, apiKey: request.apiKey)
                connectionTest.complete(request, baseURL: endpoint.baseURL, apiKey: apiKey,
                    result: .init(success: outcome.success, latencyMs: outcome.latencyMs, message: "OK"))
            } catch {
                connectionTest.complete(request, baseURL: endpoint.baseURL, apiKey: apiKey,
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

            Button(isEditing ? "glm.saveChanges".localized() : "glm.addProvider".localized()) {
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
            weightEntries = provider.apiKeys.isEmpty ? weightEntries : provider.apiKeys
            observedWeights = CustomProviderService.shared.routingWeights(for: provider,
                configPath: viewModel.proxyManager.configPath)
        }
        guard let provider = provider else { return }

        // Load API key from first entry
        if let firstKey = provider.apiKeys.first {
            apiKey = firstKey.apiKey
        }

        // Determine endpoint from base URL
        if provider.baseURL.contains("bigmodel.cn") {
            endpoint = .bigmodel
        } else {
            endpoint = .zai
        }
    }

    private func saveProvider() {
        // Validate
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedKey.isEmpty {
            validationError = "glm.error.emptyApiKey".localized()
            showValidationAlert = true
            return
        }

        var newProvider = GLMProviderEditor.updatedProvider(
            provider,
            apiKey: trimmedKey,
            endpoint: endpoint
        )

        do {
            let weighted = try CustomAPIKeyEntry.applyingRoutingWeights(weightEntries, drafts: weightDrafts, observed: observedWeights)
            for index in newProvider.apiKeys.indices {
                let entry = weighted.first { $0.id == newProvider.apiKeys[index].id }
                    ?? (index == 0 ? weighted.first : nil)
                if let entry {
                    newProvider.apiKeys[index].weight = entry.weight
                    newProvider.apiKeys[index].weightRevision = entry.weightRevision
                }
            }
        } catch {
            validationError = error.localizedDescription
            showValidationAlert = true
            return
        }

        onSave(newProvider)
        dismiss()
    }
}

enum GLMProviderEditor {
    static func updatedProvider(
        _ existing: CustomProvider?,
        apiKey: String,
        endpoint: GLMEndpoint,
        now: Date = Date()
    ) -> CustomProvider {
        guard var provider = existing else {
            return CustomProvider(
                name: "Z.ai",
                type: .glmCompatibility,
                baseURL: endpoint.baseURL,
                apiKeys: [CustomAPIKeyEntry(apiKey: apiKey)],
                createdAt: now,
                updatedAt: now
            )
        }

        provider.baseURL = endpoint.baseURL
        if provider.apiKeys.isEmpty {
            provider.apiKeys.append(CustomAPIKeyEntry(apiKey: apiKey))
        } else {
            provider.apiKeys[0].apiKey = apiKey
        }
        provider.updatedAt = now
        return provider
    }
}

// MARK: - GLM Endpoint

enum GLMEndpoint: String, CaseIterable, Codable, Identifiable, Sendable {
    case zai
    case bigmodel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zai: return "Z.ai (Global)"
        case .bigmodel: return "bigmodel.cn (国内)"
        }
    }

    var baseURL: String {
        switch self {
        case .zai: return "https://api.z.ai"
        case .bigmodel: return "https://bigmodel.cn"
        }
    }
}
