import SwiftUI

/// 主策略区只接收界面所需的值，写入仍由父级统一控制。
/// 三项胶囊是配置选择器，不创建页面导航；测试也可以在不连接真实 CPA 的情况下渲染。
struct CPARoutingPolicySection: View {
    @Binding var strategy: String
    @Binding var sessionAffinity: Bool

    var body: some View {
        Section {
            QuotioCapsuleSegmentedControl(
                options: CPARoutingStrategy.allCases.map(\.rawValue), selection: $strategy, size: .medium
            ) { value, selected in
                QuotioSegmentItemView(title: CPARoutingStrategy.displayName(for: value), isSelected: selected)
            }
            .accessibilityIdentifier("settings.cpa.routingStrategy")
            Toggle("settings.cpa.sessionAffinity".localized(), isOn: $sessionAffinity)
        } header: {
            Label("settings.routingStrategy".localized(), systemImage: "arrow.triangle.branch")
        } footer: {
            Text(CPARoutingStrategy(rawValue: strategy)?.descriptionKey.localized() ?? strategy).font(.caption)
            Text("settings.cpa.sessionAffinityHelp".localized()).font(.caption)
        }
    }
}

/// 请求与日志的高级区复用相同的收起／应用交互，数据范围仍分别保存。
/// 子代理账号选项只在会话固定启用时展示；隐藏时保留草稿，不顺手删除已有配置。
struct CPAAdvancedSettingsOptions: View {
    let scope: CPAAdvancedSettingsDraft.Scope
    var sessionAffinity = false
    var requestLog = false
    @Binding var draft: CPAAdvancedSettingsDraft
    @Binding var isExpanded: Bool
    var hasChanges: Bool = true
    let onApply: () -> Void

    private var titleKey: String {
        scope == .requests ? "settings.cpa.advancedRequests" : "settings.cpa.advancedLogs"
    }

    var body: some View {
        DisclosureGroup(titleKey.localized(), isExpanded: $isExpanded) {
            switch scope {
            case .requests:
                if sessionAffinity {
                    LabeledContent("settings.cpa.sessionTTL".localized()) {
                        TextField("1h / 30m", text: $draft.sessionTTL)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 130)
                            .accessibilityLabel("settings.cpa.sessionTTL".localized())
                    }
                    Toggle("settings.cpa.sessionSubagents".localized(), isOn: $draft.sessionSubagents)
                    Text("settings.cpa.sessionSubagentsHelp".localized()).font(.caption).foregroundStyle(.secondary)
                }
                CPASettingsNumberRow(titleKey: "settings.cpa.maxRetryCredentials",
                    text: $draft.maxRetryCredentials, helpKey: "settings.cpa.maxRetryCredentialsHelp")
                CPASettingsNumberRow(titleKey: "settings.cpa.keepaliveSeconds",
                    text: $draft.keepaliveSeconds, helpKey: "settings.cpa.keepaliveSecondsHelp")
                CPASettingsNumberRow(titleKey: "settings.cpa.bootstrapRetries",
                    text: $draft.bootstrapRetries, helpKey: "settings.cpa.bootstrapRetriesHelp")
            case .logging:
                CPASettingsNumberRow(titleKey: "settings.cpa.logsMaxSize",
                    text: $draft.logsMaxSizeMB, helpKey: "settings.cpa.logsMaxSizeHelp")
                CPASettingsNumberRow(titleKey: "settings.cpa.errorLogsMaxFiles",
                    text: $draft.errorLogsMaxFiles, helpKey: "settings.cpa.errorLogsMaxFilesHelp")
                    .disabled(requestLog)
            }
            HStack {
                Spacer()
                Button("settings.navigation.apply".localized(), action: onApply)
                    .buttonStyle(.quotioPrimaryMicroCapsule(height: 26))
                    .disabled(!hasChanges)
                    .accessibilityIdentifier(scope == .requests ? "settings.cpa.applyRequests" : "settings.cpa.applyLogs")
            }
            .padding(.top, 4)
        }
        .accessibilityIdentifier(titleKey)
    }
}
