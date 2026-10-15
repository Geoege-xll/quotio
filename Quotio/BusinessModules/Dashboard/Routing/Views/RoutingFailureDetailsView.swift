import SwiftUI

/// 复用轻量文字明细，不新增卡片或 Tab；长解释可换行和复制，默认收起由父层负责。
/// 所有文案来自有限类型，不展示或持有上游原始错误正文。
struct RoutingFailureDetailsView: View {
    let explanation: CPAUsageFailureExplanation

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(explanation.summary)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
            Text(explanation.kind.reasonKey.localized())
            Text("routing.failure.advice".localized() + "：" + explanation.kind.adviceKey.localized())
            Text(explanation.evidenceKey.localized())
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}
