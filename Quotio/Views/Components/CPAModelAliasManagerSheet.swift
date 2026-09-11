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
    @State private var copiedAlias: String?

    private var source: CPAModelAliasSource? { store.sources.first { $0.id == sourceID } }
    private var entries: [CPAModelAlias] {
        store.aliases.filter {
            search.isEmpty ||
            $0.alias.localizedCaseInsensitiveContains(search) ||
            $0.model.localizedCaseInsensitiveContains(search) ||
            $0.provider.localizedCaseInsensitiveContains(search)
        }
    }
    private var busy: Bool { store.isLoading || store.isSaving }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            VStack(spacing: 14) {
                if let error = store.errorMessage {
                    errorBanner(error)
                }

                if !store.unavailableChannels.isEmpty {
                    partialCatalogBanner
                }

                createCard

                existingAliasesCard
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footerBar
        }
        .frame(width: 780, height: 650)
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
        .interactiveDismissDisabled(store.isSaving)
        .task { await store.load(client: client) }
        .onChange(of: sourceID) { effort = ""; suggestAlias() }
        .onChange(of: effort) { suggestAlias() }
        .confirmationDialog(
            "cpaAliases.deleteTitle".localized(),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
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

    // MARK: - Header & Footer

    private var headerBar: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("cpaAliases.title".localized())
                    .font(.headline)
                Text("cpaAliases.subtitle".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await store.load(client: client) }
            } label: {
                if store.isLoading {
                    SmallProgressView()
                } else {
                    Label("action.refresh".localized(), systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.quotioSecondaryCapsule)
            .disabled(busy)

            QuotioCircularIconButton(systemImage: "xmark") { dismiss() }
                .disabled(store.isSaving)
                .accessibilityLabel("action.close".localized())
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("cpaAliases.sharedWarning".localized())
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("action.done".localized()) { dismiss() }
                .buttonStyle(.quotioPrimaryCapsule)
                .disabled(store.isSaving)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
    }

    // MARK: - Banners

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(QuotioTheme.Colors.warning)
            Text(error)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .quotioInsetCard(cornerRadius: QuotioTheme.Radius.sm, padding: 10)
    }

    private var partialCatalogBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "cpaAliases.partialCatalog".localized(), store.unavailableChannels.joined(separator: ", ")))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Create Section (Card 1)

    private var createCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("cpaAliases.create".localized())
                    .font(.subheadline.weight(.semibold))
            }

            // 原模型与来源选择器（带独立字段标题与可用数量提示）
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("cpaAliases.source".localized())
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !store.sources.isEmpty {
                        Text(String(format: "availableModels.modelCount".localized(), store.sources.count))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                CPAModelSourceSelectorButton(
                    sources: store.sources,
                    selectedSourceID: $sourceID,
                    disabled: busy
                )
            }

            // 客户端模型别名 + 思考强度并排
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("cpaAliases.alias".localized())
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    QuotioCapsuleTextField(
                        "cpaAliases.aliasPlaceholder".localized(),
                        text: $alias,
                        systemImage: "tag",
                        showsClearButton: true,
                        monospaced: true
                    )
                    .accessibilityLabel("cpaAliases.alias".localized())
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("agents.reasoningEffort".localized())
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    reasoningEffortMenu
                }
                .frame(width: 210)
            }

            // 底部帮助说明与保存主按钮
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                    Text("cpaAliases.effortHelp".localized())
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Button {
                    Task {
                        if await store.create(sourceID: sourceID, alias: alias, effort: effort) {
                            alias = ""
                            previousSuggestion = ""
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if store.isSaving {
                            SmallProgressView()
                        } else {
                            Image(systemName: "plus")
                        }
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

    private var reasoningEffortMenu: some View {
        Menu {
            Button {
                effort = ""
            } label: {
                HStack {
                    Text("cpaAliases.unspecified".localized())
                    if effort.isEmpty { Image(systemName: "checkmark") }
                }
            }

            if let levels = source?.levels, !levels.isEmpty {
                Divider()
                ForEach(levels, id: \.self) { level in
                    Button {
                        effort = level
                    } label: {
                        HStack {
                            Text(verbatim: level)
                            if effort == level { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .font(.system(size: 11))
                    .foregroundStyle(effort.isEmpty ? .secondary : Color.accentColor)

                Text(effort.isEmpty ? "cpaAliases.unspecified".localized() : effort)
                    .font(.system(size: 12, weight: effort.isEmpty ? .regular : .medium))
                    .foregroundStyle(effort.isEmpty ? .secondary : .primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
            .overlay(
                Capsule().strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .disabled(busy || source == nil || source?.levels.isEmpty == true)
        .opacity((source == nil || source?.levels.isEmpty == true) ? 0.6 : 1.0)
    }

    // MARK: - Existing Aliases Section (Card 2)

    private var existingAliasesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 工具栏：左侧标题与计数，右侧固定搜索栏
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                    Text("cpaAliases.existing".localized())
                        .font(.subheadline.weight(.semibold))
                    Text("\(store.aliases.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(QuotioTheme.Colors.cardTag(for: colorScheme), in: Capsule())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                QuotioCapsuleTextField(
                    "cpaAliases.search".localized(),
                    text: $search,
                    systemImage: "magnifyingglass",
                    showsClearButton: true
                )
                .frame(width: 230)
            }

            // 独立内部滚动的别名列表
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(entries) { entry in
                        aliasRow(entry)
                    }

                    if entries.isEmpty && !store.isLoading {
                        emptyView
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .quotioInsetCard()
    }

    private func aliasRow(_ entry: CPAModelAlias) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(verbatim: entry.alias)
                        .font(.callout.weight(.semibold))
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)

                    Button {
                        copyAlias(entry.alias)
                    } label: {
                        Image(systemName: copiedAlias == entry.alias ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(copiedAlias == entry.alias ? QuotioTheme.Colors.success : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("action.copy".localized())
                }

                HStack(spacing: 6) {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Text(verbatim: entry.model)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(verbatim: entry.provider)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if let effort = entry.effort, !effort.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .font(.caption2)
                    Text(verbatim: effort)
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
                .foregroundStyle(Color.accentColor)
            } else {
                Text("cpaAliases.unspecified".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(QuotioTheme.Colors.cardTag(for: colorScheme), in: Capsule())
            }

            QuotioCircularIconButton(systemImage: "trash", tint: .red, backgroundTint: .red) {
                pendingDelete = entry
            }
            .disabled(busy)
            .accessibilityLabel("action.delete".localized() + " " + entry.alias)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            QuotioTheme.Colors.cardBackground(for: colorScheme),
            in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
        )
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: search.isEmpty ? "arrow.triangle.branch" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(search.isEmpty ? "cpaAliases.empty".localized() : "cpaAliases.noMatches".localized())
                .font(.callout)
                .foregroundStyle(.secondary)
            if !search.isEmpty {
                Button("action.clear".localized()) {
                    search = ""
                }
                .buttonStyle(.quotioMicroCapsule)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func copyAlias(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) {
            copiedAlias = text
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedAlias == text {
                withAnimation(.easeInOut(duration: 0.15)) {
                    copiedAlias = nil
                }
            }
        }
    }

    private func suggestAlias() {
        guard let source else { return }
        let suggested = source.model + (effort.isEmpty ? "-alias" : "-" + effort)
        // 只更新由界面自动建议的值，用户手动编辑后切换强度不覆盖其别名。
        if alias.isEmpty || alias == previousSuggestion { alias = suggested }
        previousSuggestion = suggested
    }
}

// MARK: - CPAModelSourceSelectorButton

/// 原模型与来源专用选择器：胶囊展示当前选中模型与 Provider，
/// 点击唤起带搜索、按 Provider 分组与思考等级标记的 Popover 选择面板。
struct CPAModelSourceSelectorButton: View {
    let sources: [CPAModelAliasSource]
    @Binding var selectedSourceID: String
    let disabled: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPresented = false
    @State private var searchText = ""

    private var selectedSource: CPAModelAliasSource? {
        sources.first { $0.id == selectedSourceID }
    }

    private var filteredSources: [CPAModelAliasSource] {
        if searchText.isEmpty { return sources }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return sources.filter {
            $0.model.localizedCaseInsensitiveContains(query) ||
            $0.provider.localizedCaseInsensitiveContains(query) ||
            ($0.channel?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        Button {
            searchText = ""
            isPresented = true
        } label: {
            HStack(spacing: 10) {
                if let source = selectedSource {
                    Image(systemName: "cube.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)

                    Text(verbatim: source.model)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(verbatim: source.provider)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(QuotioTheme.Colors.cardTag(for: colorScheme), in: Capsule())
                        .foregroundStyle(.secondary)

                    if !source.levels.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "brain")
                                .font(.system(size: 9))
                            Text("\(source.levels.count)")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                    }
                } else {
                    Image(systemName: "cube")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("cpaAliases.chooseSource".localized())
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isPresented
                        ? Color.accentColor.opacity(0.6)
                        : QuotioTheme.Colors.sidebarBorder(for: colorScheme),
                    lineWidth: isPresented ? 1.5 : 0.5
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            sourcePopover
        }
    }

    private var sourcePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("cpaAliases.source".localized(), systemImage: "cube.transparent")
                    .font(.headline)
                Spacer()
                Text(String(format: "availableModels.displayedCount".localized(), filteredSources.count, sources.count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            QuotioCapsuleTextField(
                "cpaAliases.search".localized(),
                text: $searchText,
                systemImage: "magnifyingglass",
                showsClearButton: true,
                autofocus: true
            )

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredSources) { source in
                        sourceOptionRow(source)
                    }

                    if filteredSources.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                            Text("cpaAliases.noMatches".localized())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .padding(14)
        .frame(width: 480)
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
    }

    private func sourceOptionRow(_ source: CPAModelAliasSource) -> some View {
        let isSelected = selectedSourceID == source.id
        return Button {
            selectedSourceID = source.id
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "cube.fill" : "cube")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: source.model)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(verbatim: source.provider)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(QuotioTheme.Colors.cardTag(for: colorScheme), in: Capsule())
                            .foregroundStyle(.secondary)

                        if let channel = source.channel, !channel.isEmpty {
                            Text(verbatim: channel)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer(minLength: 8)

                if !source.levels.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "brain")
                            .font(.system(size: 9))
                        Text(source.levels.joined(separator: "/"))
                            .font(.system(size: 9))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.08)
                    : QuotioTheme.Colors.cardInset(for: colorScheme).opacity(0.5),
                in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
