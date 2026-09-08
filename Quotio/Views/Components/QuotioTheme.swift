//
//  QuotioTheme.swift
//  Quotio
//
//  Centralized design tokens and surface styling matching the Apple 26 visual prototype.
//

import SwiftUI

public enum QuotioTheme {
    public enum Colors {
        // MARK: - Canvas & Card Surfaces

        /// 全局页面主背景色（Dark: #101420 深邃黑蓝, Light: #f8fafc 雪板浅灰白）
        public static func canvasBackground(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 16/255.0, green: 20/255.0, blue: 32/255.0)   // #101420
                : Color(red: 248/255.0, green: 250/255.0, blue: 252/255.0) // #f8fafc
        }

        /// 侧边栏独立包裹面板背景色（带 macOS 原生透明度，配合 NSVisualEffectView 呈现毛玻璃通透质感）
        public static func sidebarBackground(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 18/255.0, green: 22/255.0, blue: 36/255.0).opacity(0.35)   // #121624
                : Color(red: 241/255.0, green: 245/255.0, blue: 249/255.0).opacity(0.40) // #f1f5f9
        }

        /// 侧边栏独立包裹面板边框描边
        public static func sidebarBorder(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color.white.opacity(0.08)
                : Color.black.opacity(0.08)
        }

        /// 卡片容器主背景色（Dark: #1c212f 优雅午夜黑蓝悬浮卡片, Light: #ffffff 纯白卡片）
        public static func cardBackground(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 28/255.0, green: 33/255.0, blue: 47/255.0)  // #1c212f
                : Color.white                                              // #ffffff
        }

        /// 卡片内部嵌入槽位/深色沉槽背景色（如地址栏、4-KPI 指标小卡底色、详情抽屉）
        public static func cardInset(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 14/255.0, green: 17/255.0, blue: 27/255.0)  // #0e111b
                : Color(red: 241/255.0, green: 245/255.0, blue: 249/255.0) // #f1f5f9
        }

        /// 模型代码胶囊 / 标签背景色（Dark: #242a38 稍亮的精致微透胶囊, Light: #f1f5f9）
        public static func cardTag(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 36/255.0, green: 42/255.0, blue: 56/255.0)  // #242a38
                : Color(red: 241/255.0, green: 245/255.0, blue: 249/255.0) // #f1f5f9
        }

        /// 悬停/高亮背景色
        public static func cardElevated(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 38/255.0, green: 45/255.0, blue: 62/255.0)  // #262d3e
                : Color.white
        }

        // MARK: - Semantic Status Colors
        public static let success = Color(red: 52/255.0, green: 211/255.0, blue: 153/255.0) // #34d399
        public static let warning = Color(red: 251/255.0, green: 191/255.0, blue: 36/255.0) // #fbbf24
        public static let danger  = Color(red: 248/255.0, green: 113/255.0, blue: 113/255.0) // #f87171
        public static let info    = Color(red: 96/255.0, green: 165/255.0, blue: 250/255.0)  // #60a5fa

        // MARK: - AI Brand & Accent Colors
        /// Claude 官方陶土暖橙色 (Anthropic Terracotta Orange #D97757)
        public static let claudeOrange = Color(red: 217/255.0, green: 119/255.0, blue: 87/255.0)
        /// 用量统计中 Claude 的专属金黄色；浅色模式使用深琥珀色保证小字号可读性。
        /// 这是统计页的来源标识，不改变其他页面沿用的官方陶土暖橙品牌色。
        public static func claudeUsage(for scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 251/255.0, green: 191/255.0, blue: 36/255.0)
                : Color(red: 146/255.0, green: 84/255.0, blue: 8/255.0)
        }

        /// Codex / OpenAI 标志性翠绿翡翠色 (#10A37F)
        public static let codexGreen   = Color(red: 16/255.0, green: 163/255.0, blue: 127/255.0)
        /// OpenCode 终端晴空蓝 (#3B82F6)
        public static let opencodeBlue = Color(red: 59/255.0, green: 130/255.0, blue: 246/255.0)
    }

    // MARK: - Metrics & Radius
    public enum Radius {
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 10
        public static let lg: CGFloat = 14
        public static let xl: CGFloat = 16
        public static let squircle: CGFloat = 7
    }
}

// MARK: - Card & Canvas View Modifiers

public struct QuotioPageContainerModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                QuotioTheme.Colors.canvasBackground(for: colorScheme)
                    .ignoresSafeArea()
            )
    }
}

public struct QuotioCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    public var cornerRadius: CGFloat = QuotioTheme.Radius.lg
    public var padding: CGFloat = 16
    public var isInteractive: Bool = false
    public var isHovered: Bool = false

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                isInteractive && isHovered
                    ? QuotioTheme.Colors.cardElevated(for: colorScheme)
                    : QuotioTheme.Colors.cardBackground(for: colorScheme),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                if isInteractive && isHovered {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.blue.opacity(0.3), lineWidth: 1)
                }
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? (isHovered ? 0.45 : 0.35) : (isHovered ? 0.08 : 0.04)),
                radius: colorScheme == .dark ? (isHovered ? 16 : 14) : (isHovered ? 10 : 6),
                x: 0,
                y: colorScheme == .dark ? (isHovered ? 6 : 4) : (isHovered ? 3 : 1.5)
            )
            .scaleEffect(isInteractive && isHovered ? 1.01 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

public struct QuotioInsetCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    public var cornerRadius: CGFloat = QuotioTheme.Radius.md
    public var padding: CGFloat = 14

    public init(cornerRadius: CGFloat = QuotioTheme.Radius.md, padding: CGFloat = 14) {
        self.cornerRadius = cornerRadius
        self.padding = padding
    }

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                QuotioTheme.Colors.cardInset(for: colorScheme),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

public extension View {
    /// 统一应用自研风格画板背景，穿透安全区浸润顶部导航栏/工具栏，解决老背景色残留与断层
    func quotioPage() -> some View {
        modifier(QuotioPageContainerModifier())
    }

    /// 统一应用 Apple 26 纯材质卡片（暗夜/明亮自适应原色卡片）
    func quotioCard(cornerRadius: CGFloat = QuotioTheme.Radius.lg, padding: CGFloat = 16) -> some View {
        modifier(QuotioCardModifier(cornerRadius: cornerRadius, padding: padding))
    }

    /// 统一应用带交互悬停（Hover）反馈的材质卡片
    func quotioActionCard(cornerRadius: CGFloat = QuotioTheme.Radius.lg, padding: CGFloat = 16, isHovered: Bool) -> some View {
        modifier(QuotioCardModifier(cornerRadius: cornerRadius, padding: padding, isInteractive: true, isHovered: isHovered))
    }

    /// 统一应用深色沉槽/嵌入型卡片样式（适用于模态弹窗小节、设置组内嵌面板等）
    func quotioInsetCard(cornerRadius: CGFloat = QuotioTheme.Radius.md, padding: CGFloat = 14) -> some View {
        modifier(QuotioInsetCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}
