import SwiftUI

/// 设置首页使用系统分组表单，顶部复用原有模式卡片并横向平分布局。
/// 其余功能仍为原生导航行，页面底色与产品主题保持一致。
struct SettingsOverviewScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Binding var search: String
    let modeFocusRequest: UUID
    @State private var modeManager = OperatingModeManager.shared

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matches: [SettingsTopic] {
        SettingsTopic.allCases.filter { $0 != .mode && $0.matches(query) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                OperatingModeSection().id(SettingsTopic.mode)
                if query.isEmpty {
                    categoryGroup("settings.navigation.group.app", categories: [.general, .menuBar, .usage, .notifications])
                    categoryGroup("settings.navigation.group.cpa", categories: [.service, .requests])
                    categoryGroup("settings.navigation.group.maintenance", categories: [.security, .maintenance])
                } else if matches.isEmpty && !SettingsTopic.mode.matches(query) {
                    Section {
                        ContentUnavailableView("settings.navigation.noResults".localized(), systemImage: "magnifyingglass",
                            description: Text("settings.navigation.searchHelp".localized()))
                    }
                } else if !matches.isEmpty {
                    Section {
                        ForEach(matches) { topic in
                            NavigationLink(value: SettingsDestination(category: topic.category, topic: topic)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(topic.title)
                                    Text(topic.category.title).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: { Text("settings.navigation.searchResults".localized()) }
                }
            }
            .formStyle(.grouped)
            .modifier(SettingsPageBackground())
            .task(id: modeFocusRequest) {
                // 从依赖本地模式的页面回到首页时定位真实模式控件，不再创建第二个模式编辑页。
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo(SettingsTopic.mode, anchor: .top)
            }
        }
        .navigationTitle("nav.settings".localized())
        .searchable(text: $search, prompt: Text("settings.navigation.search".localized()))
    }

    private func categoryGroup(_ titleKey: String, categories: [SettingsCategory]) -> some View {
        Section {
            ForEach(categories) { category in
                NavigationLink(value: SettingsDestination(category: category)) {
                    LabeledContent {
                        Text(summary(category))
                            .foregroundStyle(.secondary).monospacedDigit()
                            .lineLimit(1).truncationMode(.tail)
                    } label: {
                        Label(category.title, systemImage: category.icon)
                    }
                }
                .help(category.subtitle)
            }
        } header: { Text(titleKey.localized()) }
    }

    private func summary(_ category: SettingsCategory) -> String {
        let settings = MenuBarSettingsManager.shared
        switch category {
        case .general:
            return LanguageManager.shared.currentLanguage.displayName + " · " + AppearanceManager.shared.appearanceMode.localizationKey.localized()
        case .menuBar:
            return (settings.showMenuBarIcon ? "settings.navigation.menuBar.visible" : "settings.navigation.menuBar.hidden").localized()
        case .usage:
            return (settings.quotaDisplayMode == .remaining ? "settings.quota.displayMode.remaining" : "settings.quota.displayMode.used").localized()
        case .notifications:
            let manager = NotificationManager.shared
            if !manager.isAuthorized { return "settings.notifications.notAuthorized".localized() }
            return (manager.notificationsEnabled ? "settings.navigation.enabled" : "settings.navigation.disabled").localized()
        case .service, .requests:
            if !modeManager.isLocalProxyMode { return "settings.navigation.requiresLocal".localized() }
            return (viewModel.proxyManager.proxyStatus.running ? "status.running" : "status.stopped").localized()
        case .security:
            return (settings.hideSensitiveInfo ? "settings.navigation.security.hidden" : "settings.navigation.security.visible").localized()
        case .maintenance:
            return "settings.version".localized() + ": " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
        }
    }
}
