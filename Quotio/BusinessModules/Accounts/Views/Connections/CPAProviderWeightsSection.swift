import SwiftUI

/// 通用提供商、GLM 与主流 API Key 添加/编辑弹窗共用的权重设置卡片。
/// 默认展开直观展示，严格遵循“外方内圆”设计语言，采用胶囊输入控件。
/// UUID 绑定与服务商的密钥身份一致，API Key 原文只留在既有密钥控件里，不进入权重标签。
struct CPAProviderWeightsSection: View {
    let keys: [CustomAPIKeyEntry]
    var observed: [UUID: Int] = [:]
    @Binding var drafts: [UUID: String]
    var isCard: Bool = true

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            Label("settings.cpa.accountWeight".localized(), systemImage: "scalemass")
                .font(isCard ? .headline : .subheadline.weight(.semibold))

            Text("settings.cpa.providerWeightHelp".localized())
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(keys) { key in
                    let ordinal = (keys.firstIndex(where: { $0.id == key.id }) ?? 0) + 1
                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            Image(systemName: "key")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(keys.count > 1 ? "API Key #\(ordinal)" : "settings.cpa.accountWeight".localized())
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        QuotioCapsuleTextField(
                            "1",
                            text: Binding(
                                get: { drafts[key.id] ?? observed[key.id].map(String.init) ?? key.weight.map(String.init) ?? "" },
                                set: { drafts[key.id] = $0 }
                            ),
                            systemImage: "slider.horizontal.3",
                            showsClearButton: false,
                            monospaced: true
                        )
                        .frame(width: 110)
                        .accessibilityIdentifier("settings.cpa.accountWeight")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .accessibilityIdentifier("providers.routingWeights")

        if isCard {
            content.quotioInsetCard()
        } else {
            content
        }
    }
}
