//
//  SettingsScreen.swift
//  Quotio
//

import SwiftUI
import AppKit

/// 设置内部只建立一个系统导航栈；系统负责 Push、返回按钮、标题与键盘导航。
/// 应用模式只在根页面编辑，返回根页面的定位操作不写入任何业务配置。
struct SettingsScreen: View {
    var opensLogs = false
    @State private var path = NavigationPath()
    @State private var search = ""
    @State private var modeFocusRequest = UUID()

    var body: some View {
        NavigationStack(path: $path) {
            SettingsOverviewScreen(search: $search, modeFocusRequest: modeFocusRequest)
                .navigationDestination(for: SettingsDestination.self) { destination in
                    SettingsCategoryScreen(destination: destination, onShowMode: showMode)
                }
                .navigationDestination(for: SettingsAuxiliaryPage.self) { page in
                    switch page {
                    case .aliases: SettingsModelAliasesScreen()
                    case .agents: AgentSetupScreen()
                    case .logs: LogsScreen()
                    case .about: AboutScreen()
                    case .upstreamUpdates: UpstreamUpdatesScreen()
                    case .storageData: StorageDataDestination()
                    }
                }
        }
        .modifier(SettingsPageBackground())
        .onAppear {
            // 异常快捷入口复用设置导航栈，不创建没有返回按钮的独立日志页。
            if opensLogs && path.isEmpty {
                path.append(SettingsDestination(category: .maintenance))
                path.append(SettingsAuxiliaryPage.logs)
            }
        }
    }

    private func showMode() {
        search = ""
        path = NavigationPath()
        modeFocusRequest = UUID()
    }
}

// MARK: - Operating Mode Section

struct OperatingModeSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var modeManager = OperatingModeManager.shared
    @State private var showModeChangeConfirmation = false
    @State private var pendingMode: OperatingMode?
    
    var body: some View {
        Section {
            // 复用原有模式卡片的图标、徽标和选中效果，两个弹性列各占一半可用宽度。
            // 点击仍进入原来的确认与切换流程，不因布局调整直接写入运行模式。
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(OperatingMode.allCases) { mode in
                    OperatingModeCard(
                        mode: mode,
                        isSelected: modeManager.currentMode == mode,
                        onSelect: { handleModeSelection(mode) }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 4)
            DisclosureGroup("settings.navigation.mode.features".localized()) {
                ForEach(modeManager.currentMode.features, id: \.self) { feature in
                    Text(feature).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("settings.appMode".localized(), systemImage: "switch.2")
        } footer: {
            footerText
        }
        .alert("settings.appMode.switchConfirmTitle".localized(), isPresented: $showModeChangeConfirmation) {
            Button("action.cancel".localized(), role: .cancel) {
                pendingMode = nil
            }
            Button("action.switch".localized()) {
                if let mode = pendingMode {
                    switchToMode(mode)
                }
                pendingMode = nil
            }
        } message: {
            Text("settings.appMode.switchConfirmMessage".localized())
        }
    }
    
    @ViewBuilder
    private var footerText: some View {
        switch modeManager.currentMode {
        case .monitor:
            Label("settings.appMode.quotaOnlyNote".localized(), systemImage: "info.circle")
                .font(.caption)
        case .localProxy:
            EmptyView()
        }
    }
    
    private func handleModeSelection(_ mode: OperatingMode) {
        guard mode != modeManager.currentMode else { return }
        
        // Confirm when switching FROM local proxy mode (stops the local proxy)
        if modeManager.currentMode == .localProxy && mode == .monitor {
            pendingMode = mode
            showModeChangeConfirmation = true
        } else {
            // Switch immediately for other transitions
            switchToMode(mode)
        }
    }
    
    private func switchToMode(_ mode: OperatingMode) {
        modeManager.switchMode(to: mode) {
            viewModel.stopProxy()
        }
        
        // Re-initialize based on new mode
        Task {
            await viewModel.initialize()
        }
    }
}

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
    @State private var routingStrategy = "round-robin"
    @State private var switchProject = true
    @State private var switchPreviewModel = true
    @State private var requestRetry = 3
    @State private var maxRetryInterval = 30
    @State private var loggingToFile = true
    @State private var requestLog = false
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
                if scope == .all || scope == .network { upstreamProxySection }
                if scope == .all || scope == .requests {
                    routingStrategySection
                    quotaExceededSection
                    retryConfigurationSection
                }
                if scope == .all || scope == .logging { loggingSection }
            }
        }
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

    private var upstreamProxySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("settings.upstreamProxy".localized()) {
                    TextField("", text: $proxyURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 160, idealWidth: 260, maxWidth: 360)
                        .onChange(of: proxyURL) { _, newValue in
                            proxyURLValidation = ProxyURLValidator.validate(newValue)
                        }
                        .onSubmit {
                            Task { await saveProxyURL() }
                        }
                }
                
                // 保留回车提交，同时提供可发现的应用按钮；空值仍按原逻辑清除上游代理。
                Button("settings.navigation.apply".localized()) { Task { await saveProxyURL() } }
                    .disabled(proxyURLValidation != .valid && proxyURLValidation != .empty)

                if proxyURLValidation != .valid && proxyURLValidation != .empty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text((proxyURLValidation.localizationKey ?? "").localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("settings.upstreamProxy.placeholder".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("settings.upstreamProxy.title".localized(), systemImage: "network")
        }
    }
    
    private var routingStrategySection: some View {
        Section {
            SettingsChoiceControl("settings.routingStrategy", options: ["round-robin", "fill-first"], selection: $routingStrategy) {
                ($0 == "round-robin" ? "settings.roundRobin" : "settings.fillFirst").localized()
            }
            .onChange(of: routingStrategy) { _, newValue in
                guard !isLoadingConfig else { return }
                Task { await saveRoutingStrategy(newValue) }
            }
        } header: {
            Label("settings.routingStrategy".localized(), systemImage: "arrow.triangle.branch")
        } footer: {
            Text(routingStrategy == "round-robin"
                 ? "settings.roundRobinDesc".localized()
                 : "settings.fillFirstDesc".localized())
            .font(.caption)
        }
    }
    
    private var quotaExceededSection: some View {
        Section {
            Toggle("settings.autoSwitchAccount".localized(), isOn: $switchProject)
                .onChange(of: switchProject) { _, newValue in
                    guard !isLoadingConfig else { return }
                    Task { await saveSwitchProject(newValue) }
                }
            Toggle("settings.autoSwitchPreview".localized(), isOn: $switchPreviewModel)
                .onChange(of: switchPreviewModel) { _, newValue in
                    guard !isLoadingConfig else { return }
                    Task { await saveSwitchPreviewModel(newValue) }
                }
        } header: {
            Label("settings.quotaExceededBehavior".localized(), systemImage: "exclamationmark.triangle")
        } footer: {
            Text("settings.quotaExceededHelp".localized())
                .font(.caption)
        }
    }
    
    private var retryConfigurationSection: some View {
        Section {
            Stepper("settings.maxRetries".localized() + ": \(requestRetry)", value: $requestRetry, in: 0...10)
                .onChange(of: requestRetry) { _, newValue in
                    guard !isLoadingConfig else { return }
                    Task { await saveRequestRetry(newValue) }
                }
            
            Stepper("settings.maxRetryInterval".localized() + ": \(maxRetryInterval)s", value: $maxRetryInterval, in: 5...300, step: 5)
                .onChange(of: maxRetryInterval) { _, newValue in
                    guard !isLoadingConfig else { return }
                    Task { await saveMaxRetryInterval(newValue) }
                }
        } header: {
            Label("settings.retryConfiguration".localized(), systemImage: "arrow.clockwise")
        } footer: {
            Text("settings.retryHelp".localized())
                .font(.caption)
        }
    }
    
    private var loggingSection: some View {
        Section {
            Toggle("settings.loggingToFile".localized(), isOn: $loggingToFile)
                .onChange(of: loggingToFile) { _, newValue in
                    guard !isLoadingConfig else { return }
                    Task { await saveLoggingToFile(newValue) }
                }
            
            Toggle("settings.requestLog".localized(), isOn: $requestLog)
                .onChange(of: requestLog) { _, newValue in
                    guard !isLoadingConfig else { return }
                    Task { await saveRequestLog(newValue) }
                }
            
            Toggle("settings.debugMode".localized(), isOn: $debugMode)
                .onChange(of: debugMode) { _, newValue in
                    guard !isLoadingConfig else { return }
                    Task { await saveDebugMode(newValue) }
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
            
            proxyURL = config.proxyURL ?? ""
            routingStrategy = fetchedStrategy
            requestRetry = config.requestRetry ?? 3
            maxRetryInterval = config.maxRetryInterval ?? 30
            loggingToFile = config.loggingToFile ?? true
            requestLog = config.requestLog ?? false
            debugMode = config.debug ?? false
            switchProject = config.quotaExceeded?.switchProject ?? true
            switchPreviewModel = config.quotaExceeded?.switchPreviewModel ?? true
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
        if proxyURL.isEmpty {
            UserDefaults.standard.set("", forKey: "proxyURL")
        } else if proxyURLValidation == .valid {
            UserDefaults.standard.set(ProxyURLValidator.sanitize(proxyURL), forKey: "proxyURL")
        }

        guard let apiClient = viewModel.apiClient else { return }
        do {
            if proxyURL.isEmpty {
                try await apiClient.deleteProxyURL()
            } else if proxyURLValidation == .valid {
                try await apiClient.setProxyURL(ProxyURLValidator.sanitize(proxyURL))
            }
        } catch {
            NSLog("[ProxySettings] Failed to save proxy URL: \(error)")
            saveError = error.localizedDescription
        }
    }
    
    private func saveRoutingStrategy(_ strategy: String) async {
        guard let apiClient = viewModel.apiClient else { return }
        do {
            try await apiClient.setRoutingStrategy(strategy)
        } catch {
            NSLog("[ProxySettings] Failed to save routing strategy: \(error)")
            saveError = error.localizedDescription
        }
    }
    
    private func saveSwitchProject(_ enabled: Bool) async {
        guard let apiClient = viewModel.apiClient else { return }
        do {
            try await apiClient.setQuotaExceededSwitchProject(enabled)
        } catch {
            NSLog("[ProxySettings] Failed to save switch project: \(error)")
            saveError = error.localizedDescription
        }
    }
    
    private func saveSwitchPreviewModel(_ enabled: Bool) async {
        guard let apiClient = viewModel.apiClient else { return }
        do {
            try await apiClient.setQuotaExceededSwitchPreviewModel(enabled)
        } catch {
            NSLog("[ProxySettings] Failed to save switch preview model: \(error)")
            saveError = error.localizedDescription
        }
    }
    
    private func saveRequestRetry(_ count: Int) async {
        guard let apiClient = viewModel.apiClient else { return }
        do {
            try await apiClient.setRequestRetry(count)
        } catch {
            NSLog("[ProxySettings] Failed to save request retry: \(error)")
            saveError = error.localizedDescription
        }
    }
    
    private func saveMaxRetryInterval(_ seconds: Int) async {
        guard let apiClient = viewModel.apiClient else { return }
        do {
            try await apiClient.setMaxRetryInterval(seconds)
        } catch {
            NSLog("[ProxySettings] Failed to save max retry interval: \(error)")
            saveError = error.localizedDescription
        }
    }
    
    private func saveLoggingToFile(_ enabled: Bool) async {
        guard let apiClient = viewModel.apiClient else { return }
        do {
            try await apiClient.setLoggingToFile(enabled)
        } catch {
            NSLog("[ProxySettings] Failed to save logging to file: \(error)")
            saveError = error.localizedDescription
        }
    }
    
    private func saveRequestLog(_ enabled: Bool) async {
        guard let apiClient = viewModel.apiClient else { return }
        do {
            try await apiClient.setRequestLog(enabled)
        } catch {
            NSLog("[ProxySettings] Failed to save request log: \(error)")
            saveError = error.localizedDescription
        }
    }
    
    private func saveDebugMode(_ enabled: Bool) async {
        guard let apiClient = viewModel.apiClient else { return }
        do {
            try await apiClient.setDebug(enabled)
        } catch {
            NSLog("[ProxySettings] Failed to save debug mode: \(error)")
            saveError = error.localizedDescription
        }
    }
}

// MARK: - Local Proxy Server Section

struct LocalProxyServerSection: View {
    /// 新设置页将管理密钥移到隐私与安全；默认值保留旧调用点的完整展示行为。
    var showsManagementKey = true
    @Environment(QuotaViewModel.self) private var viewModel
    @AppStorage("autoStartProxy") private var autoStartProxy = false
    @AppStorage("autoStartTunnel") private var autoStartTunnel = false
    @AppStorage("autoRestartTunnel") private var autoRestartTunnel = false
    @AppStorage("allowNetworkAccess") private var allowNetworkAccess = false
    @State private var portText: String = ""
    @State private var isLoadingConfig = false  // Prevents onChange from firing during initial load
    
    var body: some View {
        Group {
        Section {
            HStack {
                Text("settings.port".localized())
                Spacer()
                TextField("settings.port".localized(), text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onChange(of: portText) { _, newValue in
                        guard !isLoadingConfig else { return }
                        if let port = UInt16(newValue), port > 0 {
                            viewModel.proxyManager.port = port
                        }
                    }
            }
            
            LabeledContent("settings.status".localized()) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.proxyManager.proxyStatus.running ? .green : .gray)
                        .frame(width: 8, height: 8)
                    Text(viewModel.proxyManager.proxyStatus.running ? "status.running".localized() : "status.stopped".localized())
                }
            }
            
            LabeledContent("settings.endpoint".localized()) {
                Text(viewModel.proxyManager.proxyStatus.endpoint)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            
            if showsManagementKey { ManagementKeyRow() }
            
            Toggle("settings.autoStartProxy".localized(), isOn: $autoStartProxy)
            
            Toggle("settings.autoStartTunnel".localized(), isOn: $autoStartTunnel)
                .disabled(!viewModel.tunnelManager.installation.isInstalled)
            
            Toggle("settings.autoRestartTunnel".localized(), isOn: $autoRestartTunnel)
                .disabled(!viewModel.tunnelManager.installation.isInstalled)
                

                

        } header: {
            Label("settings.proxyServer".localized(), systemImage: "server.rack")
        } footer: {
            Text("settings.restartProxy".localized())
                .font(.caption)
        }
            NetworkAccessSection(allowNetworkAccess: $allowNetworkAccess)
                .onChange(of: allowNetworkAccess) { _, newValue in
                    guard !isLoadingConfig else { return }
                    viewModel.proxyManager.allowNetworkAccess = newValue
                }
        }
        .onAppear {
            isLoadingConfig = true
            portText = String(viewModel.proxyManager.port)
            // Delay clearing the flag to allow onChange to be suppressed
            DispatchQueue.main.async {
                isLoadingConfig = false
            }
        }
    }
}

struct NetworkAccessSection: View {
    @Binding var allowNetworkAccess: Bool
    
    var body: some View {
        Section {
            Toggle("settings.allowNetworkAccess".localized(), isOn: $allowNetworkAccess)
            
            LabeledContent("settings.bindAddress".localized()) {
                Text(allowNetworkAccess ? "0.0.0.0 (All Interfaces)" : "127.0.0.1 (Localhost)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(allowNetworkAccess ? .orange : .secondary)
            }
            
            if allowNetworkAccess {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("settings.networkAccessWarning".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Label("settings.networkAccess".localized(), systemImage: "network")
        } footer: {
            Text("settings.networkAccessFooter".localized())
                .font(.caption)
        }
    }
}

// MARK: - Local Paths Section

struct LocalPathsSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    
    var body: some View {
        Section {
            LabeledContent("settings.binary".localized()) {
                PathLabel(path: viewModel.proxyManager.effectiveBinaryPath)
            }
            
            LabeledContent("settings.config".localized()) {
                PathLabel(path: viewModel.proxyManager.configPath)
            }
            
            LabeledContent("settings.authDir".localized()) {
                PathLabel(path: viewModel.proxyManager.authDir)
            }
        } header: {
            Label("settings.paths".localized(), systemImage: "folder")
        }
    }
}

// MARK: - Path Label

struct PathLabel: View {
    let path: String
    
    var body: some View {
        HStack {
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }
}

struct NotificationSettingsSection: View {
    private let notificationManager = NotificationManager.shared
    
    var body: some View {
        @Bindable var manager = notificationManager
        
        Section {
            Toggle("settings.notifications.enabled".localized(), isOn: Binding(
                get: { manager.notificationsEnabled },
                set: { manager.notificationsEnabled = $0 }
            ))
            
            if manager.notificationsEnabled {
                Toggle("settings.notifications.quotaLow".localized(), isOn: Binding(
                    get: { manager.notifyOnQuotaLow },
                    set: { manager.notifyOnQuotaLow = $0 }
                ))
                
                Toggle("settings.notifications.cooling".localized(), isOn: Binding(
                    get: { manager.notifyOnCooling },
                    set: { manager.notifyOnCooling = $0 }
                ))
                
                Toggle("settings.notifications.proxyCrash".localized(), isOn: Binding(
                    get: { manager.notifyOnProxyCrash },
                    set: { manager.notifyOnProxyCrash = $0 }
                ))
                
                Toggle("settings.notifications.upgradeAvailable".localized(), isOn: Binding(
                    get: { manager.notifyOnUpgradeAvailable },
                    set: { manager.notifyOnUpgradeAvailable = $0 }
                ))
                
                HStack {
                    Text("settings.notifications.threshold".localized())
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Picker("settings.notifications.threshold".localized(), selection: Binding(
                        get: { Int(manager.quotaAlertThreshold) },
                        set: { manager.quotaAlertThreshold = Double($0) }
                    )) {
                        Text("10%").tag(10)
                        Text("20%").tag(20)
                        Text("30%").tag(30)
                        Text("50%").tag(50)
                    }
                    .pickerStyle(.menu)
                    // 隐藏 Picker 自带标签，但保留无障碍名称；宽度由百分比、
                    // 系统菜单箭头和内边距共同决定，不再用 80 点硬裁切导致省略号。
                    .labelsHidden()
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 100, alignment: .trailing)
                    .layoutPriority(1)
                }
            }
            
            if !manager.isAuthorized {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("settings.notifications.notAuthorized".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("settings.notifications".localized(), systemImage: "bell")
        } footer: {
            Text("settings.notifications.help".localized())
                .font(.caption)
        }
    }
}

// MARK: - Quota Display Settings Section

struct QuotaDisplaySettingsSection: View {
    @State private var settings = MenuBarSettingsManager.shared
    
    private var displayModeBinding: Binding<QuotaDisplayMode> {
        Binding(
            get: { settings.quotaDisplayMode },
            set: { settings.quotaDisplayMode = $0 }
        )
    }
    
    private var displayStyleBinding: Binding<QuotaDisplayStyle> {
        Binding(
            get: { settings.quotaDisplayStyle },
            set: { settings.quotaDisplayStyle = $0 }
        )
    }
    
    var body: some View {
        Section {
            SettingsChoiceControl("settings.quota.displayMode", options: [QuotaDisplayMode.used, .remaining], selection: displayModeBinding) {
                ($0 == .used ? "settings.quota.displayMode.used" : "settings.quota.displayMode.remaining").localized()
            }
            
            SettingsChoiceControl("settings.quota.displayStyle", options: QuotaDisplayStyle.allCases, selection: displayStyleBinding) {
                $0.localizationKey.localized()
            }
        } header: {
            Label("settings.quota.display".localized(), systemImage: "percent")
        } footer: {
            Text("settings.quota.display.help".localized())
                .font(.caption)
        }
    }
}

// MARK: - Refresh Cadence Settings Section

struct RefreshCadenceSettingsSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var refreshSettings = RefreshSettingsManager.shared
    
    private var cadenceBinding: Binding<RefreshCadence> {
        Binding(
            get: { refreshSettings.refreshCadence },
            set: { refreshSettings.refreshCadence = $0 }
        )
    }
    
    var body: some View {
        Section {
            Picker("settings.refresh.cadence".localized(), selection: cadenceBinding) {
                ForEach(RefreshCadence.allCases) { cadence in
                    Text(cadence.localizationKey.localized()).tag(cadence)
                }
            }
            
            if refreshSettings.refreshCadence == .manual {
                Button {
                    Task {
                        await viewModel.manualRefresh()
                    }
                } label: {
                    Label("settings.refresh.now".localized(), systemImage: "arrow.clockwise")
                }
            }
        } header: {
            Label("settings.refresh".localized(), systemImage: "clock.arrow.2.circlepath")
        } footer: {
            Text("settings.refresh.help".localized())
                .font(.caption)
        }
    }
}

// MARK: - Update Settings Section

struct UpdateSettingsSection: View {
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    
    #if canImport(Sparkle)
    private let updaterService = UpdaterService.shared
    #endif
    
    var body: some View {
        Section {
            #if canImport(Sparkle)
            Toggle("settings.autoCheckUpdates".localized(), isOn: $autoCheckUpdates)
                .onChange(of: autoCheckUpdates) { _, newValue in
                    updaterService.automaticallyChecksForUpdates = newValue
                }
                .disabled(!updaterService.supportsAutomaticUpdates)

            if !updaterService.supportsAutomaticUpdates {
                Text("updates.own.manualOnly".localized()).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Text("settings.lastChecked".localized())
                Spacer()
                if let date = updaterService.lastUpdateCheckDate {
                    UpdateCheckTimestamp(date: date)
                        .foregroundStyle(.secondary)
                } else {
                    Text("settings.never".localized())
                        .foregroundStyle(.secondary)
                }
            }
            
            Button(updaterService.checkButtonTitleKey.localized()) {
                updaterService.checkForUpdates()
            }
            .disabled(!updaterService.canCheckForUpdates)
            #else
            Text("settings.version".localized() + ": " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"))
            #endif
        } header: {
            Label("settings.updates".localized(), systemImage: "arrow.down.circle")
        }
    }
}

// MARK: - Proxy Update Settings Section

struct ProxyUpdateSettingsSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var isCheckingForUpdate = false
    @State private var isUpgrading = false
    @State private var upgradeError: String?
    @State private var showAdvancedSheet = false

    private var proxyManager: CLIProxyManager {
        viewModel.proxyManager
    }

    private var atomFeedService: AtomFeedUpdateService {
        AtomFeedUpdateService.shared
    }
    
    var body: some View {
        Section {
            // Current version
            LabeledContent("settings.proxyUpdate.currentVersion".localized()) {
                if let version = proxyManager.currentVersion ?? proxyManager.installedProxyVersion {
                    Text("v\(version)")
                        .font(.system(.body, design: .monospaced))
                } else {
                    Text("settings.proxyUpdate.unknown".localized())
                        .foregroundStyle(.secondary)
                }
            }
            
            // Upgrade status
            if proxyManager.upgradeAvailable, let upgrade = proxyManager.availableUpgrade {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label {
                            Text("settings.proxyUpdate.available".localized())
                        } icon: {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(.green)
                        }
                        
                        Text("v\(upgrade.version)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Button {
                        performUpgrade(to: upgrade)
                    } label: {
                        ZStack {
                            Text("action.update".localized())
                                .opacity(isUpgrading ? 0 : 1)
                            
                            if isUpgrading {
                                SmallProgressView()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isUpgrading)
                }
            } else {
                HStack {
                    Label {
                        Text("settings.proxyUpdate.upToDate".localized())
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    
                    Spacer()

                    Button {
                        checkForUpdate()
                    } label: {
                        ZStack {
                            Text("settings.proxyUpdate.checkNow".localized())
                                .opacity(isCheckingForUpdate ? 0 : 1)

                            if isCheckingForUpdate {
                                SmallProgressView()
                            }
                        }
                    }
                    .disabled(isCheckingForUpdate)
                }

                // Last checked time
                if let lastCheck = atomFeedService.lastCLIProxyCheck {
                    HStack {
                        Text("Last checked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        UpdateCheckTimestamp(date: lastCheck)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // Last checked time
            HStack {
                Text("settings.lastChecked".localized())
                Spacer()
                if let date = proxyManager.lastProxyUpdateCheckDate {
                    UpdateCheckTimestamp(date: date)
                        .foregroundStyle(.secondary)
                } else {
                    Text("settings.never".localized())
                        .foregroundStyle(.secondary)
                }
            }
            
            // Error message
            if let error = upgradeError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Advanced button
            Button {
                showAdvancedSheet = true
            } label: {
                HStack {
                    Label("settings.proxyUpdate.advanced".localized(), systemImage: "gearshape.2")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } header: {
            Label("settings.proxyUpdate".localized(), systemImage: "shippingbox.and.arrow.backward")
        } footer: {
            Text("settings.proxyUpdate.help".localized())
                .font(.caption)
        }
        .sheet(isPresented: $showAdvancedSheet) {
            ProxyVersionManagerSheet()
                .environment(viewModel)
        }
    }
    
    private func checkForUpdate() {
        isCheckingForUpdate = true
        upgradeError = nil

        Task { @MainActor in
            defer {
                // Always reset loading state
                isCheckingForUpdate = false
            }

            await proxyManager.checkForUpgrade()
        }
    }
    
    private func performUpgrade(to version: ProxyVersionInfo) {
        isUpgrading = true
        upgradeError = nil
        
        Task { @MainActor in
            do {
                try await proxyManager.performManagedUpgrade(to: version)
                isUpgrading = false
            } catch {
                upgradeError = error.localizedDescription
                isUpgrading = false
            }
        }
    }
}

// MARK: - Proxy Version Manager Sheet

struct ProxyVersionManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(QuotaViewModel.self) private var viewModel
    
    @State private var availableVersions: [ProxyVersionInfo] = []
    @State private var installedVersions: [InstalledProxyVersion] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var installingVersion: String?
    @State private var installError: String?
    
    // State for deletion warning
    @State private var showDeleteWarning = false
    @State private var pendingInstallVersion: ProxyVersionInfo?
    @State private var versionsToDelete: [String] = []
    
    private var proxyManager: CLIProxyManager {
        viewModel.proxyManager
    }

    private var installedVersionItems: [NamespacedInstalledVersionItem] {
        installedVersions.map { version in
            NamespacedInstalledVersionItem(id: "installed-\(version.id)", version: version)
        }
    }

    private var availableVersionItems: [NamespacedAvailableVersionItem] {
        availableVersions.map { versionInfo in
            NamespacedAvailableVersionItem(id: "available-\(versionInfo.id)", versionInfo: versionInfo)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("settings.proxyUpdate.advanced.title".localized())
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("settings.proxyUpdate.advanced.description".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            // Content
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("settings.proxyUpdate.advanced.loading".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("settings.proxyUpdate.advanced.fetchError".localized())
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("action.refresh".localized()) {
                        Task { await loadReleases() }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Installed Versions Section
                if !installedVersions.isEmpty {
                            sectionHeader("settings.proxyUpdate.advanced.installedVersions".localized())
                            
                            ForEach(installedVersionItems) { item in
                                InstalledVersionRow(
                                    version: item.version,
                                    onActivate: { activateVersion(item.version.version) },
                                    onDelete: { deleteVersion(item.version.version) }
                                )
                                Divider().padding(.leading, 16)
                            }
                        }
                        
                        // Available Versions Section
                        sectionHeader("settings.proxyUpdate.advanced.availableVersions".localized())
                        
                        if availableVersions.isEmpty {
                            HStack {
                                Text("settings.proxyUpdate.advanced.noReleases".localized())
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                        } else {
                            ForEach(availableVersionItems) { item in
                                AvailableVersionRow(
                                    versionInfo: item.versionInfo,
                                    isInstalled: isVersionInstalled(item.versionInfo.version),
                                    isInstalling: installingVersion == item.versionInfo.version,
                                    onInstall: { installVersion(item.versionInfo) }
                                )
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .padding(.bottom)
                }
            }
            
            // Error footer
            if let error = installError {
                Divider()
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        installError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
            }
        }
        .frame(width: 500, height: 500)
        .task {
            await loadReleases()
        }
        .alert("settings.proxyUpdate.deleteWarning.title".localized(), isPresented: $showDeleteWarning) {
            Button("action.cancel".localized(), role: .cancel) {
                pendingInstallVersion = nil
                versionsToDelete = []
            }
            Button("settings.proxyUpdate.deleteWarning.confirm".localized(), role: .destructive) {
                if let versionInfo = pendingInstallVersion {
                    performInstall(versionInfo)
                }
                pendingInstallVersion = nil
                versionsToDelete = []
            }
        } message: {
            Text(String(format: "settings.proxyUpdate.deleteWarning.message".localized(), AppConstants.maxInstalledVersions, versionsToDelete.joined(separator: ", ")))
        }
    }
    
    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(QuotioTheme.Colors.cardInset(for: colorScheme))
    }
    
    private func isVersionInstalled(_ version: String) -> Bool {
        installedVersions.contains { $0.version == version }
    }
    
    private func refreshInstalledVersions() {
        installedVersions = proxyManager.installedVersions
    }
    
    private func loadReleases() async {
        isLoading = true
        loadError = nil
        
        do {
            availableVersions = try await proxyManager.fetchAvailableVersions(limit: 15)
            refreshInstalledVersions()
            isLoading = false
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }
    
    private func installVersion(_ versionInfo: ProxyVersionInfo) {
        // Check if installing will delete old versions
        let toDelete = proxyManager.storageManager.versionsToBeDeleted(keepLast: AppConstants.maxInstalledVersions)
        if !toDelete.isEmpty {
            versionsToDelete = toDelete
            pendingInstallVersion = versionInfo
            showDeleteWarning = true
            return
        }
        
        performInstall(versionInfo)
    }
    
    private func performInstall(_ versionInfo: ProxyVersionInfo) {
        installingVersion = versionInfo.version
        installError = nil
        
        Task { @MainActor in
            do {
                try await proxyManager.performManagedUpgrade(to: versionInfo)
                installingVersion = nil
                refreshInstalledVersions()
            } catch {
                installError = error.localizedDescription
                installingVersion = nil
            }
        }
    }
    
    private func activateVersion(_ version: String) {
        Task { @MainActor in
            do {
                let wasRunning = proxyManager.proxyStatus.running
                if wasRunning {
                    proxyManager.stop()
                }
                try proxyManager.storageManager.setCurrentVersion(version)
                if wasRunning {
                    try await proxyManager.start()
                }
                refreshInstalledVersions()
            } catch {
                installError = error.localizedDescription
            }
        }
    }
    
    private func deleteVersion(_ version: String) {
        do {
            try proxyManager.storageManager.deleteVersion(version)
            refreshInstalledVersions()
        } catch {
            installError = error.localizedDescription
        }
    }
}

private struct NamespacedInstalledVersionItem: Identifiable {
    let id: String
    let version: InstalledProxyVersion
}

private struct NamespacedAvailableVersionItem: Identifiable {
    let id: String
    let versionInfo: ProxyVersionInfo
}

// MARK: - Installed Version Row

private struct InstalledVersionRow: View {
    let version: InstalledProxyVersion
    let onActivate: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Version info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("v\(version.version)")
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                    
                    if version.isCurrent {
                        Text("settings.proxyUpdate.advanced.current".localized())
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green)
                            .clipShape(Capsule())
                    }
                }
                
                Text(version.installedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Actions
            if !version.isCurrent {
                Button("settings.proxyUpdate.advanced.activate".localized()) {
                    onActivate()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Available Version Row

private struct AvailableVersionRow: View {
    let versionInfo: ProxyVersionInfo
    let isInstalled: Bool
    let isInstalling: Bool
    let onInstall: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Version info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("v\(versionInfo.version)")
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                    
                    if versionInfo.version.contains("-rc") {
                        Text("settings.proxyUpdate.advanced.prerelease".localized())
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    
                    if isInstalled {
                        Text("settings.proxyUpdate.advanced.installed".localized())
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                
            }
            
            Spacer()
            
            // Install button
            if !isInstalled {
                Button {
                    onInstall()
                } label: {
                    if isInstalling {
                        SmallProgressView()
                    } else {
                        Text("settings.proxyUpdate.advanced.install".localized())
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isInstalling)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Menu Bar Settings Section

struct MenuBarSettingsSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    private let settings = MenuBarSettingsManager.shared
    @AppStorage("showInDock") private var showInDock = true
    @State private var showTruncationAlert = false
    @State private var pendingMaxItems: Int?
    
    private var showMenuBarIconBinding: Binding<Bool> {
        Binding(
            get: { settings.showMenuBarIcon },
            set: { newValue in
                // Prevent disabling both dock and menu bar icon (user would have no way to access app)
                if !newValue && !showInDock {
                    // Re-enable dock if user tries to disable menu bar icon while dock is already disabled
                    showInDock = true
                    // activation policy will be set by showInDockBinding automatically
                }
                settings.showMenuBarIcon = newValue
            }
        )
    }

    private var showInDockBinding: Binding<Bool> {
        Binding(
            get: { showInDock },
            set: { newValue in
                // Prevent disabling both dock and menu bar icon (user would have no way to access app)
                if !newValue && !settings.showMenuBarIcon {
                    // Re-enable menu bar icon if user tries to disable dock while menu bar is already disabled
                    settings.showMenuBarIcon = true
                }

                // Update the value
                showInDock = newValue

                // This is the ONLY place where activation policy is changed based on user settings
                // - true: dock icon always visible, even when window is closed
                // - false: dock icon never visible
                NSApp.setActivationPolicy(newValue ? .regular : .accessory)
            }
        )
    }
    
    private var showQuotaBinding: Binding<Bool> {
        Binding(
            get: { settings.showQuotaInMenuBar },
            set: { settings.showQuotaInMenuBar = $0 }
        )
    }
    
    private var colorModeBinding: Binding<MenuBarColorMode> {
        Binding(
            get: { settings.colorMode },
            set: { settings.colorMode = $0 }
        )
    }

    private var stackPairedQuotaMetricsBinding: Binding<Bool> {
        Binding(
            get: { settings.stackPairedQuotaMetrics },
            set: { settings.stackPairedQuotaMetrics = $0 }
        )
    }
    
    private var maxItemsBinding: Binding<Int> {
        Binding(
            get: { settings.menuBarMaxItems },
            set: { newValue in
                let clamped = min(max(newValue, MenuBarSettingsManager.minMenuBarItems), MenuBarSettingsManager.maxMenuBarItems)

                // Check if reducing max items would truncate current selection
                if clamped < settings.menuBarMaxItems && settings.selectedItems.count > clamped {
                    pendingMaxItems = clamped
                    showTruncationAlert = true
                } else {
                    settings.menuBarMaxItems = clamped
                    viewModel.syncMenuBarSelection()
                }
            }
        )
    }
    
    var body: some View {
        Section {
            Toggle("settings.showInDock".localized(), isOn: showInDockBinding)
            
            Toggle("settings.menubar.showIcon".localized(), isOn: showMenuBarIconBinding)
            
            if settings.showMenuBarIcon {
                Toggle("settings.menubar.showQuota".localized(), isOn: showQuotaBinding)
                
                if settings.showQuotaInMenuBar {
                    Toggle(
                        "settings.menubar.stackPairedQuotaMetrics".localized(),
                        isOn: stackPairedQuotaMetricsBinding
                    )

                    HStack {
                        Text("settings.menubar.maxItems".localized())
                        Spacer()
                        Text("\(settings.menuBarMaxItems)")
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Stepper(
                            "",
                            value: maxItemsBinding,
                            in: MenuBarSettingsManager.minMenuBarItems...MenuBarSettingsManager.maxMenuBarItems,
                            step: 1
                        )
                        .labelsHidden()
                    }
                    
                    Picker("settings.menubar.colorMode".localized(), selection: colorModeBinding) {
                        Text("settings.menubar.colored".localized()).tag(MenuBarColorMode.colored)
                        Text("settings.menubar.monochrome".localized()).tag(MenuBarColorMode.monochrome)
                    }
                    .pickerStyle(.segmented)
                }
            }
        } header: {
            Label("settings.menubar".localized(), systemImage: "menubar.rectangle")
        } footer: {
            Text(String(
                format: "settings.menubar.help".localized(),
                settings.menuBarMaxItems
            ))
            .font(.caption)
        }
        .alert("menubar.truncation.title".localized(), isPresented: $showTruncationAlert) {
            Button("action.cancel".localized(), role: .cancel) {
                pendingMaxItems = nil
            }
            Button("action.ok".localized(), role: .destructive) {
                if let newMax = pendingMaxItems {
                    settings.menuBarMaxItems = newMax
                    viewModel.syncMenuBarSelection()
                    pendingMaxItems = nil
                }
            }
        } message: {
            if let newMax = pendingMaxItems {
                Text(String(
                    format: "menubar.truncation.message".localized(),
                    settings.selectedItems.count,
                    newMax
                ))
            }
        }
    }
}

// MARK: - Appearance Settings Section

struct AppearanceSettingsSection: View {
    @State private var appearanceManager = AppearanceManager.shared
    
    private var appearanceModeBinding: Binding<AppearanceMode> {
        Binding(
            get: { appearanceManager.appearanceMode },
            set: { appearanceManager.appearanceMode = $0 }
        )
    }
    
    var body: some View {
        Section {
            SettingsChoiceControl("settings.appearance.mode", options: AppearanceMode.allCases, selection: appearanceModeBinding) {
                $0.localizationKey.localized()
            }
        } header: {
            Label("settings.appearance.title".localized(), systemImage: "paintbrush")
        } footer: {
            Text("settings.appearance.help".localized())
                .font(.caption)
        }
    }
}

// MARK: - Privacy Settings Section

struct PrivacySettingsSection: View {
    @State private var settings = MenuBarSettingsManager.shared
    @State private var telemetrySettings = TelemetrySettings.shared
    
    private var hideSensitiveBinding: Binding<Bool> {
        Binding(
            get: { settings.hideSensitiveInfo },
            set: { settings.hideSensitiveInfo = $0 }
        )
    }

    private var shareAnonymousUsageBinding: Binding<Bool> {
        Binding(
            get: { telemetrySettings.shareAnonymousUsage },
            set: { telemetrySettings.shareAnonymousUsage = $0 }
        )
    }
    
    var body: some View {
        Section {
            Toggle("settings.privacy.hideSensitive".localized(), isOn: hideSensitiveBinding)
            Toggle("settings.privacy.shareAnonymousUsage".localized(), isOn: shareAnonymousUsageBinding)
        } header: {
            Label("settings.privacy".localized(), systemImage: "eye.slash")
        } footer: {
            Text("settings.privacy.help".localized())
                .font(.caption)
        }
    }
}

// MARK: - YubiKey Settings Section

struct YubiKeySettingsSection: View {
    /// What Quotio is configured to do right now, which is the first thing this
    /// section has to answer.
    private enum VaultStatus: Equatable {
        case notConfigured
        case active(name: String, fingerprint: String, secrets: Int)
        case keyMissing(fingerprint: String, secrets: Int)
    }

    @State private var identities: [YubiKeyPIVIdentity] = []
    @State private var devices: [YubiKeyPIVDevice] = []
    @State private var status: VaultStatus = .notConfigured
    @State private var yubiKeyConnected = false
    @State private var selectedID = ""
    @State private var selectedDeviceID = ""
    @State private var statusMessage: String?

    private var isConfigured: Bool {
        status != .notConfigured
    }

    var body: some View {
        Section {
            statusView
            actionsView

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("settings.yubikey.refresh".localized()) {
                // A stale message outlives the state it described, so drop it
                // rather than let it contradict the status row.
                statusMessage = nil
                Task { await refresh() }
            }
        } header: {
            Label("settings.yubikey.title".localized(), systemImage: "key.viewfinder")
        } footer: {
            Text("settings.yubikey.help".localized())
        }
        .task { await refresh() }

    }

    /// Exactly one story per state: adopt a key that already exists, or create
    /// one. Anything the status row already says is not repeated here.
    @ViewBuilder
    private var actionsView: some View {
        switch status {
        case .active:
            // Only worth offering when there is something else to switch to.
            if identities.count > 1 {
                identityPicker
                Button("settings.yubikey.change".localized()) { select() }
                    .disabled(selectedID.isEmpty)
            }

        case .keyMissing:
            // The status row already says which key to insert; nothing to do here.
            EmptyView()

        case .notConfigured:
            if !identities.isEmpty {
                identityPicker
                Button("settings.yubikey.use".localized()) { select() }
                    .disabled(selectedID.isEmpty)
            }

            // Still offered alongside an existing identity: that identity may
            // belong to another application, and provisioning would otherwise
            // be unreachable.
            if !devices.isEmpty {
                Picker("settings.yubikey.setupPicker".localized(), selection: $selectedDeviceID) {
                    ForEach(devices) { device in
                        Text(device.name + " (" + device.serial + ")").tag(device.id)
                    }
                }
                // 硬件配置页面使用系统 Push，成功后仍执行原有身份刷新和选用流程。
                if let device = devices.first(where: { $0.id == selectedDeviceID }) {
                    NavigationLink {
                        YubiKeyProvisioningSheet(device: device, usesNavigation: true) {
                            await completeProvisioning()
                        }
                    } label: {
                        Text("settings.yubikey.setup".localized())
                    }
                } else {
                    Button("settings.yubikey.setup".localized()) {}.disabled(true)
                }
            }

            if identities.isEmpty, devices.isEmpty {
                Label(
                    yubiKeyConnected
                        ? "settings.yubikey.detected".localized()
                        : "settings.yubikey.insert".localized(),
                    systemImage: yubiKeyConnected ? "key.badge.exclamationmark" : "key.slash"
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    private var identityPicker: some View {
        Picker("settings.yubikey.identityPicker".localized(), selection: $selectedID) {
            ForEach(identities) { identity in
                Text(identity.name + " (" + String(identity.fingerprint.prefix(12)) + ")")
                    .tag(identity.id)
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .notConfigured:
            Label("settings.yubikey.status.inactive".localized(), systemImage: "lock.open")
                .foregroundStyle(.secondary)

        case let .active(name, fingerprint, secrets):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    String(format: "settings.yubikey.status.active".localized(), name),
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(.green)
                Text(String(format: "settings.yubikey.status.activeDetail".localized(),
                            String(fingerprint.prefix(12)), secrets))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case let .keyMissing(fingerprint, secrets):
            VStack(alignment: .leading, spacing: 4) {
                Label("settings.yubikey.status.missing".localized(), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(String(format: "settings.yubikey.status.missingDetail".localized(),
                            String(fingerprint.prefix(12)), secrets))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func select() {
        guard let identity = identities.first(where: { $0.id == selectedID }) else { return }
        if YubiKeySecretVault.select(identity) {
            statusMessage = "settings.yubikey.selected".localized()
        } else {
            statusMessage = "settings.yubikey.changeBlocked".localized()
        }
        Task { await refresh() }
    }

    private func completeProvisioning() async {
        // macOS republishes the token's identities asynchronously, so the new key
        // is not always visible the instant ykman exits.
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            await refresh()
            if !identities.isEmpty { break }
        }

        // ykman succeeded, so the key holds a Quotio identity — but macOS has
        // not surfaced it. Say so, rather than point at a picker that is empty
        // precisely because there is nothing to put in it.
        guard !identities.isEmpty else {
            statusMessage = "settings.yubikey.setupUnpublished".localized()
            return
        }

        // Another key is already protecting secrets; this one stays unused
        // until an explicit migration exists.
        guard !isConfigured else {
            statusMessage = "settings.yubikey.setupUnusedKeyConfigured".localized()
            return
        }

        // The new identity protects nothing yet. Adopt it so setup ends in a
        // state the status row reports as active instead of silently leaving it
        // idle. With several candidates, the choice stays with the user — and
        // only then does "choose the key below" describe a picker that exists.
        let provisioned = identities.first { $0.name == YubiKeySecretVault.identityName }
            ?? (identities.count == 1 ? identities.first : nil)
        if let provisioned, YubiKeySecretVault.select(provisioned) {
            statusMessage = "settings.yubikey.setupSucceeded".localized()
            await refresh()
        } else {
            statusMessage = "settings.yubikey.setupSucceededSelect".localized()
        }
    }

    private func refresh() async {
        let result = await Task.detached(priority: .userInitiated) {
            let identities = YubiKeySecretVault.availableIdentities()
            return (
                connected: YubiKeySecretVault.isYubiKeyConnected(),
                devices: YubiKeySecretVault.provisionableDevices(),
                identities: identities,
                selected: YubiKeySecretVault.identity(matching: identities),
                fingerprint: YubiKeySecretVault.selectedFingerprint,
                secrets: YubiKeySecretVault.protectedSecretCount
            )
        }.value

        yubiKeyConnected = result.connected
        devices = result.devices
        identities = result.identities
        if selectedDeviceID.isEmpty { selectedDeviceID = devices.first?.id ?? "" }

        switch (result.fingerprint, result.selected) {
        case let (_, .some(identity)):
            status = .active(name: identity.name, fingerprint: identity.fingerprint, secrets: result.secrets)
            selectedID = identity.id
        case let (.some(fingerprint), nil):
            status = .keyMissing(fingerprint: fingerprint, secrets: result.secrets)
            if selectedID.isEmpty { selectedID = identities.first?.id ?? "" }
        case (nil, nil):
            status = .notConfigured
            if selectedID.isEmpty { selectedID = identities.first?.id ?? "" }
        }
    }
}

struct GeneralSettingsTab: View {
    @AppStorage("autoStartProxy") private var autoStartProxy = false
    
    var body: some View {
        @Bindable var lang = LanguageManager.shared
        
        Form {
            Section {
                LaunchAtLoginToggle()
                
                Toggle("settings.autoStartProxy".localized(), isOn: $autoStartProxy)
            } header: {
                Label("settings.startup".localized(), systemImage: "power")
            }
            
            Section {
                Picker(selection: Binding(
                    get: { lang.currentLanguage },
                    set: { lang.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases) { language in
                        HStack {
                            Text(language.flag)
                            Text(language.displayName)
                        }
                        .tag(language)
                    }
                } label: {
                    Label("settings.language".localized(), systemImage: "globe")
                }
            } header: {
                Label("settings.language".localized(), systemImage: "globe")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Management Key Row

struct ManagementKeyRow: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var settings = MenuBarSettingsManager.shared
    @State private var regenerateError: String?
    @State private var showRegenerateConfirmation = false
    @State private var showCopyConfirmation = false
    
    private var displayKey: String {
        if settings.hideSensitiveInfo {
            let key = viewModel.proxyManager.managementKey
            return String(repeating: "•", count: 8) + "..." + key.suffix(4)
        }
        return viewModel.proxyManager.managementKey
    }
    
    var body: some View {
        LabeledContent("settings.managementKey".localized()) {
            HStack(spacing: 8) {
                Text(displayKey)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(viewModel.proxyManager.managementKey, forType: .string)
                    showCopyConfirmation = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        showCopyConfirmation = false
                    }
                } label: {
                    Image(systemName: showCopyConfirmation ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .frame(width: 14, height: 14)
                        .foregroundStyle(showCopyConfirmation ? .green : .primary)
                        .modifier(SymbolEffectTransitionModifier())
                }
                .buttonStyle(.borderless)
                .help("action.copy".localized())
                
                Button {
                    showRegenerateConfirmation = true
                } label: {
                    if viewModel.proxyManager.isRegeneratingKey {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.proxyManager.isRegeneratingKey)
                .help("settings.managementKey.regenerate".localized())
            }
        }
        .confirmationDialog(
            "settings.managementKey.regenerate.title".localized(),
            isPresented: $showRegenerateConfirmation,
            titleVisibility: .visible
        ) {
            Button("settings.managementKey.regenerate.confirm".localized(), role: .destructive) {
                Task {
                    regenerateError = nil
                    do {
                        try await viewModel.proxyManager.regenerateManagementKey()
                    } catch {
                        regenerateError = error.localizedDescription
                    }
                }
            }
            Button("action.cancel".localized(), role: .cancel) {}
        } message: {
            Text("settings.managementKey.regenerate.warning".localized())
        }
        .alert("Error".localized(), isPresented: .init(
            get: { regenerateError != nil },
            set: { if !$0 { regenerateError = nil } }
        )) {
            Button("OK".localized()) { regenerateError = nil }
        } message: {
            Text(regenerateError ?? "")
        }
    }
}

// MARK: - Launch at Login Toggle

/// Reusable toggle component for Launch at Login functionality
/// Uses LaunchAtLoginManager for proper SMAppService handling
struct LaunchAtLoginToggle: View {
    private let launchManager = LaunchAtLoginManager.shared
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showLocationWarning = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("settings.launchAtLogin".localized(), isOn: Binding(
                get: { launchManager.isEnabled },
                set: { newValue in
                    do {
                        try launchManager.setEnabled(newValue)
                        
                        // Show warning if app is not in /Applications when enabling
                        if newValue && !launchManager.isInValidLocation {
                            showLocationWarning = true
                        } else {
                            showLocationWarning = false
                        }
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            ))
            
            // Show location warning inline
            if showLocationWarning {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text("launchAtLogin.warning.notInApplications".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 2)
            }
        }
        .onAppear {
            // Refresh status when view appears to sync with System Settings
            launchManager.refreshStatus()
        }
        .alert("launchAtLogin.error.title".localized(), isPresented: $showError) {
            Button("OK".localized()) { showError = false }
            Button("launchAtLogin.openSystemSettings".localized()) {
                launchManager.openSystemSettings()
                showError = false
            }
        } message: {
            Text(errorMessage)
        }
    }
}

// MARK: - Usage Display Settings Section

struct UsageDisplaySettingsSection: View {
    @State private var settings = MenuBarSettingsManager.shared
    
    private var totalUsageModeBinding: Binding<TotalUsageMode> {
        Binding(
            get: { settings.totalUsageMode },
            set: { settings.totalUsageMode = $0 }
        )
    }
    
    private var modelAggregationModeBinding: Binding<ModelAggregationMode> {
        Binding(
            get: { settings.modelAggregationMode },
            set: { settings.modelAggregationMode = $0 }
        )
    }
    
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.usageDisplay.totalMode.title".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                SettingsChoiceControl("", options: TotalUsageMode.allCases, selection: totalUsageModeBinding) {
                    $0.localizationKey.localized()
                }
                
                Text("settings.usageDisplay.totalMode.description".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.usageDisplay.modelAggregation.title".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                SettingsChoiceControl("", options: ModelAggregationMode.allCases, selection: modelAggregationModeBinding) {
                    $0.localizationKey.localized()
                }
                
                Text("settings.usageDisplay.modelAggregation.description".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Label("settings.usageDisplay.title".localized(), systemImage: "chart.bar.doc.horizontal")
        } footer: {
            Text("settings.usageDisplay.description".localized())
                .font(.caption)
        }
    }
}
