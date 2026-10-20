import SwiftUI

/// 默认模型与四个角色共用原表格，显示名称仅保留在配置数据中，不再作为输入列。
/// 表单状态由原配置 ViewModel 持有，刷新目录不会丢失自定义模型或存量名称。
struct ClaudeModelMappingView: View {
    @Bindable var viewModel: AgentSetupViewModel
    /// 由原配置弹窗传入不可变身份；独立组件调用保留默认参数兼容。
    var configurationSessionID: UUID? = nil
    var aliases: [CPAModelAlias] = []
    var onManageAliases: () -> Void = {}
    let onOneMillionChange: () -> Void

    /// 使用生成器同一纯计划显示自动上下文，不在 body 中回写原草稿。
    private var resolvedConfiguration: AgentConfiguration? {
        viewModel.claudeCompatibilityPlan?.configuration ?? viewModel.currentConfiguration
    }

    private func requestModel(for slot: ModelSlot) -> String {
        guard let configuration = resolvedConfiguration else { return "" }
        let model = configuration.modelSlots[slot]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 新增 Fable 未配置时显示选择提示，不替用户选一个代理可能不提供的固定模型。
        if slot == .fable, model.isEmpty { return "" }
        // 草稿拆开保存基础 ID 和各槽的 1M 声明；选择器必须重新组合后回显。
        // 否则同型号的 Sonnet／Haiku 会都显示裸 ID，隐藏其中一个已开启的 [1m]。
        return configuration.claudeRequestModel(for: slot)
    }

    private func uses1MContext(for slot: ModelSlot) -> Bool {
        resolvedConfiguration?.usesClaude1MContext(for: slot) ?? false
    }

    /// 仅给默认行的“跟随角色”选项提供最终请求说明；不复制可变配置或改变原槽的所有权。
    private var requestModels: [ModelSlot: String] {
        Dictionary(uniqueKeysWithValues: (resolvedConfiguration?.configuredClaudeSlots ?? []).map {
            ($0, requestModel(for: $0))
        })
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
                    get: { resolvedConfiguration?.claudeDefaultModelSelector ?? ModelSlot.opus.rawValue },
                    set: { viewModel.updateDefaultModel($0); onOneMillionChange() }
                ),
                availableModels: viewModel.currentModelCandidates,
                isFetchingModels: viewModel.isFetchingModels,
                onRefresh: { Task { await viewModel.loadModels(forceRefresh: true, sessionID: configurationSessionID) } },
                slotModels: requestModels,
                aliases: aliases,
                showsHeader: false,
                isCompact: true
            )
            .frame(minWidth: 0, maxWidth: .infinity)

            contextIndicator(resolvedConfiguration?.claudeDefaultUses1MContext ?? false)
                .frame(width: 44).frame(minHeight: 34)

        }
    }

    // MARK: - Model Slots Table
    private var modelSlotsTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            // 上下文只读显示自动识别结果，不再让用户逐槽维护开关。
            // 存量独立声明继续由原配置持有，不在视图出现／折叠时重写已有选择。
            GridRow {
                Text("agents.modelMapping.purpose".localized())
                    .frame(width: 58, alignment: .leading)

                Text("agents.modelMapping.requestModel".localized())
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("agents.claudeMenu.context".localized()).frame(width: 44)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)

            defaultModelRow

            // 四个角色槽位行
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

                    // 实际请求模型包含该槽完整后缀，预览、选择器和配置生成共用同一推导。
                    // 与默认模型共用搜索、别名分组和手动输入，但禁止角色自引用。
                    AgentDefaultModelPicker(
                        agent: .claudeCode,
                        selectedModel: Binding(get: { requestModel(for: slot) },
                                               set: { viewModel.updateModelSlot(slot, model: $0); onOneMillionChange() }),
                        availableModels: viewModel.currentModelCandidates,
                        isFetchingModels: viewModel.isFetchingModels,
                        onRefresh: { Task { await viewModel.loadModels(forceRefresh: true, sessionID: configurationSessionID) } },
                        aliases: aliases, showsHeader: false, isCompact: true,
                        allowsRoleSelection: false, selectionLabelKey: "agents.modelMapping.requestModel"
                    )
                    .frame(minWidth: 0, maxWidth: .infinity)

                    contextIndicator(uses1MContext(for: slot))
                        .frame(width: 44, height: 34)

                }
            }
        }
    }

    /// 只读标识消费与配置生成相同的上下文结果；“自动”表示交给 CLI，不暗示模型只有 200K。
    private func contextIndicator(_ uses1M: Bool) -> some View {
        Text(uses1M ? "1M" : "agents.claudeMenu.contextAutomatic".localized())
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(uses1M ? QuotioTheme.Colors.claudeOrange : .secondary)
            .help("agents.claudeMenu.contextInfo".localized())
            .accessibilityIdentifier("claudeContextReadOnly")
    }

    // MARK: - Alias Summaries
    @ViewBuilder
    private var aliasSummariesSection: some View {
        let activeSlots = ModelSlot.allCases.filter {
            // 1M 是 CLI 上下文声明，不属于 CPA 别名本身；摘要继续按原始别名身份查询。
            !CPAModelAliasPolicy.entries(for: AgentConfiguration.normalizedClaudeModelID(requestModel(for: $0)).base, in: aliases).isEmpty
        }
        if !activeSlots.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(activeSlots) { slot in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: slot.rawValue.capitalized)
                            .font(.caption.weight(.medium))
                            .frame(width: 58, alignment: .leading)
                        CPAModelAliasSummary(model: AgentConfiguration.normalizedClaudeModelID(requestModel(for: slot)).base, aliases: aliases)
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}
