import SwiftUI

/// 低频维护操作沿用设置页的原生 Form、Section 与系统确认；不在统计筛选区混入删除入口。
/// 服务由应用层持有，离开或重建页面不会另建数据库消费者，也不会丢失正在进行的维护任务。
struct StorageDataScreen: View {
    let service: StorageMaintenanceService
    @Environment(\.locale) private var locale
    @State private var showsClearConfirmation = false
    @State private var pendingModules = Set<AnalyticsStorageModule>()

    var body: some View {
        Form {
            overviewSection
            dataManagementSection
            maintenanceSection

            if service.isBusy {
                Section { ProgressView("storage.operation.running".localized()).controlSize(.small) }
            }
            if let key = service.errorKey {
                Section {
                    Label(key.localized(), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else if let key = service.messageKey {
                Section {
                    Label(key.localized(), systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .modifier(SettingsPageBackground())
        .navigationTitle("storage.title".localized())
        .monospacedDigit()
        .disabled(service.isBusy)
        // 维护写入期间临时禁止本页返回；任务完成后恢复系统导航，不自行绘制返回栏。
        .navigationBarBackButtonHidden(service.isBusy)
        .task { await service.inspect() }
        .confirmationDialog("storage.data.confirm.title".localized(), isPresented: $showsClearConfirmation, titleVisibility: .visible) {
            Button("storage.data.confirm.action".localized(), role: .destructive) {
                let modules = pendingModules
                Task { await service.clearStatistics(modules) }
            }
            Button("action.cancel".localized(), role: .cancel) { pendingModules = [] }
        } message: {
            Text(String(format: "storage.data.confirm.message".localized(), selectedModuleNames))
        }
    }

    private var overviewSection: some View {
        Section {
            LabeledContent("storage.database.total".localized(), value: size(service.snapshot?.totalBytes))
            LabeledContent("storage.database.file".localized(), value: size(service.snapshot?.databaseBytes))
            LabeledContent("storage.database.wal".localized(), value: size(service.snapshot?.walBytes))
            Button("storage.inspect.refresh".localized()) { Task { await service.inspect() } }
        } header: { Text("storage.overview.title".localized()) }
          footer: { Text("storage.overview.help".localized()) }
    }

    private var dataManagementSection: some View {
        Section {
            ForEach(AnalyticsStorageModule.allCases) { module in
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(module.titleKey.localized())
                                .font(.body)
                            Text(String(format: "storage.records.format".localized(), recordCount(module)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: module.iconName)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("storage.data.clearAction".localized(), role: .destructive) {
                        pendingModules = [module]
                        showsClearConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(service.isBusy || (service.snapshot?.recordCounts[module] ?? 0) == 0)
                }
            }

            Button(role: .destructive) {
                pendingModules = Set(AnalyticsStorageModule.allCases)
                showsClearConfirmation = true
            } label: {
                HStack {
                    Spacer()
                    Text("storage.data.clearAll".localized())
                    Spacer()
                }
            }
            .accessibilityIdentifier("clearAnalyticsDataButton")
            .disabled(service.isBusy || isAllModulesEmpty)
        } header: { Text("storage.data.title".localized()) }
          footer: { Text("storage.data.help".localized()) }
    }

    private var maintenanceSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("storage.cache.clearTitle".localized())
                        .font(.body)
                    Text("storage.cache.clearSubtitle".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("storage.cache.clearAction".localized()) {
                    Task { await service.clearCaches() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("clearAnalyticsCachesButton")
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("storage.compact.title".localized())
                        .font(.body)
                    Text("storage.compact.subtitle".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("storage.compact.action".localized()) {
                    Task { await service.compact() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("compactAnalyticsDatabaseButton")
            }
        } header: { Text("storage.maintenance.title".localized()) }
          footer: { Text("storage.maintenance.help".localized()) }
    }

    private var isAllModulesEmpty: Bool {
        guard let snapshot = service.snapshot else { return false }
        return snapshot.recordCounts.values.allSatisfy { $0 == 0 }
    }

    private var selectedModuleNames: String {
        let names = AnalyticsStorageModule.allCases.filter { pendingModules.contains($0) }
            .map { $0.titleKey.localized() }
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: names) ?? names.joined(separator: ", ")
    }

    private func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func recordCount(_ module: AnalyticsStorageModule) -> String {
        guard let snapshot = service.snapshot else { return "—" }
        return (snapshot.recordCounts[module] ?? 0).formatted()
    }
}

private extension AnalyticsStorageModule {
    var iconName: String {
        switch self {
        case .dashboard: return "gauge.with.needle"
        case .clientUsage: return "chart.bar.xaxis"
        case .callAnalytics: return "desktopcomputer"
        case .quotaHistory: return "clock.arrow.circlepath"
        }
    }
}
