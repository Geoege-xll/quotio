import SwiftUI

/// 模型槽中的启动模型选择器：角色引用与真实模型分组展示，不复制角色当前的模型 ID。
/// 弹层仅在用户明确选择时提交 Binding；目录刷新、搜索和关闭弹层都不会改写已有配置。
struct AgentDefaultModelPicker: View {
    let agent: CLIAgent
    @Binding var selectedModel: String
    let availableModels: [AvailableModel]
    let isFetchingModels: Bool
    let onRefresh: () -> Void
    var slotModels: [ModelSlot: String] = [:]
    var aliases: [CPAModelAlias] = []

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPresented = false
    @State private var search = ""

    private var selectedSlot: ModelSlot? {
        agent == .claudeCode ? ModelSlot.allCases.first { $0.rawValue == selectedModel } : nil
    }

    private func model(for slot: ModelSlot) -> String {
        slotModels[slot] ?? AvailableModel.defaultModels[slot]?.name ?? slot.rawValue
    }

    private var requestModel: String { selectedSlot.map(model(for:)) ?? (selectedModel.isEmpty ? "agents.pi.selectModel".localized() : selectedModel) }
    private var title: String {
        selectedSlot.map { String(format: "agents.defaultModel.followSlot".localized(), $0.rawValue.capitalized) }
            ?? selectedModel
    }

    private var models: [String] {
        let roles = agent == .claudeCode ? Set(ModelSlot.allCases.map(\.rawValue)) : []
        return Set(availableModels.map(\.name) + [selectedModel])
            .filter { !$0.isEmpty && !roles.contains($0) }
            .filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("agents.defaultModel".localized(), systemImage: "play.circle")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button(action: onRefresh) {
                    if isFetchingModels { SmallProgressView() }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.quotioMicroCapsule)
                .disabled(isFetchingModels)
                .help("agents.models.refresh".localized())
                .accessibilityLabel("agents.models.refresh".localized())
            }
            Button {
                search = ""
                isPresented = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selectedSlot == nil ? "cpu" : "arrow.triangle.branch")
                        .foregroundStyle(agent.color)
                    Text(verbatim: title).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            }
            .buttonStyle(.quotioSecondaryCapsule)
            .accessibilityLabel("agents.defaultModel".localized())
            .accessibilityValue(title)
            .accessibilityIdentifier("agentDefaultModelPicker")
            .help(requestModel)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) { modelPopover }

            if selectedSlot != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("cpaAliases.actualModel".localized())
                    Text(verbatim: requestModel).fontDesign(.monospaced).textSelection(.enabled)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            CPAModelAliasSummary(model: requestModel, aliases: aliases)
            Text((agent == .pi ? "agents.pi.modelInfo" : (agent == .claudeCode ? "agents.defaultModel.claudeInfo" : "agents.defaultModel.codexInfo")).localized())
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var modelPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("agents.defaultModel".localized()).font(.headline)
                Spacer()
                Button("action.close".localized()) { isPresented = false }
                    .buttonStyle(.quotioMicroCapsule)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            TextField("cpaAliases.search".localized(), text: $search)
                .modifier(CPAAliasInputStyle())
                .accessibilityLabel("cpaAliases.search".localized())
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if agent == .claudeCode {
                        Text("cpaAliases.followRole".localized()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(ModelSlot.allCases) { slot in
                            option(value: slot.rawValue,
                                   title: String(format: "agents.defaultModel.followSlot".localized(), slot.rawValue.capitalized),
                                   detail: model(for: slot), symbol: "arrow.triangle.branch")
                        }
                    }
                    Text("cpaAliases.specificModel".localized())
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                    ForEach(models, id: \.self) { name in
                        option(value: name, title: name, detail: nil, symbol: "cpu")
                    }
                    if models.isEmpty {
                        Text("cpaAliases.noMatches".localized()).font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                }
            }
            .frame(maxHeight: 330)
        }
        .padding(16)
        .frame(width: 460)
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
    }

    private func option(value: String, title: String, detail: String?, symbol: String) -> some View {
        Button {
            selectedModel = value
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(agent.color).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if let detail {
                        Text(verbatim: detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: value == selectedModel ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(value == selectedModel ? agent.color : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: detail == nil ? 24 : 36, alignment: .leading)
            .contentShape(Capsule())
        }
        .buttonStyle(.quotioSecondaryCapsule)
        .help(detail ?? value)
        .accessibilityValue(value == selectedModel ? "cpaAliases.selected".localized() : "")
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
