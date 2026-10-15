//
//  ProxySettingsSection.swift
//  Quotio
//

// CPA 设置完整分区，按原 scope 展示网络、请求或日志选项；本文件不拆分表单状态。
// 原草稿、保存基线、读取抑制、保存锁和 task(id:) 继续由同一个视图实例管理，
// 保留原有 v8 读取、精确保存与错误反馈，文件拆分不改变配置键和任务生命周期。

import SwiftUI
import AppKit

// MARK: - Proxy Settings Section
// Uses ManagementAPIClient for hot-reload settings

struct ProxySettingsSection: View {
    /// 展示范围只决定哪些卡片可见；所有范围复用原有加载和保存函数，避免配置实现分叉。
    enum Scope { case all, network, requests, logging }
    var scope: Scope = .all
    @State private var saveError: String?
    @Environment(QuotaViewModel.self) private var viewModel
    
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isLoadingConfig = false  // Prevents onChange from firing during load

    @State private var proxyURL = ""
    @State private var savedProxyURL = ""
    @State private var isSavingProxyURL = false
    @State private var routingStrategy = "round-robin"
    @State private var sessionAffinity = false
    @State private var isSaving = false
    /// 草稿与服务器读取基线分开，展开高级选项不会写配置；两个分类各自确认保存范围。
    @State private var advancedDraft = CPAAdvancedSettingsDraft()
    @State private var savedAdvancedDraft = CPAAdvancedSettingsDraft()
    @State private var requestsAdvancedExpanded = false
    @State private var loggingAdvancedExpanded = false
    @State private var requestRetry = 0
    @State private var maxRetryInterval = 0
    // 与代理默认配置保持一致；加载完成后以管理 API 返回的实时值覆盖。
    @State private var debugMode = false
    
    @State private var proxyURLValidation: ProxyURLValidationResult = .empty
    
    private var isAPIAvailable: Bool {
        viewModel.proxyManager.proxyStatus.running && viewModel.apiClient != nil
    }
    
    var body: some View {
        Group {
            if !isAPIAvailable {
                Section {
                    Label("settings.proxy.startToConfigureAdvanced".localized(), systemImage: "network.slash")
                        .foregroundStyle(.secondary)
                } header: {
                    Label("settings.proxySettings".localized(), systemImage: "slider.horizontal.3")
                }
            } else if isLoading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("settings.proxy.loading".localized()).foregroundStyle(.secondary)
                    }
                } header: {
                    Label("settings.proxySettings".localized(), systemImage: "slider.horizontal.3")
                }
            } else if let error = loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.secondary)
                    Button("action.retry".localized()) { Task { await loadConfig() } }
                } header: {
                    Label("settings.proxySettings".localized(), systemImage: "slider.horizontal.3")
                }
            } else {
                if isSaving {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("settings.cpa.saving".localized()).foregroundStyle(.secondary)
                        }
                    }
                }
                if scope == .all || scope == .network { upstreamProxySection }
                if scope == .all || scope == .requests {
                    routingStrategySection
                    // CPA 8 不提供旧版“额度不足切换账号／预览模型”配置项。
                    // 故障转移继续由内核的路由与重试策略控制，页面只展示可通过 v8 管理的设置。
                    retryConfigurationSection
                }
                if scope == .all || scope == .logging { loggingSection }
            }
        }
        // 保存期间阻止连点产生先后响应倒置；失败仍通过现有弹窗提供重新读取入口。
        .disabled(isSaving)
        // 分类页出现或服务可用性变化时读取最新配置；读取不会触发 onChange 的写入。
        .task(id: isAPIAvailable) {
            if isAPIAvailable { await loadConfig() }
        }
        .alert("settings.navigation.saveFailed".localized(), isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("settings.navigation.reload".localized()) {
                saveError = nil
                Task { await loadConfig() }
            }
            Button("action.close".localized(), role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private var canApplyProxyURL: Bool {
        guard !isSavingProxyURL && !isSaving else { return false }
        guard proxyURLValidation.isValid else { return false }
        return proxyURL != savedProxyURL
    }

    private var upstreamProxySection: some View {
        Section {
            QuotioInlineApplyField(
                titleKey: "settings.upstreamProxy",
                placeholderKey: "settings.upstreamProxy.placeholder",
                text: $proxyURL,
                savedText: savedProxyURL,
                isValid: proxyURLValidation.isValid,
                validationErrorMessage: (proxyURLValidation != .valid && proxyURLValidation != .empty)
                    ? (proxyURLValidation.localizationKey ?? "").localized()
                    : nil,
                isSaving: isSavingProxyURL,
                accessibilityPrefix: "settings.upstreamProxy"
            ) {
                await saveProxyURL()
            }
            .onChange(of: proxyURL) { _, newValue in
                proxyURLValidation = ProxyURLValidator.validate(newValue)
            }
        } header: {
            Label("settings.upstreamProxy.title".localized(), systemImage: "network")
        }
    }
    
    private var routingStrategySection: some View {
        CPARoutingPolicySection(strategy: $routingStrategy, sessionAffinity: $sessionAffinity)
            .onChange(of: routingStrategy) { _, newValue in
                guard !isLoadingConfig else { return }
                saveRoutingStrategy(newValue)
            }
            .onChange(of: sessionAffinity) { _, newValue in
                guard !isLoadingConfig else { return }
                saveSessionAffinity(newValue)
            }
    }

    private var retryConfigurationSection: some View {
        Section {
            Stepper("settings.maxRetries".localized() + ": \(requestRetry)", value: $requestRetry, in: 0...10)
                .onChange(of: requestRetry) { _, newValue in
                    guard !isLoadingConfig else { return }
                    saveRequestRetry(newValue)
                }
            
            // 0 是 CPA 支持的“不等待冷却”，不能把未设置或显式 0 自动提升到五秒。
            Stepper("settings.maxRetryInterval".localized() + ": \(maxRetryInterval)s", value: $maxRetryInterval, in: 0...300, step: 5)
                .onChange(of: maxRetryInterval) { _, newValue in
                    guard !isLoadingConfig else { return }
                    saveMaxRetryInterval(newValue)
                }

            CPAAdvancedSettingsOptions(scope: .requests, sessionAffinity: sessionAffinity,
                draft: $advancedDraft, isExpanded: $requestsAdvancedExpanded,
                hasChanges: advancedDraft.hasChanges(comparedTo: savedAdvancedDraft, scope: .requests)) {
                Task { await saveAdvancedSettings(scope: .requests) }
            }
        } header: {
            Label("settings.retryConfiguration".localized(), systemImage: "arrow.clockwise")
        } footer: {
            Text("settings.retryHelp".localized())
                .font(.caption)
            Text("settings.retryZeroIntervalHelp".localized())
                .font(.caption)
        }
    }

    private var loggingSection: some View {
        Section {
            Toggle("settings.debugMode".localized(), isOn: $debugMode)
                .onChange(of: debugMode) { _, newValue in
                    guard !isLoadingConfig else { return }
                    saveDebugMode(newValue)
                }

            CPAAdvancedSettingsOptions(scope: .logging, requestLog: debugMode,
                draft: $advancedDraft, isExpanded: $loggingAdvancedExpanded,
                hasChanges: advancedDraft.hasChanges(comparedTo: savedAdvancedDraft, scope: .logging)) {
                Task { await saveAdvancedSettings(scope: .logging) }
            }
        } header: {
            Label("settings.logging".localized(), systemImage: "doc.text")
        } footer: {
            Text("settings.loggingHelp".localized())
                .font(.caption)
        }
    }
    
    private func loadConfig() async {
        isLoading = true
        isLoadingConfig = true
        loadError = nil
        
        guard let apiClient = viewModel.apiClient else {
            loadError = "settings.proxy.startToConfigureAdvanced".localized()
            isLoading = false
            isLoadingConfig = false
            return
        }
        
        do {
            async let configTask = apiClient.fetchConfig()
            async let routingTask = apiClient.getRoutingStrategy()
            
            let (config, fetchedStrategy) = try await (configTask, routingTask)
            guard !Task.isCancelled else { return }
            
            proxyURL = config.proxyURL ?? ""
            savedProxyURL = proxyURL
            routingStrategy = CPARoutingStrategy.canonicalValue(fetchedStrategy)
            sessionAffinity = config.sessionAffinity ?? false
            advancedDraft = CPAAdvancedSettingsDraft(config: config)
            savedAdvancedDraft = advancedDraft
            // 模板推荐 3/30 仅适用于文件明确声明；缺省运行值为 0/0，负数也按有效零值展示。
            requestRetry = max(0, config.requestRetry ?? 0)
            maxRetryInterval = max(0, config.maxRetryInterval ?? 0)
            debugMode = (config.debug ?? false) || (config.loggingToFile ?? false) || (config.requestLog ?? false)
            proxyURLValidation = ProxyURLValidator.validate(proxyURL)
            isLoading = false

            try? await Task.sleep(for: .milliseconds(100))
            isLoadingConfig = false
        } catch {
            loadError = error.localizedDescription
            isLoading = false
            isLoadingConfig = false
        }
    }

    /// Persists the upstream proxy URL to both UserDefaults and the running proxy instance.
    ///
    /// The URL is first saved to UserDefaults so it survives app restarts (used by
    /// `CLIProxyManager.syncProxyURLInConfig()` during proxy startup), then sent to the
    /// proxy API to take effect immediately. Only valid or empty URLs are saved.
    private func saveProxyURL() async {
        guard canApplyProxyURL else { return }
        isSavingProxyURL = true
        defer { isSavingProxyURL = false }

        if proxyURL.isEmpty {
            UserDefaults.standard.set("", forKey: "proxyURL")
        } else if proxyURLValidation == .valid {
            UserDefaults.standard.set(ProxyURLValidator.sanitize(proxyURL), forKey: "proxyURL")
        }

        guard let apiClient = viewModel.apiClient else { return }
        do {
            if proxyURL.isEmpty {
                try await apiClient.deleteProxyURL()
                savedProxyURL = ""
            } else if proxyURLValidation == .valid {
                let sanitized = ProxyURLValidator.sanitize(proxyURL)
                try await apiClient.setProxyURL(sanitized)
                savedProxyURL = proxyURL
            }
        } catch {
            NSLog("[ProxySettings] Failed to save proxy URL: \(error)")
            saveError = error.localizedDescription
        }
    }
    
    /// 在同步点击回调中先锁定表单，再启动网络任务，避免同一帧连点产生乱序保存。
    /// 闭包捕获本次客户端和值；只读加载直接赋值状态，仍由 isLoadingConfig 阻止写入。
    private func saveScalar(_ mutation: @escaping @MainActor () async throws -> Void) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do { try await mutation() }
            catch { saveError = error.localizedDescription }
        }
    }

    private func saveRoutingStrategy(_ strategy: String) {
        guard let apiClient = viewModel.apiClient else { return }
        saveScalar { try await apiClient.setRoutingStrategy(strategy) }
    }

    private func saveSessionAffinity(_ enabled: Bool) {
        guard let apiClient = viewModel.apiClient else { return }
        saveScalar { try await apiClient.setSessionAffinity(enabled) }
    }

    private func saveAdvancedSettings(scope: CPAAdvancedSettingsDraft.Scope) async {
        guard !isSaving, let apiClient = viewModel.apiClient else { return }
        // 冻结本次草稿，确认后只推进对应区域的保存基线；服务端错误不吞掉用户输入。
        let submittedDraft = advancedDraft
        do {
            guard let patch = try submittedDraft.patch(comparedTo: savedAdvancedDraft, scope: scope) else { return }
            isSaving = true
            defer { isSaving = false }
            try await apiClient.patchV8Config(patch)
            savedAdvancedDraft.accept(submittedDraft, scope: scope)
        } catch { saveError = error.localizedDescription }
    }
    
    private func saveRequestRetry(_ count: Int) {
        guard let apiClient = viewModel.apiClient else { return }
        saveScalar { try await apiClient.setRequestRetry(count) }
    }
    
    private func saveMaxRetryInterval(_ seconds: Int) {
        guard let apiClient = viewModel.apiClient else { return }
        saveScalar { try await apiClient.setMaxRetryInterval(seconds) }
    }
    
    private func saveDebugMode(_ enabled: Bool) {
        guard let apiClient = viewModel.apiClient else { return }
        saveScalar { try await apiClient.setDebugLogging(enabled) }
    }
}

