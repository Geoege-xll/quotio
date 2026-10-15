import SwiftUI

/// 兼容已有程序化“额度”入口。实际内容统一由账号融合页承载，避免维护两套账号列表。
/// 本文件只保留兼容入口与原有预览；额度卡片的状态仍由原来的 AccountQuotaContent 持有。
struct QuotaScreen: View {
    var body: some View { ProvidersScreen() }
}

// MARK: - Preview

#Preview {
    QuotaScreen()
        .environment(QuotaViewModel())
        .frame(width: 600, height: 500)
}
