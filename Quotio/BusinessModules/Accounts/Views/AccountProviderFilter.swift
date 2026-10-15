import SwiftUI

/// 服务商数据筛选，复用设计系统胶囊分段控件。状态仅改变列表范围，页面仍是一个整体。
/// nil 代表全部；账号数量和最低剩余额度取自同一份目录／快照，不读取任何凭据。
struct AccountProviderFilter: View {
    let providers: [AIProvider]
    let accountCounts: [AIProvider: Int]
    let lowestPercentages: [AIProvider: Double]
    @Binding var selection: AIProvider?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            QuotioCapsuleSegmentedControl(
                options: [nil] + providers.map { Optional($0) },
                selection: $selection,
                size: .medium,
                optionTint: { $0?.color },
                isEqualWidth: false
            ) { provider, _ in
                HStack(spacing: 6) {
                    if let provider { ProviderIcon(provider: provider, size: 14) }
                    Text(provider?.displayName ?? "accounts.filter.all".localized())
                        .lineLimit(1)
                    Text("\(provider.map { accountCounts[$0] ?? 0 } ?? accountCounts.values.reduce(0, +))")
                        .font(.caption2.bold().monospacedDigit())
                    if let provider, let percent = lowestPercentages[provider] {
                        Text("\(Int(percent))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(percent <= 10 ? Color.red : percent <= 25 ? Color.orange : Color.green)
                    }
                }
            }
            .padding(2)
        }
        .scrollClipDisabled()
        .accessibilityLabel("accounts.filter.provider".localized())
    }
}
