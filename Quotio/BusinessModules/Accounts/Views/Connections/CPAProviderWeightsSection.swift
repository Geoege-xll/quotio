import SwiftUI

/// 通用提供商与 GLM 编辑共用同一组权重输入，默认收起，不增加 Tab 或永久说明卡片。
/// UUID 绑定与服务商的密钥身份一致，API Key 原文只留在既有密钥控件里，不进入权重标签。
struct CPAProviderWeightsSection: View {
    let keys: [CustomAPIKeyEntry]
    var observed: [UUID: Int] = [:]
    @Binding var drafts: [UUID: String]
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("settings.cpa.accountWeight".localized(), isExpanded: $isExpanded) {
            ForEach(keys) { key in
                let ordinal = (keys.firstIndex(where: { $0.id == key.id }) ?? 0) + 1
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key #\(ordinal)").font(.caption).foregroundStyle(.secondary)
                    CPASettingsNumberRow(titleKey: "settings.cpa.accountWeight", text: Binding(
                        get: { drafts[key.id] ?? observed[key.id].map(String.init) ?? key.weight.map(String.init) ?? "" },
                        set: { drafts[key.id] = $0 }
                    ))
                }
            }
            Text("settings.cpa.providerWeightHelp".localized()).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("providers.routingWeights")
    }
}
