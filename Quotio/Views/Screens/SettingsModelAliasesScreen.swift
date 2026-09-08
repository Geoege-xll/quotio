import SwiftUI

/// 设置专用的原生别名页面。复用现有 CPA ViewModel 与服务，保持创建、删除、
/// 配置版本检查和部分保存失败提示；代理配置弹窗继续使用原有 sheet，不受此导航改动影响。
struct SettingsModelAliasesScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var store = CPAModelAliasesViewModel()
    @State private var search = ""
    @State private var pendingDelete: CPAModelAlias?

    private var available: Bool {
        OperatingModeManager.shared.isLocalProxyMode
            && viewModel.proxyManager.proxyStatus.running && viewModel.apiClient != nil
    }
    private var busy: Bool { store.isLoading || store.isSaving }
    private var entries: [CPAModelAlias] {
        store.aliases.filter { search.isEmpty || $0.alias.localizedCaseInsensitiveContains(search)
            || $0.model.localizedCaseInsensitiveContains(search) || $0.provider.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Form {
            if !available {
                Section {
                    Label("cpaAliases.startProxy".localized(), systemImage: "network.slash")
                }
            } else {
                Section {
                    NavigationLink {
                        SettingsModelAliasEditor(store: store, client: viewModel.apiClient)
                    } label: {
                        Label("cpaAliases.create".localized(), systemImage: "plus")
                    }
                    .disabled(busy)
                } footer: { Text("cpaAliases.sharedWarning".localized()) }
                statusSections
                Section {
                    ForEach(entries) { entry in
                        aliasRow(entry)
                    }
                    if entries.isEmpty && !store.isLoading {
                        Text("cpaAliases.empty".localized()).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("cpaAliases.existing".localized() + " (\(store.aliases.count))").monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
        .modifier(SettingsPageBackground())
        .navigationTitle("cpaAliases.title".localized())
        .searchable(text: $search, prompt: Text("cpaAliases.search".localized()))
        .toolbar {
            ToolbarItem {
                Button { Task { await store.load(client: viewModel.apiClient) } } label: {
                    Label("action.refresh".localized(), systemImage: "arrow.clockwise")
                }
                .disabled(busy || !available)
            }
        }
        // 不可用时不发起管理请求；返回列表时重新读取，避免使用其他客户端修改前的快照。
        .task(id: available) {
            if available && !store.isSaving { await store.load(client: viewModel.apiClient) }
        }
        .navigationBarBackButtonHidden(store.isSaving)
        .confirmationDialog("cpaAliases.deleteTitle".localized(), isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("action.delete".localized(), role: .destructive) {
                guard let entry = pendingDelete else { return }
                pendingDelete = nil
                Task { await store.delete(entry) }
            }
            Button("action.cancel".localized(), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(String(format: "cpaAliases.deleteMessage".localized(), pendingDelete?.alias ?? ""))
        }
    }

    @ViewBuilder private var statusSections: some View {
        if store.isLoading || store.isSaving {
            Section { ProgressView().controlSize(.small) }
        }
        if let error = store.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .textSelection(.enabled)
            }
        }
        if !store.unavailableChannels.isEmpty {
            Section {
                Text(String(format: "cpaAliases.partialCatalog".localized(), store.unavailableChannels.joined(separator: ", ")))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func aliasRow(_ entry: CPAModelAlias) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: entry.alias).fontWeight(.medium).textSelection(.enabled)
                Text(verbatim: entry.model).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
                Text(verbatim: entry.provider).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(verbatim: entry.effort ?? "cpaAliases.unspecified".localized())
                .font(.caption).foregroundStyle(.secondary)
            Button { pendingDelete = entry } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).disabled(busy)
                .accessibilityLabel("action.delete".localized() + " " + entry.alias)
        }
    }
}

/// 新增别名使用系统 Push 表单；自动建议仍只更新未被用户手动改写的别名。
/// 保存期间暂时禁止返回，防止共享 CPA 配置写入尚未完成时销毁操作页面。
private struct SettingsModelAliasEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: CPAModelAliasesViewModel
    let client: ManagementAPIClient?
    @State private var sourceID = ""
    @State private var alias = ""
    @State private var effort = ""
    @State private var previousSuggestion = ""
    @State private var sourceSearch = ""

    private var source: CPAModelAliasSource? { store.sources.first { $0.id == sourceID } }
    private var busy: Bool { store.isLoading || store.isSaving }
    private var sources: [CPAModelAliasSource] {
        store.sources.filter { sourceSearch.isEmpty || $0.id == sourceID
            || $0.model.localizedCaseInsensitiveContains(sourceSearch)
            || $0.provider.localizedCaseInsensitiveContains(sourceSearch) }
    }

    var body: some View {
        Form {
            Section {
                TextField("cpaAliases.search".localized(), text: $sourceSearch)
                Picker("cpaAliases.source".localized(), selection: $sourceID) {
                    Text("cpaAliases.chooseSource".localized()).tag("")
                    ForEach(sources) { source in
                        Text(verbatim: "\(source.model) · \(source.provider)").tag(source.id)
                    }
                }
                TextField("cpaAliases.alias".localized(), text: $alias,
                          prompt: Text("cpaAliases.aliasPlaceholder".localized()))
                Picker("agents.reasoningEffort".localized(), selection: $effort) {
                    Text("cpaAliases.unspecified".localized()).tag("")
                    ForEach(source?.levels ?? [], id: \.self) { level in
                        Text(verbatim: level).tag(level)
                    }
                }
                .disabled(source?.levels.isEmpty != false)
            } footer: { Text("cpaAliases.effortHelp".localized()) }
            .disabled(busy)
            if let error = store.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                    Button("settings.navigation.reload".localized()) {
                        Task { await store.load(client: client) }
                    }
                    .disabled(busy)
                }
            }
            Section {
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("cpaAliases.saveToCPA".localized()) {
                        Task {
                            if await store.create(sourceID: sourceID, alias: alias, effort: effort) { dismiss() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || source == nil || alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } footer: { Text("cpaAliases.sharedWarning".localized()) }
        }
        .formStyle(.grouped)
        .modifier(SettingsPageBackground())
        .navigationTitle("cpaAliases.create".localized())
        .navigationBarBackButtonHidden(store.isSaving)
        .onChange(of: sourceID) { effort = ""; suggestAlias() }
        .onChange(of: effort) { suggestAlias() }
    }

    private func suggestAlias() {
        guard let source else { return }
        let suggested = source.model + (effort.isEmpty ? "-alias" : "-" + effort)
        if alias.isEmpty || alias == previousSuggestion { alias = suggested }
        previousSuggestion = suggested
    }
}
