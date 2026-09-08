import SwiftUI

/// 分类页只组合原有业务组件，系统 Form 负责表单的层次、间距与分隔。
/// 页面标题和返回按钮由外层 NavigationStack 提供，不再手工绘制第二套导航栏。
struct SettingsCategoryScreen: View {
    @State private var modeManager = OperatingModeManager.shared
    let destination: SettingsDestination
    let onShowMode: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if destination.category.isCPAOnly && !modeManager.isLocalProxyMode {
                    localModeNotice
                } else {
                    ForEach(destination.category.topics) { topic in
                        topicContent(topic).id(topic)
                    }
                }
            }
            .formStyle(.grouped)
            .modifier(SettingsPageBackground())
            .task(id: destination) {
                guard let topic = destination.topic else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo(topic, anchor: .top)
            }
        }
        .navigationTitle(destination.category.title)
        .monospacedDigit()
    }

    private var localModeNotice: some View {
        Section {
            Label("settings.navigation.localModeHelp".localized(), systemImage: "network.slash")
                .foregroundStyle(.secondary)
            Button("settings.navigation.openMode".localized(), action: onShowMode)
        } header: { Text("settings.navigation.requiresLocal".localized()) }
    }

    @ViewBuilder private func topicContent(_ topic: SettingsTopic) -> some View {
        switch topic {
        case .mode:
            // 模式只在首页编辑；兼容旧搜索目标时也引导回同一个控件。
            Section { Button("settings.navigation.openMode".localized(), action: onShowMode) }
        case .startup:
            Section { LaunchAtLoginToggle() } header: {
                Text("settings.startup".localized())
            }
        case .language:
            languageSection
        case .appearance:
            AppearanceSettingsSection()
        case .menuBar:
            MenuBarSettingsSection()
        case .quota:
            QuotaDisplaySettingsSection()
        case .usage:
            UsageDisplaySettingsSection()
        case .refresh:
            RefreshCadenceSettingsSection()
        case .notifications:
            NotificationSettingsSection()
        case .server:
            if modeManager.isLocalProxyMode { LocalProxyServerSection(showsManagementKey: false) }
        case .upstream:
            if modeManager.isLocalProxyMode { ProxySettingsSection(scope: .network) }
        case .aliases:
            if modeManager.isLocalProxyMode { SettingsModelAliasesSection() }
        case .requestPolicy:
            if modeManager.isLocalProxyMode { ProxySettingsSection(scope: .requests) }
        case .privacy:
            PrivacySettingsSection()
        case .yubiKey:
            YubiKeySettingsSection()
        case .managementKey:
            if modeManager.isLocalProxyMode {
                Section { ManagementKeyRow() } header: {
                    Text("settings.managementKey".localized())
                } footer: {
                    Text("settings.navigation.managementKeyHelp".localized())
                }
            } else { localModeNotice }
        case .logging:
            if modeManager.isLocalProxyMode { ProxySettingsSection(scope: .logging) }
            else { localModeNotice }
        case .workaround:
            workaroundSection
        case .paths:
            if modeManager.isLocalProxyMode { LocalPathsSection() }
        case .maintenanceLinks:
            Section {
                NavigationLink(value: SettingsAuxiliaryPage.storageData) {
                    Label("storage.title".localized(), systemImage: "internaldrive")
                }
                NavigationLink(value: SettingsAuxiliaryPage.about) {
                    Label("settings.navigation.openAbout".localized(), systemImage: "info.circle")
                }
                // 上游检查属于源码维护；独立于关于页中自有发行版的安装更新。
                NavigationLink(value: SettingsAuxiliaryPage.upstreamUpdates) {
                    Label("updates.upstream.title".localized(), systemImage: "arrow.triangle.branch")
                }
                if modeManager.isLocalProxyMode {
                    NavigationLink(value: SettingsAuxiliaryPage.logs) {
                        Label("settings.navigation.openLogs".localized(), systemImage: "doc.text.magnifyingglass")
                    }
                }
            } header: { Text(topic.title) }
        }
    }

    private var languageSection: some View {
        Section {
            // 保留完整语言集合和原有切换入口，系统 Picker 负责菜单及当前值的呈现。
            Picker("settings.language".localized(), selection: Binding(
                get: { LanguageManager.shared.currentLanguage },
                set: { LanguageManager.shared.setLanguage($0) }
            )) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
        } header: { Text("settings.language".localized()) }
    }

    private var workaroundSection: some View {
        Section {
            Button("troubleshooting.applyWorkaround".localized()) {
                CLIProxyManager.shared.applyBaseURLWorkaround()
            }
            Button("troubleshooting.restoreOriginal".localized()) {
                CLIProxyManager.shared.removeBaseURLWorkaround()
            }
        } header: {
            Text("troubleshooting.title".localized())
        } footer: {
            Text("troubleshooting.description".localized())
        }
    }
}

/// 设置中的页面入口一律使用 NavigationLink，避免跳走主侧栏后丢失系统返回路径。
private struct SettingsModelAliasesSection: View {
    @Environment(QuotaViewModel.self) private var viewModel

    var body: some View {
        Section {
            NavigationLink(value: SettingsAuxiliaryPage.aliases) {
                Text("cpaAliases.manage".localized())
            }
            if !viewModel.proxyManager.proxyStatus.running || viewModel.apiClient == nil {
                Label("cpaAliases.startProxy".localized(), systemImage: "network.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
            NavigationLink(value: SettingsAuxiliaryPage.agents) {
                Text("settings.navigation.openAgents".localized())
            }
        } header: {
            Text("cpaAliases.title".localized())
        } footer: {
            Text("settings.navigation.aliasHelp".localized() + " " + "cpaAliases.sharedWarning".localized())
        }
    }
}
