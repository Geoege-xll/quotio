import SwiftUI

/// 高级设置与 agent 弹窗使用同一个管理界面，所有操作直接作用于 CPA 配置。
struct CPAModelAliasManagerSheet: View {
    @Bindable var store: CPAModelAliasesViewModel
    let client: ManagementAPIClient?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var sourceID = ""
    @State private var alias = ""
    @State private var effort = ""
    @State private var search = ""
    @State private var previousSuggestion = ""
    @State private var pendingDelete: CPAModelAlias?

    private var source: CPAModelAliasSource? { store.sources.first { $0.id == sourceID } }
    private var entries: [CPAModelAlias] {
        store.aliases.filter { search.isEmpty || $0.alias.localizedCaseInsensitiveContains(search)
            || $0.model.localizedCaseInsensitiveContains(search) || $0.provider.localizedCaseInsensitiveContains(search) }
    }
    private var busy: Bool { store.isLoading || store.isSaving }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.branch").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("cpaAliases.title".localized()).font(.headline)
                    Text("cpaAliases.subtitle".localized()).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await store.load(client: client) } } label: {
                    if store.isLoading { SmallProgressView() }
                    else { Label("action.refresh".localized(), systemImage: "arrow.clockwise") }
                }
                .buttonStyle(.quotioSecondaryCapsule).disabled(busy)
                QuotioCircularIconButton(systemImage: "xmark") { dismiss() }
                    .disabled(store.isSaving).accessibilityLabel("action.close".localized())
            }
            .padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = store.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .quotioInsetCard()
                    }
                    if !store.unavailableChannels.isEmpty {
                        Label(String(format: "cpaAliases.partialCatalog".localized(), store.unavailableChannels.joined(separator: ", ")),
                              systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    createSection
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("cpaAliases.existing".localized()).font(.subheadline.weight(.semibold))
                            Text("\(store.aliases.count)").font(.caption.monospacedDigit())
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(QuotioTheme.Colors.cardTag(for: colorScheme), in: Capsule())
                        }
                        TextField("cpaAliases.search".localized(), text: $search).modifier(CPAAliasInputStyle())
                        LazyVStack(spacing: 8) {
                            ForEach(entries) { entry in aliasRow(entry) }
                            if entries.isEmpty && !store.isLoading {
                                Text("cpaAliases.empty".localized()).font(.callout).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity).padding(.vertical, 20)
                            }
                        }
                    }
                    .quotioInsetCard()
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
            HStack {
                Text("cpaAliases.sharedWarning".localized()).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("action.done".localized()) { dismiss() }
                    .buttonStyle(.quotioPrimaryCapsule).disabled(store.isSaving)
            }
            .padding(20)
        }
        .frame(width: 760, height: 640)
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
        .interactiveDismissDisabled(store.isSaving)
        .task { await store.load(client: client) }
        .onChange(of: sourceID) { effort = ""; suggestAlias() }
        .onChange(of: effort) { suggestAlias() }
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

    private var createSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("cpaAliases.create".localized()).font(.subheadline.weight(.semibold))
            Picker("cpaAliases.source".localized(), selection: $sourceID) {
                Text("cpaAliases.chooseSource".localized()).tag("")
                ForEach(store.sources) { source in
                    Text(verbatim: "\(source.model) · \(source.provider)").tag(source.id)
                }
            }
            .pickerStyle(.menu).modifier(AgentConfigMenuStyle())
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("cpaAliases.alias".localized()).font(.caption).foregroundStyle(.secondary)
                    TextField("cpaAliases.aliasPlaceholder".localized(), text: $alias)
                        .modifier(CPAAliasInputStyle()).accessibilityLabel("cpaAliases.alias".localized())
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("agents.reasoningEffort".localized()).font(.caption).foregroundStyle(.secondary)
                    Picker("agents.reasoningEffort".localized(), selection: $effort) {
                        Text("cpaAliases.unspecified".localized()).tag("")
                        ForEach(source?.levels ?? [], id: \.self) { level in Text(verbatim: level).tag(level) }
                    }
                    .labelsHidden().pickerStyle(.menu).modifier(AgentConfigMenuStyle())
                    .disabled(source?.levels.isEmpty != false)
                }
                .frame(width: 180)
            }
            HStack(alignment: .center, spacing: 16) {
                Text("cpaAliases.effortHelp".localized()).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    Task {
                        if await store.create(sourceID: sourceID, alias: alias, effort: effort) {
                            alias = ""; previousSuggestion = ""
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if store.isSaving { SmallProgressView() } else { Image(systemName: "plus") }
                        Text("cpaAliases.saveToCPA".localized())
                    }
                }
                .buttonStyle(.quotioPrimaryCapsule)
                .disabled(busy || source == nil || alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .disabled(busy)
        .quotioInsetCard()
    }

    private func aliasRow(_ entry: CPAModelAlias) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: entry.alias).font(.callout.weight(.semibold)).textSelection(.enabled)
                Label(entry.model, systemImage: "arrow.turn.down.right")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(verbatim: entry.provider).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(verbatim: entry.effort ?? "cpaAliases.unspecified".localized())
                .font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 4)
                .background(QuotioTheme.Colors.cardTag(for: colorScheme), in: Capsule())
            Button { pendingDelete = entry } label: { Image(systemName: "trash") }
                .buttonStyle(.quotioMicroCapsule).disabled(busy)
                .accessibilityLabel("action.delete".localized() + " " + entry.alias)
        }
        .padding(12)
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme),
                    in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous))
    }

    private func suggestAlias() {
        guard let source else { return }
        let suggested = source.model + (effort.isEmpty ? "-alias" : "-" + effort)
        // 只更新由界面自动建议的值，用户手动编辑后切换强度不覆盖其别名。
        if alias.isEmpty || alias == previousSuggestion { alias = suggested }
        previousSuggestion = suggested
    }
}

/// 模型配置只显示 CPA 的实际别名信息，不在本地复制一份可编辑的强度策略。
struct CPAModelAliasSummary: View {
    let model: String
    let aliases: [CPAModelAlias]

    var body: some View {
        let entries = CPAModelAliasPolicy.entries(for: model, in: aliases)
        if !entries.isEmpty {
            if let effort = CPAModelAliasPolicy.fixedEffort(for: model, in: aliases) {
                Label(String(format: "cpaAliases.fixedSummary".localized(), effort), systemImage: "brain")
                    .font(.caption).foregroundStyle(.secondary)
            } else if entries.contains(where: { $0.effort != nil }) {
                Label("cpaAliases.routedSummary".localized(), systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("cpaAliases.aliasSummary".localized(), systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 新增输入控件统一采用胶囊沉槽，并在本地维护焦点及减弱动态效果的偏好。
struct CPAAliasInputStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).focused($focused)
            .padding(.horizontal, 14).frame(minHeight: 34)
            .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
            .overlay(Capsule().strokeBorder(
                focused ? Color.accentColor.opacity(0.6) : QuotioTheme.Colors.sidebarBorder(for: colorScheme),
                lineWidth: focused ? 1.5 : 0.5
            ))
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.72), value: focused)
    }
}

/// 设置页的正式入口与 agent 弹窗复用同一服务；代理不可用时明确禁用保存能力。
struct CPAModelAliasSettingsSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var store = CPAModelAliasesViewModel()
    @State private var isPresented = false

    var body: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("cpaAliases.title".localized()).font(.callout.weight(.medium))
                    Text("cpaAliases.subtitle".localized()).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("cpaAliases.manage".localized()) { isPresented = true }
                    .buttonStyle(.quotioSecondaryCapsule)
                    .disabled(viewModel.apiClient == nil || !viewModel.proxyManager.proxyStatus.running)
            }
        } header: {
            Label("cpaAliases.advanced".localized(), systemImage: "slider.horizontal.3")
        }
        .sheet(isPresented: $isPresented) {
            CPAModelAliasManagerSheet(store: store, client: viewModel.apiClient)
        }
    }
}
