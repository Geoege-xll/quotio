// Copyright 2026 AIUsage contributors. Licensed under Apache-2.0.
// 来源：sylearn/AIUsage，提交 bdb83bbe；修改：限定于 Quotio 统计页面，避免影响现有页面外观。
import SwiftUI

// MARK: - App Surface Tokens
// 全局界面色阶。浅色模式采用低亮度雾蓝灰，降低大面积纯白带来的眩光；
// 深色模式继续沿用系统材质，仅统一表面层级与描边语义。

enum AnalyticsSurface {
    /// 页面底：直接接入 QuotioTheme 全局画板
    static func page(_ scheme: ColorScheme) -> Color {
        QuotioTheme.Colors.canvasBackground(for: scheme)
    }

    /// 悬浮检查器、瞬时详情等必须完全遮住下层内容的浮动面。
    static func floatingPanel(_ scheme: ColorScheme) -> Color {
        QuotioTheme.Colors.cardElevated(for: scheme)
    }

    /// 告警摘要行、次级列表行。
    static func row(_ scheme: ColorScheme) -> Color {
        QuotioTheme.Colors.cardInset(for: scheme)
    }

}

enum AnalyticsContent {
    /// 主标题/正文：浅色加深，避免发灰。
    static func primary(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.primary
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.090, green: 0.129, blue: 0.200)
        }
    }

}

enum AnalyticsShadow {

    static func floatingPanel(_ scheme: ColorScheme) -> Color {
        Color.black.opacity(scheme == .dark ? 0.45 : 0.15)
    }
}

extension View {

    func analyticsPageChrome(_ scheme: ColorScheme) -> some View {
        foregroundStyle(AnalyticsContent.primary(scheme))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                AnalyticsSurface.page(scheme)
                    .ignoresSafeArea()
            )
    }
}
