import SwiftUI

/// 模型槽中的启动模型选择器：角色引用、CPA 模型别名与真实模型分组展示。
/// 弹层仅在用户明确选择时提交 Binding；目录刷新、搜索和关闭弹层都不会改写已有配置。
struct AgentDefaultModelPicker: View {
    let agent: CLIAgent
    @Binding var selectedModel: String
    let availableModels: [AvailableModel]
    let isFetchingModels: Bool
    let onRefresh: () -> Void
    var slotModels: [ModelSlot: String] = [:]
    var aliases: [CPAModelAlias] = []
    var showsHeader: Bool = true
    /// 模型槽表格只呈现紧凑选择按钮，说明与名称由同一行的其他列负责，避免重复撑高行。
    var isCompact: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPresented = false
    @State private var search = ""

    private var selectedSlot: ModelSlot? {
        agent == .claudeCode ? ModelSlot.allCases.first { $0.rawValue == selectedModel } : nil
    }

    private var selectedAlias: CPAModelAlias? {
        aliases.first { $0.alias.caseInsensitiveCompare(selectedModel) == .orderedSame }
    }

    private func model(for slot: ModelSlot) -> String {
        slotModels[slot] ?? AvailableModel.defaultModels[slot]?.name ?? slot.rawValue
    }

    private var requestModel: String {
        if let selectedSlot {
            return model(for: selectedSlot)
        }
        if selectedModel.isEmpty {
            return "agents.pi.selectModel".localized()
        }
        return selectedModel
    }

    private var title: String {
        if let selectedSlot {
            return String(format: "agents.defaultModel.followSlot".localized(), selectedSlot.rawValue.capitalized)
        }
        return selectedModel.isEmpty ? "agents.pi.selectModel".localized() : selectedModel
    }

    private var matchingAliases: [CPAModelAlias] {
        aliases.filter {
            search.isEmpty ||
            $0.alias.localizedCaseInsensitiveContains(search) ||
            $0.model.localizedCaseInsensitiveContains(search) ||
            $0.provider.localizedCaseInsensitiveContains(search)
        }
    }

    private var matchingModels: [String] {
        let aliasNames = Set(aliases.map { $0.alias.lowercased() })
        let roles = agent == .claudeCode ? Set(ModelSlot.allCases.map(\.rawValue)) : []
        var set = Set(availableModels.map(\.name))
        if !selectedModel.isEmpty && !roles.contains(selectedModel) && !aliasNames.contains(selectedModel.lowercased()) {
            set.insert(selectedModel)
        }
        return set
            .filter { !aliasNames.contains($0.lowercased()) && !roles.contains($0) && !$0.isEmpty }
            .filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var canAddCustomModel: Bool {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let existsInAliases = aliases.contains { $0.alias.caseInsensitiveCompare(trimmed) == .orderedSame }
        let existsInModels = availableModels.contains { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        let existsInRoles = agent == .claudeCode && ModelSlot.allCases.contains { $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame }
        return !existsInAliases && !existsInModels && !existsInRoles
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                HStack {
                    Label("agents.defaultModel".localized(), systemImage: "play.circle")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button(action: onRefresh) {
                        if isFetchingModels {
                            SmallProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.quotioMicroCapsule)
                    .disabled(isFetchingModels)
                    .help("agents.models.refresh".localized())
                    .accessibilityLabel("agents.models.refresh".localized())
                }
            }

            Button {
                search = ""
                isPresented = true
            } label: {
                HStack(spacing: isCompact ? 6 : 10) {
                    if !isCompact { pickerLeadingIcon }

                    Text(verbatim: title)
                        .font(isCompact ? .system(size: 12, design: .monospaced) : .system(.body, design: .monospaced))
                        .fontWeight(.medium)
                        .foregroundStyle(selectedModel.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !isCompact, let alias = selectedAlias {
                        Text("cpaAliases.title".localized())
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.accentColor)

                        Text("→ " + alias.model)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, isCompact ? 10 : 14)
                .frame(maxWidth: .infinity, minHeight: isCompact ? 34 : 36, alignment: .leading)
                .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        isPresented ? Color.accentColor.opacity(0.6) : QuotioTheme.Colors.sidebarBorder(for: colorScheme),
                        lineWidth: isPresented ? 1.5 : 0.5
                    )
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("agents.defaultModel".localized())
            .accessibilityValue(title)
            .accessibilityIdentifier("agentDefaultModelPicker")
            .help(requestModel)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) { modelPopover }

            if !isCompact, selectedSlot != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("cpaAliases.actualModel".localized())
                    Text(verbatim: requestModel).fontDesign(.monospaced).textSelection(.enabled)
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            if !isCompact, selectedAlias == nil && selectedSlot == nil {
                CPAModelAliasSummary(model: requestModel, aliases: aliases)
            }

            if showsHeader {
                Text((agent == .pi ? "agents.pi.modelInfo" : (agent == .claudeCode ? "agents.defaultModel.claudeInfo" : "agents.defaultModel.codexInfo")).localized())
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var pickerLeadingIcon: some View {
        if selectedSlot != nil {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(agent.color)
        } else if selectedAlias != nil {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(Color.accentColor)
        } else {
            Image(systemName: "cpu")
                .foregroundStyle(agent.color)
        }
    }

    private var modelPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("agents.defaultModel".localized()).font(.headline)
                Spacer()
                Button("action.close".localized()) { isPresented = false }
                    .buttonStyle(.quotioMicroCapsule)
                    .keyboardShortcut(.escape, modifiers: [])
            }

            QuotioCapsuleTextField(
                "cpaAliases.search".localized(),
                text: $search,
                systemImage: "magnifyingglass",
                showsClearButton: true,
                autofocus: true
            )

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if canAddCustomModel {
                        customModelOptionRow(search.trimmingCharacters(in: .whitespacesAndNewlines))
                    }

                    if agent == .claudeCode {
                        Text("cpaAliases.followRole".localized())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)

                        ForEach(ModelSlot.allCases) { slot in
                            roleOptionRow(slot)
                        }
                    }

                    if !matchingAliases.isEmpty {
                        Text("cpaAliases.title".localized())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.top, 4)

                        ForEach(matchingAliases) { alias in
                            aliasOptionRow(alias)
                        }
                    }

                    if !matchingModels.isEmpty {
                        Text("cpaAliases.specificModel".localized())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)

                        ForEach(matchingModels, id: \.self) { name in
                            modelOptionRow(name)
                        }
                    }

                    if matchingAliases.isEmpty && matchingModels.isEmpty && !canAddCustomModel {
                        Text("cpaAliases.noMatches".localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
            }
            .frame(maxHeight: 330)
        }
        .padding(14)
        .frame(width: 480)
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
    }

    private func roleOptionRow(_ slot: ModelSlot) -> some View {
        let isSelected = slot.rawValue == selectedModel
        return Button {
            selectedModel = slot.rawValue
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(agent.color)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "agents.defaultModel.followSlot".localized(), slot.rawValue.capitalized))
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(verbatim: model(for: slot))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(agent.color)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isSelected ? agent.color.opacity(0.1) : QuotioTheme.Colors.cardInset(for: colorScheme).opacity(0.5),
                in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func aliasOptionRow(_ entry: CPAModelAlias) -> some View {
        let isSelected = entry.alias.caseInsensitiveCompare(selectedModel) == .orderedSame
        return Button {
            selectedModel = entry.alias
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: entry.alias)
                            .font(.system(.callout, design: .monospaced))
                            .fontWeight(.semibold)
                            .lineLimit(1)

                        Text("cpaAliases.title".localized())
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }

                    HStack(spacing: 4) {
                        Text("→ " + entry.model)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text("· " + entry.provider)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 8)

                if let effort = entry.effort, !effort.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "brain")
                            .font(.system(size: 9))
                        Text(verbatim: effort)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isSelected ? Color.accentColor.opacity(0.1) : QuotioTheme.Colors.cardInset(for: colorScheme).opacity(0.5),
                in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func modelOptionRow(_ name: String) -> some View {
        let isSelected = name.caseInsensitiveCompare(selectedModel) == .orderedSame
        return Button {
            selectedModel = name
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .foregroundStyle(agent.color)
                    .frame(width: 18)

                Text(verbatim: name)
                    .font(.system(.callout, design: .monospaced))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(agent.color)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isSelected ? agent.color.opacity(0.1) : QuotioTheme.Colors.cardInset(for: colorScheme).opacity(0.5),
                in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func customModelOptionRow(_ name: String) -> some View {
        Button {
            selectedModel = name
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name)
                        .font(.system(.callout, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)

                    Text("使用此自定义模型名称")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.right.circle")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Color.accentColor.opacity(0.08),
                in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// 保留原生菜单的键盘交互，在项目统一的胶囊沉槽中显示焦点。
struct AgentConfigMenuStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderless)
            .focused($isFocused)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 32)
            .background(Capsule().fill(QuotioTheme.Colors.cardInset(for: colorScheme)))
            .overlay(Capsule().strokeBorder(
                isFocused ? Color.accentColor : QuotioTheme.Colors.sidebarBorder(for: colorScheme),
                lineWidth: isFocused ? 1.5 : 0.5
            ))
            .opacity(isEnabled ? 1 : 0.5)
    }
}
