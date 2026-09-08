import SwiftUI

/// 低频维护操作沿用设置页的原生 Form、Section 与系统确认；不在统计筛选区混入删除入口。
/// 服务由应用层持有，离开或重建页面不会另建数据库消费者，也不会丢失正在进行的维护任务。
struct StorageDataScreen: View {
    let service: StorageMaintenanceService
    @Environment(\.locale) private var locale
    @State private var selectedModules = Set<AnalyticsStorageModule>()
    @State private var showsClearConfirmation = false
    @State private var pendingModules = Set<AnalyticsStorageModule>()

    var body: some View {
        Form {
            Section {
                LabeledContent("storage.database.total".localized(), value: size(service.snapshot?.totalBytes))
                LabeledContent("storage.database.file".localized(), value: size(service.snapshot?.databaseBytes))
                LabeledContent("storage.database.wal".localized(), value: size(service.snapshot?.walBytes))
                ForEach(AnalyticsStorageModule.allCases) { module in
                    LabeledContent(module.titleKey.localized(), value: recordCount(module))
                }
                Button("storage.inspect.refresh".localized()) { Task { await service.inspect() } }
            } header: { Text("storage.overview.title".localized()) }
              footer: { Text("storage.overview.help".localized()) }

            Section {
                Button("storage.cache.clear".localized()) { Task { await service.clearCaches() } }
                    .accessibilityIdentifier("clearAnalyticsCachesButton")
                Button("storage.compact.action".localized()) { Task { await service.compact() } }
                    .accessibilityIdentifier("compactAnalyticsDatabaseButton")
            } header: { Text("storage.cache.title".localized()) }
              footer: { Text("storage.cache.help".localized()) }

            Section {
                ForEach(AnalyticsStorageModule.allCases) { module in
                    Toggle(module.titleKey.localized(), isOn: Binding(
                        get: { selectedModules.contains(module) },
                        set: { selected in
                            if selected { selectedModules.insert(module) }
                            else { selectedModules.remove(module) }
                        }
                    ))
                }
                Button("storage.data.clear".localized(), role: .destructive) {
                    // 确认界面固定本次选择；确认前后不读取可能变化的表单状态来扩大删除范围。
                    pendingModules = selectedModules
                    showsClearConfirmation = true
                }
                .disabled(selectedModules.isEmpty)
                .accessibilityIdentifier("clearAnalyticsDataButton")
            } header: { Text("storage.data.title".localized()) }
              footer: { Text("storage.data.help".localized()) }

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

    private var selectedModuleNames: String {
        let names = AnalyticsStorageModule.allCases.filter { pendingModules.contains($0) }
            .map { $0.titleKey.localized() }
        // 系统列表格式跟随应用语言，确认范围在英文等语言下也使用对应的连接词与标点。
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
