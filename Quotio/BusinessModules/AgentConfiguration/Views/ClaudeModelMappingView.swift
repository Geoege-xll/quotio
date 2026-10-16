import SwiftUI

/// 默认模型与三个角色继续使用原表格，显示名称仅保留在配置数据中，不再作为输入列。
/// 表单状态由原配置 ViewModel 持有，刷新目录不会丢失自定义模型或存量名称。
struct ClaudeModelMappingView: View {
    @Bindable var viewModel: AgentSetupViewModel
    /// 由原配置弹窗传入不可变身份；独立组件调用保留默认参数兼容。
    var configurationSessionID: UUID? = nil
    var aliases: [CPAModelAlias] = []
    var onManageAliases: () -> Void = {}
    let onOneMillionChange: () -> Void

    private func requestModel(for slot: ModelSlot) -> String {
        let model = viewModel.currentConfiguration?.modelSlots[slot]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 新增 Fable 未配置时显示选择提示，不替用户选一个代理可能不提供的固定模型。
        if slot == .fable { return model }
        return model.isEmpty ? (AvailableModel.defaultModels[slot]?.name ?? "") : model
    }

    private func uses1MContext(for slot: ModelSlot) -> Bool {
        viewModel.currentConfiguration?.usesClaude1MContext(for: slot) ?? false
    }

    private func roleColor(for slot: ModelSlot) -> Color {
        switch slot {
        case .opus:
            return QuotioTheme.Colors.claudeOrange
        case .fable:
            return .purple
        case .sonnet:
            return QuotioTheme.Colors.codexGreen
        case .haiku:
            return Color.blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar

            // 默认模型与四个角色共用原三列，新增 Fable 不增加名称输入或另一套菜单编辑入口。
            modelSlotsTable

            // CPA 别名策略摘要指示
            aliasSummariesSection

            // 子代理属于模型选择：放在同一张卡片底部，仅用分隔线分组，不再嵌套另一张卡片。
            // 复用原状态与回调，移动位置不会重置已有固定模型或“跟随会话”的选择。
            Divider()
            ClaudeSubagentModelSection(viewModel: viewModel, configurationSessionID: configurationSessionID, aliases: aliases, onChange: onOneMillionChange)
        }
        .quotioInsetCard()
    }

    // MARK: - Header Bar
    private var headerBar: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(QuotioTheme.Colors.claudeOrange.opacity(0.15))
                    .frame(width: 24, height: 24)
                Image(systemName: "square.grid.3x3.topleft.filled")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(QuotioTheme.Colors.claudeOrange)
            }

            Text("agents.modelSlots".localized())
                .font(.subheadline.weight(.semibold))

            Spacer()

            Button("cpaAliases.manage".localized(), action: onManageAliases)
                .buttonStyle(.quotioMicroCapsule)

            Button {
                Task { await viewModel.loadModels(forceRefresh: true, sessionID: configurationSessionID) }
            } label: {
                if viewModel.isFetchingModels {
                    SmallProgressView()
                } else {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
            }
            .buttonStyle(.quotioMicroCapsule)
            .disabled(viewModel.isFetchingModels)
            .help("agents.models.refresh".localized())
            .accessibilityLabel("agents.models.refresh".localized())
        }
    }

    /// 默认行复用已有可搜索选择器；继承关系必须由角色选项明确建立，不能通过相同 ID 猜测。
    private var defaultModelRow: some View {
        GridRow {
            Label("agents.modelMapping.defaultRole".localized(), systemImage: "play.circle")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 58, height: 34, alignment: .leading)

            AgentDefaultModelPicker(
                agent: .claudeCode,
                selectedModel: Binding(
                    get: { viewModel.currentConfiguration?.claudeModel ?? ModelSlot.opus.rawValue },
                    set: { viewModel.updateDefaultModel($0); onOneMillionChange() }
                ),
                availableModels: viewModel.availableModels,
                isFetchingModels: viewModel.isFetchingModels,
                onRefresh: { Task { await viewModel.loadModels(forceRefresh: true, sessionID: configurationSessionID) } },
                slotModels: viewModel.currentConfiguration?.modelSlots ?? [:],
                aliases: aliases,
                showsHeader: false,
                isCompact: true
            )
            .frame(minWidth: 0, maxWidth: .infinity)

            VStack(spacing: 0) {
                Toggle("agents.modelMapping.oneMillion".localized(), isOn: Binding(
                    get: { viewModel.currentConfiguration?.claudeDefaultUses1MContext ?? false },
                    set: { viewModel.updateClaudeDefault1MContext($0); onOneMillionChange() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(viewModel.currentConfiguration?.claudeDefaultModelSlot != nil)
                .accessibilityLabel("agents.defaultModel".localized() + " 1M")
                if viewModel.currentConfiguration?.claudeDefaultModelSlot != nil {
                    Text("agents.modelMapping.inherited".localized())
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 44)
            .frame(minHeight: 34)
            .help("agents.modelMapping.defaultOneMillionInfo".localized())
        }
    }

    // MARK: - Model Slots Table
    private var modelSlotsTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            // 表头行
            GridRow {
                Text("agents.modelMapping.purpose".localized())
                    .frame(width: 58, alignment: .leading)

                Text("agents.modelMapping.requestModel".localized())
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("agents.modelMapping.oneMillion".localized())
                    .frame(width: 44, alignment: .center)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)

            defaultModelRow

            // 三个槽位行
            ForEach(ModelSlot.allCases) { slot in
                GridRow {
                    // 角色指示
                    HStack(spacing: 5) {
                        Circle()
                            .fill(roleColor(for: slot))
                            .frame(width: 6, height: 6)
                        Text(verbatim: slot.rawValue.capitalized)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    .frame(width: 58, height: 34, alignment: .leading)

                    // 实际请求模型下拉选择胶囊
                    // 与默认模型共用搜索、别名分组和手动输入，但禁止角色自引用。
                    AgentDefaultModelPicker(
                        agent: .claudeCode,
                        selectedModel: Binding(get: { requestModel(for: slot) },
                                               set: { viewModel.updateModelSlot(slot, model: $0); onOneMillionChange() }),
                        availableModels: viewModel.availableModels,
                        isFetchingModels: viewModel.isFetchingModels,
                        onRefresh: { Task { await viewModel.loadModels(forceRefresh: true, sessionID: configurationSessionID) } },
                        aliases: aliases, showsHeader: false, isCompact: true,
                        allowsRoleSelection: false, selectionLabelKey: "agents.modelMapping.requestModel"
                    )

                    // 名称输入列已删除，但不清空 claudeModelDisplayNames；保存时继续沿用原 _NAME。
                    // 实际模型选择器获得更多宽度，搜索、CPA 别名和手动输入仍使用原实现。
                    // 1M 上下文切换开关
                    Toggle("agents.modelMapping.oneMillion".localized(), isOn: Binding(
                        get: { uses1MContext(for: slot) },
                        set: {
                            viewModel.updateClaude1MContext($0, for: slot)
                            onOneMillionChange()
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .frame(width: 44, height: 34, alignment: .center)
                    .disabled(slot == .fable && requestModel(for: slot).isEmpty)
                    .accessibilityLabel(slot.rawValue.capitalized + " " + "agents.modelMapping.oneMillion".localized())
                    .accessibilityHint("agents.modelMapping.oneMillion.info".localized())
                }
            }
        }
    }

    // MARK: - Alias Summaries
    @ViewBuilder
    private var aliasSummariesSection: some View {
        let activeSlots = ModelSlot.allCases.filter {
            !CPAModelAliasPolicy.entries(for: requestModel(for: $0), in: aliases).isEmpty
        }
        if !activeSlots.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(activeSlots) { slot in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: slot.rawValue.capitalized)
                            .font(.caption.weight(.medium))
                            .frame(width: 58, alignment: .leading)
                        CPAModelAliasSummary(model: requestModel(for: slot), aliases: aliases)
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}
