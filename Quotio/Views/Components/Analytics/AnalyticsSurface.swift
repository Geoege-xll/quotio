// Copyright 2026 AIUsage contributors. Licensed under Apache-2.0.
// 来源：sylearn/AIUsage，提交 bdb83bbe；修改：限定于 Quotio 统计页面，避免影响现有页面外观。
import SwiftUI
import AppKit

// MARK: - App Surface Tokens
// 全局界面色阶。浅色模式采用低亮度雾蓝灰，降低大面积纯白带来的眩光；
// 深色模式继续沿用系统材质，仅统一表面层级与描边语义。

enum AnalyticsSurface {
    /// 页面底：直接接入 QuotioTheme 全局画板
    static func page(_ scheme: ColorScheme) -> Color {
        QuotioTheme.Colors.canvasBackground(for: scheme)
    }

    /// 主侧栏与页面内二级导航，比页面底再沉一级。
    static func sidebar(_ scheme: ColorScheme) -> Color {
        QuotioTheme.Colors.cardInset(for: scheme)
    }

    /// 卡片/面板抬升面。
    static func card(_ scheme: ColorScheme) -> Color {
        QuotioTheme.Colors.cardBackground(for: scheme)
    }

    /// 浮层与输入区域；只在需要比卡片再高一级时使用。
    static func elevated(_ scheme: ColorScheme) -> Color {
        QuotioTheme.Colors.cardElevated(for: scheme)
    }

    /// 悬浮检查器、瞬时详情等必须完全遮住下层内容的浮动面。
    static func floatingPanel(_ scheme: ColorScheme) -> Color {
        QuotioTheme.Colors.cardElevated(for: scheme)
    }

    /// 芯片 / 胶囊 / 轻量行底。
    static func chip(_ scheme: ColorScheme) -> Color {
        QuotioTheme.Colors.cardTag(for: scheme)
    }

    /// 告警摘要行、次级列表行。
    static func row(_ scheme: ColorScheme) -> Color {
        QuotioTheme.Colors.cardInset(for: scheme)
    }

    /// 工具栏略高于页面底，但不回到刺眼纯白。
    static func toolbar(_ scheme: ColorScheme) -> Color {
        QuotioTheme.Colors.canvasBackground(for: scheme)
    }

    /// 选中菜单和聚焦区域的低饱和蓝底。
    static func selection(_ scheme: ColorScheme) -> Color {
        QuotioTheme.Colors.cardElevated(for: scheme)
    }
}

enum AnalyticsStroke {
    static func card(_ scheme: ColorScheme) -> Color {
        Color.clear
    }

    static func subtle(_ scheme: ColorScheme) -> Color {
        Color.clear
    }

    static func strong(_ scheme: ColorScheme) -> Color {
        Color.clear
    }

    static func floatingPanel(_ scheme: ColorScheme) -> Color {
        Color.clear
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

    /// 次要说明：浅色略深于系统 secondary。
    static func secondary(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.secondary
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.310, green: 0.373, blue: 0.467)
        }
    }

    /// 时间戳等三级信息。
    static func tertiary(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color.secondary.opacity(0.85)
        case .light:
            fallthrough
        @unknown default:
            return Color(red: 0.435, green: 0.498, blue: 0.588)
        }
    }

    /// 不透明浮动面上的固定内容色，避免系统层级色叠加后再次变灰、变透。
    static func floatingPrimary(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.957, green: 0.969, blue: 0.984)
            : Color(red: 0.090, green: 0.129, blue: 0.200)
    }

    static func floatingSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.761, green: 0.792, blue: 0.835)
            : Color(red: 0.310, green: 0.373, blue: 0.467)
    }

    static func floatingTertiary(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.616, green: 0.659, blue: 0.722)
            : Color(red: 0.380, green: 0.440, blue: 0.530)
    }
}

enum AnalyticsAccent {
    static func control(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.accentColor
            : Color(red: 0.216, green: 0.408, blue: 0.741)
    }
}

enum AnalyticsShadow {
    static func card(_ scheme: ColorScheme) -> Color {
        Color.black.opacity(scheme == .dark ? 0.35 : 0.05)
    }

    static func floatingPanel(_ scheme: ColorScheme) -> Color {
        Color.black.opacity(scheme == .dark ? 0.45 : 0.15)
    }
}

extension View {
    func analyticsPageBackground(_ scheme: ColorScheme) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                AnalyticsSurface.page(scheme)
                    .ignoresSafeArea()
            )
    }

    func analyticsPageChrome(_ scheme: ColorScheme) -> some View {
        foregroundStyle(AnalyticsContent.primary(scheme))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                AnalyticsSurface.page(scheme)
                    .ignoresSafeArea()
            )
    }
}
