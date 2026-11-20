import SwiftUI

/// 设置首页沿用系统分组表单，服务设置与其他原生导航行共用同一个导航栈。
struct SettingsOverviewScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Binding var search: String

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matches: [SettingsTopic] {
        SettingsTopic.allCases.filter { $0.matches(query) }
    }

    var body: some View {
        Form {
            if query.isEmpty {
                categoryGroup("settings.navigation.group.app", categories: [.general, .usage, .notifications])
                categoryGroup("settings.navigation.group.cpa", categories: [.service, .requests])
                categoryGroup("settings.navigation.group.maintenance", categories: [.security, .maintenance])
            } else if matches.isEmpty {
                Section {
                    ContentUnavailableView("settings.navigation.noResults".localized(), systemImage: "magnifyingglass",
                        description: Text("settings.navigation.searchHelp".localized()))
                }
            } else {
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
        case .usage:
            return (settings.quotaDisplayMode == .remaining ? "settings.quota.displayMode.remaining" : "settings.quota.displayMode.used").localized()
        case .notifications:
            let manager = NotificationManager.shared
            if !manager.isAuthorized { return "settings.notifications.notAuthorized".localized() }
            return (manager.notificationsEnabled ? "settings.navigation.enabled" : "settings.navigation.disabled").localized()
        case .service, .requests:
            return (viewModel.proxyManager.proxyStatus.running ? "status.running" : "status.stopped").localized()
        case .security:
            return (settings.hideSensitiveInfo ? "settings.navigation.security.hidden" : "settings.navigation.security.visible").localized()
        case .maintenance:
            return "settings.version".localized() + ": " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
        }
    }
}
