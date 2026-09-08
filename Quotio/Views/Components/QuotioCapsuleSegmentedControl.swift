//
//  QuotioCapsuleSegmentedControl.swift
//  Quotio
//
//  Centralized capsule-styled segmented control conforming to macOS 26 & Apple fluid UI design system.
//

import SwiftUI

// MARK: - Segment Size

/// 胶囊分段选择器尺寸规格
/// 仅提供不可变的尺寸常量，不访问视图状态，因此不需要主线程隔离。
/// 显式取消项目默认的 MainActor 隔离，保证 Release 模块接口中的自动合成
/// Equatable/Hashable 实现也能在任意隔离域安全使用。
public nonisolated enum QuotioSegmentSize: Sendable {
    case small   // 高度 26pt, 字体 11pt, 紧凑小弹窗/列表行内/次级过滤
    case medium  // 高度 30pt, 字体 12pt, 默认通用标准尺寸
    case large   // 高度 34pt, 字体 13pt, 页面顶部主导航/主 Tab 切换

    public var height: CGFloat {
        switch self {
        case .small: return 26
        case .medium: return 30
        case .large: return 34
        }
    }

    public var fontSize: CGFloat {
        switch self {
        case .small: return 11
        case .medium: return 12
        case .large: return 13
        }
    }

    public var horizontalPadding: CGFloat {
        switch self {
        case .small: return 10
        case .medium: return 14
        case .large: return 16
        }
    }

    public var iconSize: CGFloat {
        switch self {
        case .small: return 11
        case .medium: return 12
        case .large: return 13.5
        }
    }
}

// MARK: - Standard Segment Item View

/// 标准胶囊选项展示内容（支持图标、文案与计数徽章）
public struct QuotioSegmentItemView: View {
    public let title: String
    public var icon: String? = nil
    public var badge: String? = nil
    public var isSelected: Bool = false
    public var size: QuotioSegmentSize = .medium

    public init(
        title: String,
        icon: String? = nil,
        badge: String? = nil,
        isSelected: Bool = false,
        size: QuotioSegmentSize = .medium
    ) {
        self.title = title
        self.icon = icon
        self.badge = badge
        self.isSelected = isSelected
        self.size = size
    }

    public var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: size.iconSize, weight: isSelected ? .semibold : .medium))
            }

            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            if let badge, !badge.isEmpty {
                Text(badge)
                    .font(.system(size: size.fontSize - 2, weight: .bold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        isSelected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06),
                        in: Capsule()
                    )
            }
        }
    }
}

// MARK: - Main Segmented Control

/// 通用胶囊分段选择器 (Capsule Segmented Control)
/// 遵循 macOS 26 外方内圆（Squircle 容器 + Capsule 交互件）设计规范，支持平滑滑块微动效、按选项专属主题色与明暗自适应。
public struct QuotioCapsuleSegmentedControl<Option: Hashable, Label: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let options: [Option]
    @Binding public var selection: Option
    public var size: QuotioSegmentSize = .medium
    public var tint: Color? = nil
    public var optionTint: ((Option) -> Color?)? = nil
    public var isEqualWidth: Bool = true
    public var segmentWidth: CGFloat? = nil
    @ViewBuilder public let label: (Option, Bool) -> Label

    @Namespace private var segmentNamespace
    @State private var hoveredOption: Option? = nil

    public init(
        options: [Option],
        selection: Binding<Option>,
        size: QuotioSegmentSize = .medium,
        tint: Color? = nil,
        optionTint: ((Option) -> Color?)? = nil,
        isEqualWidth: Bool = true,
        segmentWidth: CGFloat? = nil,
        @ViewBuilder label: @escaping (Option, Bool) -> Label
    ) {
        self.options = options
        self._selection = selection
        self.size = size
        self.tint = tint
        self.optionTint = optionTint
        self.isEqualWidth = isEqualWidth
        self.segmentWidth = segmentWidth
        self.label = label
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                segmentItem(for: option)
            }
        }
        .padding(3)
        .background(
            QuotioTheme.Colors.cardInset(for: colorScheme),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06),
                    lineWidth: 0.5
                )
        )
        .opacity(isEnabled ? 1.0 : 0.38)
        // 容器级弹簧动画：确保外部 Binding 与内部点击均能触发完全一致的物理平滑滑动
        .animation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.74), value: selection)
    }

    @ViewBuilder
    private func segmentItem(for option: Option) -> some View {
        let isSelected = selection == option
        let isHovered = hoveredOption == option && !isSelected
        let itemTint = resolveTint(for: option)

        Button {
            select(option)
        } label: {
            label(option, isSelected)
                .font(.system(size: size.fontSize, weight: isSelected ? .semibold : .medium))
                .monospacedDigit()
                .foregroundStyle(foregroundColor(for: option, isSelected: isSelected))
                .animation(.easeInOut(duration: 0.18), value: isSelected)
                .padding(.horizontal, size.horizontalPadding)
                .frame(height: size.height)
                .frame(maxWidth: isEqualWidth && segmentWidth == nil ? .infinity : nil)
                .frame(width: segmentWidth)
                .contentShape(Capsule())
        }
        .buttonStyle(SegmentButtonStyle())
        .background {
            if isSelected {
                activeThumb(for: option, tintColor: itemTint)
            } else if isHovered {
                Capsule()
                    .fill(QuotioTheme.Colors.cardElevated(for: colorScheme).opacity(colorScheme == .dark ? 0.5 : 0.6))
                    .transition(.opacity)
            }
        }
        .onHover { hovering in
            guard isEnabled else { return }
            withAnimation(.easeInOut(duration: 0.12)) {
                if hovering {
                    hoveredOption = option
                } else if hoveredOption == option {
                    hoveredOption = nil
                }
            }
        }
        .accessibilityLabel(String(describing: option))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Active Sliding Thumb

    @ViewBuilder
    private func activeThumb(for option: Option, tintColor: Color?) -> some View {
        ZStack {
            // 1. 基础悬浮卡片材质底座
            Capsule()
                .fill(QuotioTheme.Colors.cardBackground(for: colorScheme))

            // 2. 专属品牌色微透光晕（深色模式透亮，浅色模式柔润，烘托出高级品牌质感）
            if let tintColor {
                Capsule()
                    .fill(tintColor.opacity(colorScheme == .dark ? 0.16 : 0.10))
            }

            // 3. 精致微光描边（顶部微亮高光，底部融入容器）
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            (tintColor ?? Color.white).opacity(colorScheme == .dark ? 0.42 : 0.32),
                            (tintColor ?? Color.white).opacity(colorScheme == .dark ? 0.14 : 0.08)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
        }
        .shadow(
            color: (tintColor ?? Color.black).opacity(colorScheme == .dark ? 0.35 : 0.12),
            radius: colorScheme == .dark ? 6 : 3.5,
            x: 0,
            y: 1.5
        )
        .matchedGeometryEffect(id: "ACTIVE_CAPSULE_THUMB", in: segmentNamespace)
    }

    // MARK: - Helpers

    private func select(_ option: Option) {
        guard isEnabled, selection != option else { return }
        if reduceMotion {
            selection = option
        } else {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.74)) {
                selection = option
            }
        }
    }

    private func resolveTint(for option: Option) -> Color? {
        if let optionTint = optionTint?(option) {
            return optionTint
        }
        return tint
    }

    private func foregroundColor(for option: Option, isSelected: Bool) -> Color {
        if isSelected {
            if let itemTint = resolveTint(for: option) {
                return itemTint
            }
            return colorScheme == .dark ? .white : .primary
        }
        return Color.secondary
    }
}

// MARK: - Tactile Press Button Style

struct SegmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Convenience Initializers

extension QuotioCapsuleSegmentedControl where Label == QuotioSegmentItemView {
    /// 快捷文本 / 图标 / 徽章构造器（支持全局固定色或每项专属主题色）
    public init(
        _ options: [Option],
        selection: Binding<Option>,
        size: QuotioSegmentSize = .medium,
        tint: Color? = nil,
        optionTint: ((Option) -> Color?)? = nil,
        isEqualWidth: Bool = true,
        segmentWidth: CGFloat? = nil,
        icon: ((Option) -> String?)? = nil,
        badge: ((Option) -> String?)? = nil,
        title: @escaping (Option) -> String
    ) {
        self.init(
            options: options,
            selection: selection,
            size: size,
            tint: tint,
            optionTint: optionTint,
            isEqualWidth: isEqualWidth,
            segmentWidth: segmentWidth
        ) { option, isSelected in
            QuotioSegmentItemView(
                title: title(option),
                icon: icon?(option),
                badge: badge?(option),
                isSelected: isSelected,
                size: size
            )
        }
    }
}

extension QuotioCapsuleSegmentedControl where Label == Text {
    /// 最简纯文本构造器（支持全局固定色或每项专属主题色）
    public init(
        _ options: [Option],
        selection: Binding<Option>,
        size: QuotioSegmentSize = .medium,
        tint: Color? = nil,
        optionTint: ((Option) -> Color?)? = nil,
        isEqualWidth: Bool = true,
        segmentWidth: CGFloat? = nil,
        title: @escaping (Option) -> String
    ) {
        self.init(
            options: options,
            selection: selection,
            size: size,
            tint: tint,
            optionTint: optionTint,
            isEqualWidth: isEqualWidth,
            segmentWidth: segmentWidth
        ) { option, _ in
            Text(title(option))
        }
    }
}
