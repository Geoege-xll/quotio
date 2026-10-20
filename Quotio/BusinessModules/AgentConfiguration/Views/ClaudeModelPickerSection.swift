import SwiftUI

/// 模型槽卡片底部的子代理设置，不单独绘制卡片背景。
/// 默认规则包括未声明及原生 inherit；指定目标只设置默认值，不承诺覆盖代理定义或单次调用。
struct ClaudeSubagentModelSection: View {
    @Bindable var viewModel: AgentSetupViewModel
    /// 由原配置弹窗传入不可变身份；独立组件调用保留默认参数兼容。
    var configurationSessionID: UUID? = nil
    var aliases: [CPAModelAlias] = []
    let onChange: () -> Void
    /// 只持有高级区域的展示状态，不复制子代理模型或 FORCE；打开旧配置也保持默认收起。
    @State private var isAdvancedExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Label("agents.claudeSubagent.title".localized(), systemImage: "person.2")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                // 子代理模式复用统一分段控件，与标题同行垂直居中对齐
                QuotioCapsuleSegmentedControl(
                    [false, true],
                    selection: Binding(get: { viewModel.currentConfiguration?.claudeSubagentSelector != nil },
                                       set: { viewModel.updateClaudeSubagentMode($0); onChange() }),
                    size: .small, tint: QuotioTheme.Colors.claudeOrange, isEqualWidth: false,
                    title: { ($0 ? "agents.claudeSubagent.specify" : "agents.claudeSubagent.inherit").localized() }
                )
                .accessibilityLabel("agents.claudeSubagent.title".localized())
            }
            if let config = viewModel.currentConfiguration, config.claudeSubagentSelector != nil {
                let resolved = viewModel.claudeCompatibilityPlan?.configuration ?? config
                AgentDefaultModelPicker(
                    agent: .claudeCode,
                    selectedModel: Binding(get: { viewModel.currentConfiguration?.claudeSubagentModel ?? "" },
                                           set: { viewModel.updateClaudeSubagentModel($0); onChange() }),
                    availableModels: viewModel.currentModelCandidates,
                    isFetchingModels: viewModel.isFetchingModels,
                    onRefresh: { Task { await viewModel.loadModels(forceRefresh: true, sessionID: configurationSessionID) } },
                    // 跟随角色的说明也使用其完整请求，不能把该槽独立的 1M 后缀丢掉。
                    slotModels: Dictionary(uniqueKeysWithValues: config.configuredClaudeSlots.map { ($0, config.claudeRequestModel(for: $0)) }),
                    aliases: aliases, showsHeader: false, isCompact: true,
                    selectionLabelKey: "agents.claudeSubagent.title"
                )
                Text(verbatim: resolved.claudeResolvedSelector(resolved.claudeSubagentSelector ?? ""))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)

            }

            // FORCE 是独立的 CLI 策略：未指定默认模型或 inherit 时同样可能开启。
            // 收起时仍明确提示已有覆盖，避免界面显示“默认规则”却把强制状态完全隐藏。
            if viewModel.currentConfiguration?.claudeSubagentSettings.isForced == true {
                Label("agents.claudeSubagent.force.title".localized(), systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("claudeSubagentForceSummary")
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isAdvancedExpanded.toggle() }
            } label: {
                HStack {
                    Text("agents.claude.advanced".localized()).font(.caption)
                    Spacer()
                    Image(systemName: isAdvancedExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("claudeSubagentAdvancedToggle")
            if isAdvancedExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("agents.claudeSubagent.force.title".localized(), isOn: Binding(
                        get: { viewModel.currentConfiguration?.claudeSubagentSettings.isForced ?? false },
                        set: { viewModel.updateClaudeSubagentForce($0); onChange() }
                    ))
                    .toggleStyle(.switch).controlSize(.small).font(.caption)
                    .accessibilityIdentifier("claudeSubagentForceToggle")

                    Text("agents.claudeSubagent.force.info".localized())
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
            Text("agents.claudeSubagent.info".localized())
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 面板预览和命令补全共用配置模型的名称与说明规则，不在视图中再拼接另一套模型 ID。
/// 原生条目、组织限制及当前会话模型由 CLI 决定，预览明确说明这些动态内容。
/// 支持一键折叠/展开，展开后限制最大高度滚动，避免长列表撑破弹窗。
struct ClaudeModelPanelPreview: View {
    let configuration: AgentConfiguration
    var availableModels: [AvailableModel] = []
    var configurationPlan: ClaudeConfigurationPlan? = nil
    @State private var isExpanded = false
    @State private var showsCompletion = false
    /// 面板只消费共享计划的解析结果，不修改原草稿；JSON 和 Shell 生成也使用同一规则。
    private var resolvedConfiguration: AgentConfiguration {
        plan.configuration
    }
    private var plan: ClaudeConfigurationPlan {
        configurationPlan ?? ClaudeConfigurationPlan(configuration: configuration, availableModels: availableModels)
    }

    private var previewItemCount: Int {
        let configuration = resolvedConfiguration
        if showsCompletion {
            return ModelSlot.allCases.count
        }
        var count = 1 // Default 默认模型
        if configuration.claudeModelPicker.mode == .native || configuration.claudeModelPicker.mode == .append {
            count += ModelSlot.allCases.count
        }
        if configuration.claudeModelPicker.mode == .curated || configuration.claudeModelPicker.mode == .append {
            count += configuration.claudeEffectivePickerOptions.count
        }
        return count
    }

    var body: some View {
        let configuration = resolvedConfiguration
        VStack(alignment: .leading, spacing: 10) {
            // 可折叠控制头部
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(QuotioTheme.Colors.claudeOrange)

                    Text("agents.claudePicker.preview".localized())
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)

                    Text("\(previewItemCount)")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("agents.claudePicker.preview".localized())

            if isExpanded {
                // 两种预览只是视图状态，统一分段控件直接绑定原状态，不触发配置保存或模型切换。
                QuotioCapsuleSegmentedControl(
                    [false, true], selection: $showsCompletion,
                    size: .small, tint: QuotioTheme.Colors.claudeOrange, isEqualWidth: false,
                    title: { ($0 ? "agents.claudePicker.preview.completion" : "agents.claudePicker.preview.panel").localized() }
                )
                .accessibilityLabel("agents.claudePicker.preview".localized())

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        if showsCompletion {
                            ForEach(ModelSlot.allCases) { slot in
                                previewRow("/model " + slot.rawValue, description: roleDescription(slot))
                            }
                        } else {
                            // Default 预览只显示有效目标；不复制 CLI 自己的 recommended/来源说明长句。
                            // 这是预览排版，不伪造一个能够修改 CLI 内置 Default 描述的配置字段。
                            previewRow("Default", description: ClaudeModelPresentation.platformModel(configuration.claudeDefaultRequestModel,
                                availableModels: availableModels, hints: configuration.claudeModelPlatformHints))
                            if configuration.claudeModelPicker.mode == .native || configuration.claudeModelPicker.mode == .append {
                                ForEach(ModelSlot.allCases) { slot in
                                    previewRow(plan.displayName(for: slot), description: roleDescription(slot))
                                }
                            }
                            if configuration.claudeModelPicker.mode == .curated || configuration.claudeModelPicker.mode == .append {
                                ForEach(configuration.claudeEffectivePickerOptions) { option in
                                    previewRow(configuration.claudePickerLabel(for: option),
                                               description: configuration.claudePickerDescription(for: option))
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text("agents.claudePicker.previewInfo".localized())
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func roleDescription(_ slot: ModelSlot) -> String {
        let configuration = resolvedConfiguration
        if slot == .fable && !configuration.configuredClaudeSlots.contains(slot) {
            return "agents.claude.fable.nativeDefault".localized()
        }
        return configuration.claudeModelDescription(for: slot, availableModels: availableModels)
    }

    /// 名称和说明使用两列，同 CLI 的“角色｜平台/模型”与“模型｜平台/账号”规则一致。
    /// 长模型或账号允许换行，保留文本选择与完整悬停信息，不截断保存的数据。
    private func previewRow(_ title: String, description: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(verbatim: title).font(.callout.monospaced().weight(.semibold))
                .frame(width: 174, alignment: .leading)
            Text(verbatim: description).font(.caption.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(description)
    }
}

/// 兼容性提示直接放在原配置流中，不增加卡片、名称输入框或菜单编辑器。
/// 无法证明的旧目标继续保留；提示只列出实际计划结果，不把目录缺失解释成上游退役。
struct ClaudeCompatibilityNotice: View {
    let plan: ClaudeConfigurationPlan
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if plan.isCatalogManaged {
                DisclosureGroup(isExpanded: $showsDetails) {
                    details
                        .padding(.top, 6)
                } label: {
                    Text(String(format: "agents.catalog.summary".localized(), plan.catalogCount,
                                plan.migrations.count, plan.removedModels.count))
                        .foregroundStyle(.secondary)
                }
                Text("agents.catalog.restart".localized()).foregroundStyle(.secondary)
            } else { details }
        }
        .font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !plan.removedModels.isEmpty {
                Label("agents.catalog.removed".localized() + " " + plan.removedModels.joined(separator: ", "),
                      systemImage: "archivebox").foregroundStyle(.secondary)
            }
            if !plan.migrations.isEmpty {
                Label(String(format: "agents.claudeCompatibility.migrated".localized(), plan.migrations.count),
                      systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
            if !plan.isCatalogManaged, !plan.unresolved.isEmpty {
                Label("agents.claudeCompatibility.unresolved".localized() + " " + plan.unresolved.joined(separator: ", "),
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if !plan.conflicts.isEmpty {
                Label("agents.claudeCompatibility.conflicts".localized() + " " + plan.conflicts.joined(separator: ", "),
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
}
