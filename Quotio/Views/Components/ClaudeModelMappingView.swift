import SwiftUI

/// 三列按「模型角色 → 实际请求模型 → 显示名称」排列；名称编辑不改变请求模型。
/// 表单状态由原配置 ViewModel 持有，刷新目录不会丢失自定义模型或尚未保存的名称。
struct ClaudeModelMappingView: View {
    @Bindable var viewModel: AgentSetupViewModel
    var aliases: [CPAModelAlias] = []
    var onManageAliases: () -> Void = {}
    let onOneMillionChange: () -> Void

    private func requestModel(for slot: ModelSlot) -> String {
        let model = viewModel.currentConfiguration?.modelSlots[slot]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return model.isEmpty ? (AvailableModel.defaultModels[slot]?.name ?? "") : model
    }

    private func options(for slot: ModelSlot) -> [String] {
        Set(viewModel.availableModels.map(\.name) + [requestModel(for: slot)])
            .filter { !$0.isEmpty }
            .sorted()
    }

    private func uses1MContext(for slot: ModelSlot) -> Bool {
        viewModel.currentConfiguration?.usesClaude1MContext(for: slot) ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("agents.modelSlots".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Button("cpaAliases.manage".localized(), action: onManageAliases)
                    .buttonStyle(.quotioMicroCapsule)
                Button {
                    Task { await viewModel.loadModels(forceRefresh: true) }
                } label: {
                    if viewModel.isFetchingModels {
                        SmallProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                }
                .buttonStyle(.quotioMicroCapsule)
                .opacity(viewModel.isFetchingModels ? 0.5 : 1)
                .help("agents.models.refresh".localized())
                .accessibilityLabel("agents.models.refresh".localized())
                .disabled(viewModel.isFetchingModels)
            }

            // 启动模型属于模型槽区域，但仍保存角色引用，与三个角色的映射独立。
            AgentDefaultModelPicker(
                agent: .claudeCode,
                selectedModel: Binding(
                    get: { viewModel.currentConfiguration?.claudeModel ?? ModelSlot.opus.rawValue },
                    set: { viewModel.updateDefaultModel($0); onOneMillionChange() }
                ),
                availableModels: viewModel.availableModels,
                isFetchingModels: viewModel.isFetchingModels,
                onRefresh: { Task { await viewModel.loadModels(forceRefresh: true) } },
                slotModels: viewModel.currentConfiguration?.modelSlots ?? [:],
                aliases: aliases
            )
            .padding(.bottom, 8)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("agents.modelMapping.role".localized()).frame(width: 65, alignment: .leading)
                    Text("agents.modelMapping.requestModel".localized()).frame(maxWidth: .infinity, alignment: .leading)
                    Text("agents.modelMapping.displayName".localized()).frame(width: 180, alignment: .leading)
                    Text("agents.modelMapping.oneMillion".localized()).frame(width: 56, alignment: .center)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(ModelSlot.allCases) { slot in
                    GridRow {
                        Text(verbatim: slot.rawValue.capitalized)
                            .font(.caption)
                            .fontWeight(.medium)
                            .frame(width: 65, alignment: .leading)

                        Picker("agents.modelMapping.requestModel".localized(), selection: Binding(
                            get: { requestModel(for: slot) },
                            set: { viewModel.updateModelSlot(slot, model: $0) }
                        )) {
                            ForEach(options(for: slot), id: \.self) { model in
                                Text(verbatim: model).tag(model)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .modifier(AgentConfigMenuStyle())
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .help(requestModel(for: slot))
                        .accessibilityLabel(slot.rawValue.capitalized + " " + "agents.modelMapping.requestModel".localized())

                        // 空白代表自动使用实际 ID，作为占位显示；输入自定义名称后才单独保存。
                        TextField("agents.modelMapping.displayName".localized(), text: Binding(
                            get: { viewModel.currentConfiguration?.claudeModelDisplayNames?[slot] ?? "" },
                            set: { viewModel.updateModelDisplayName(slot, name: $0) }
                        ), prompt: Text(verbatim: requestModel(for: slot)))
                        .modifier(AgentModelDisplayNameStyle())
                        .frame(width: 180)
                        .accessibilityLabel(slot.rawValue.capitalized + " " + "agents.modelMapping.displayName".localized())

                        Toggle("agents.modelMapping.oneMillion".localized(), isOn: Binding(
                            get: { uses1MContext(for: slot) },
                            set: {
                                viewModel.updateClaude1MContext($0, for: slot)
                                onOneMillionChange()
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .frame(width: 56)
                        .accessibilityLabel(slot.rawValue.capitalized + " " + "agents.modelMapping.oneMillion".localized())
                        .accessibilityHint("agents.modelMapping.oneMillion.info".localized())
                    }
                }
            }

            Text("agents.modelMapping.displayNameInfo".localized())
                .font(.caption)
                .foregroundStyle(.secondary)

            // 每个角色显示它所选 CPA 别名的实际策略；不伪造 Claude Code 原生逐槽强度字段。
            ForEach(ModelSlot.allCases) { slot in
                if !CPAModelAliasPolicy.entries(for: requestModel(for: slot), in: aliases).isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: slot.rawValue.capitalized).font(.caption.weight(.medium)).frame(width: 65, alignment: .leading)
                        CPAModelAliasSummary(model: requestModel(for: slot), aliases: aliases)
                    }
                }
            }
        }
        .quotioInsetCard()
    }
}

/// Keep focus updates local to the field without rebuilding the model menus.
private struct AgentModelDisplayNameStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused($isFocused)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .background(Capsule().fill(QuotioTheme.Colors.cardInset(for: colorScheme)))
            .overlay(
                Capsule().strokeBorder(
                    isFocused ? Color.accentColor.opacity(contrast == .increased ? 1 : 0.4) : QuotioTheme.Colors.sidebarBorder(for: colorScheme),
                    lineWidth: isFocused ? 1.5 : 0.5
                )
            )
    }
}
