import SwiftUI

/// 默认用途与三个角色合并为同一张表；显示名称和 1M 均不会改变代理别名的映射策略。
/// 表单状态由原配置 ViewModel 持有，刷新目录不会丢失自定义模型或尚未保存的名称。
struct ClaudeModelMappingView: View {
    @Bindable var viewModel: AgentSetupViewModel
    var aliases: [CPAModelAlias] = []
    var onManageAliases: () -> Void = {}
    let onOneMillionChange: () -> Void

    @Environment(\.colorScheme) private var colorScheme

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

    private func roleColor(for slot: ModelSlot) -> Color {
        switch slot {
        case .opus:
            return QuotioTheme.Colors.claudeOrange
        case .sonnet:
            return QuotioTheme.Colors.codexGreen
        case .haiku:
            return Color.blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar

            // 四行共用相同列宽和控件尺寸，默认选择的继承状态在所在行直接可见。
            modelSlotsTable

            Text("agents.modelMapping.displayNameInfo".localized())
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let configuration = viewModel.currentConfiguration {
                // 终端风格的 /model 模型槽补全预览
                ClaudeModelDisplayPreview(configuration: configuration)
            }

            // 网关模型发现开关
            gatewayDiscoveryToggle

            // CPA 别名策略摘要指示
            aliasSummariesSection
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
                Task { await viewModel.loadModels(forceRefresh: true) }
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
                onRefresh: { Task { await viewModel.loadModels(forceRefresh: true) } },
                slotModels: viewModel.currentConfiguration?.modelSlots ?? [:],
                aliases: aliases,
                showsHeader: false,
                isCompact: true
            )
            .frame(minWidth: 0, maxWidth: .infinity)

            // Default 是客户端原生项，不存在与三个角色等价的可编辑 NAME 字段。
            // 这里只读展示来源名称，实际请求 ID 同时出现在预览和悬停说明中。
            Text(verbatim: viewModel.currentConfiguration?.claudeDefaultDisplayName ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .frame(width: 125, height: 34, alignment: .leading)
                .help("agents.modelMapping.defaultNameInfo".localized())

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

                Text("agents.modelMapping.displayName".localized())
                    .frame(width: 125, alignment: .leading)

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
                    Menu {
                        ForEach(options(for: slot), id: \.self) { model in
                            Button {
                                viewModel.updateModelSlot(slot, model: model)
                            } label: {
                                HStack {
                                    Text(verbatim: model)
                                    if requestModel(for: slot) == model {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(verbatim: requestModel(for: slot))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 4)

                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
                        .overlay(
                            Capsule().strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(requestModel(for: slot))
                    .accessibilityLabel(slot.rawValue.capitalized + " " + "agents.modelMapping.requestModel".localized())

                    // 显示名称输入框
                    TextField(
                        "agents.modelMapping.displayName".localized(),
                        text: Binding(
                            get: { viewModel.currentConfiguration?.claudeModelDisplayNames?[slot] ?? "" },
                            set: { viewModel.updateModelDisplayName(slot, name: $0) }
                        ),
                        prompt: Text(verbatim: requestModel(for: slot))
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .frame(width: 125, height: 34)
                    .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
                    )
                    .accessibilityLabel(slot.rawValue.capitalized + " " + "agents.modelMapping.displayName".localized())

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
                    .accessibilityLabel(slot.rawValue.capitalized + " " + "agents.modelMapping.oneMillion".localized())
                    .accessibilityHint("agents.modelMapping.oneMillion.info".localized())
                }
            }
        }
    }

    // MARK: - Gateway Discovery Toggle
    private var gatewayDiscoveryToggle: some View {
        Toggle(isOn: Binding(
            get: { viewModel.currentConfiguration?.claudeGatewayModelDiscovery ?? false },
            set: {
                viewModel.updateClaudeGatewayModelDiscovery($0)
                onOneMillionChange()
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("agents.modelMapping.gatewayModels".localized())
                    .font(.caption.weight(.medium))
                Text("agents.modelMapping.gatewayModelsInfo".localized())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityHint("agents.modelMapping.gatewayModelsInfo".localized())
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

/// 终端风格的 /model 命令补全预览面板。
private struct ClaudeModelDisplayPreview: View {
    let configuration: AgentConfiguration
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("agents.modelMapping.preview".localized())
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                // 启动预览展示实际目标；默认 JSON 保留角色标识以维持可回填的继承关系。
                HStack(spacing: 8) {
                    Text("agents.modelMapping.startup".localized())
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(QuotioTheme.Colors.claudeOrange)
                        .frame(width: 90, alignment: .leading)
                    Text(verbatim: configuration.claudeDefaultRequestModel)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(configuration.claudeDefaultRequestModel)
                }
                ForEach(ModelSlot.allCases) { slot in
                    HStack(spacing: 8) {
                        Text("/model " + slot.rawValue)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(QuotioTheme.Colors.claudeOrange)
                            .frame(width: 90, alignment: .leading)

                        Text(verbatim: configuration.claudeModelDescription(for: slot))
                            .font(.caption)
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
                    .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
            )

            Text("agents.modelMapping.previewInfo".localized())
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}
