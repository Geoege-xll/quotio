import SwiftUI

/// 两个统计页面共用参考项目的面板样式，统一圆角和描边；内容只负责展示，不持有服务。
struct AnalyticsCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .quotioCard(cornerRadius: 14, padding: 16)
    }
}
