import SwiftUI

/// 模型槽卡片底部的子代理设置，不单独绘制卡片背景。
/// 会话继承通过移除变量实现；指定目标可以是角色或完整模型 ID，保持与 CLI 原生语义一致。
struct ClaudeSubagentModelSection: View {
    @Bindable var viewModel: AgentSetupViewModel
    var aliases: [CPAModelAlias] = []
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("agents.claudeSubagent.title".localized(), systemImage: "person.2")
                .font(.subheadline.weight(.semibold))
            // 子代理模式复用统一分段控件，保留继承与指定模型的既有切换语义。
            QuotioCapsuleSegmentedControl(
                [false, true],
                selection: Binding(get: { viewModel.currentConfiguration?.claudeSubagentSelector != nil },
                                   set: { viewModel.updateClaudeSubagentModel($0 ? ModelSlot.haiku.rawValue : nil); onChange() }),
                size: .small, tint: QuotioTheme.Colors.claudeOrange, isEqualWidth: false,
                title: { ($0 ? "agents.claudeSubagent.specify" : "agents.claudeSubagent.inherit").localized() }
            )
            .accessibilityLabel("agents.claudeSubagent.title".localized())
            if let config = viewModel.currentConfiguration, config.claudeSubagentSelector != nil {
                AgentDefaultModelPicker(
                    agent: .claudeCode,
                    selectedModel: Binding(get: { viewModel.currentConfiguration?.claudeSubagentModel ?? "" },
                                           set: { viewModel.updateClaudeSubagentModel($0); onChange() }),
                    availableModels: viewModel.availableModels,
                    isFetchingModels: viewModel.isFetchingModels,
                    onRefresh: { Task { await viewModel.loadModels(forceRefresh: true) } },
                    slotModels: config.modelSlots, aliases: aliases, showsHeader: false, isCompact: true,
                    selectionLabelKey: "agents.claudeSubagent.title"
                )
                Text(verbatim: config.claudeResolvedSelector(config.claudeSubagentSelector ?? ""))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("agents.claudeSubagent.info".localized())
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 面板预览和命令补全共用配置模型的名称与说明规则，不在视图中再拼接另一套模型 ID。
/// 原生条目、组织限制及当前会话模型由 CLI 决定，预览明确说明这些动态内容。
struct ClaudeModelPanelPreview: View {
    let configuration: AgentConfiguration
    var availableModels: [AvailableModel] = []
    @State private var showsCompletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 两种预览只是视图状态，统一分段控件直接绑定原状态，不触发配置保存或模型切换。
            QuotioCapsuleSegmentedControl(
                [false, true], selection: $showsCompletion,
                size: .small, tint: QuotioTheme.Colors.claudeOrange, isEqualWidth: false,
                title: { ($0 ? "agents.claudePicker.preview.completion" : "agents.claudePicker.preview.panel").localized() }
            )
            .accessibilityLabel("agents.claudePicker.preview".localized())
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
                            previewRow(configuration.claudeDisplayName(for: slot), description: roleDescription(slot))
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
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            Text("agents.claudePicker.previewInfo".localized())
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func roleDescription(_ slot: ModelSlot) -> String {
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
