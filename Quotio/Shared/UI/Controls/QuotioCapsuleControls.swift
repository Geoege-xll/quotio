//
//  QuotioCapsuleControls.swift
//  Quotio
//
//  Reusable capsule-silhouette form controls per the macOS 26 design spec:
//  `QuotioCapsuleTextField` / `QuotioCapsuleSecureField` (des-input-001/002/003)
//  and `QuotioCircularIconButton` (26pt row action targets, des-card-004).
//

import SwiftUI

// MARK: - Capsule Text Field

/// Capsule-silhouette single-line text field.
/// Inset-well background (`cardInset`), 0.5pt hairline border, breathing focus ring,
/// optional leading icon and trailing clear button.
struct QuotioCapsuleTextField: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding private var text: String
    @FocusState private var isFocused: Bool

    private let placeholder: String
    private let systemImage: String?
    private let showsClearButton: Bool
    private var monospaced: Bool = false
    /// 默认不抢占焦点；短任务弹窗可显式要求显示后聚焦真实输入框。
    private let autofocus: Bool

    init(
        _ placeholder: String,
        text: Binding<String>,
        systemImage: String? = nil,
        showsClearButton: Bool = true,
        monospaced: Bool = false,
        autofocus: Bool = false
    ) {
        self.placeholder = placeholder
        self._text = text
        self.systemImage = systemImage
        self.showsClearButton = showsClearButton
        self.monospaced = monospaced
        self.autofocus = autofocus
    }

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            TextField(placeholder, text: $text)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .focused($isFocused)
                .textFieldStyle(.plain)
                .onSubmit { }
                .onAppear { if autofocus { isFocused = true } }

            if showsClearButton && !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("action.clear".localized())
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(
            Capsule().fill(QuotioTheme.Colors.cardInset(for: colorScheme))
        )
        .overlay(
            Capsule().strokeBorder(
                isFocused
                    ? Color.accentColor.opacity(0.4)
                    : QuotioTheme.Colors.sidebarBorder(for: colorScheme),
                lineWidth: isFocused ? 1.5 : 0.5
            )
        )
        .overlay(
            // Breathing focus glow — soft ambient halo that doesn't displace layout.
            Capsule()
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.18 : 0), lineWidth: 3)
                .blur(radius: 2)
        )
        .animation(.easeInOut(duration: 0.18), value: isFocused)
        .animation(.easeInOut(duration: 0.15), value: text.isEmpty)
    }
}

// MARK: - Capsule Secure Field

/// Capsule-silhouette secure (password) field sharing the text field's visual language.
struct QuotioCapsuleSecureField: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding private var text: String
    @FocusState private var isFocused: Bool

    private let placeholder: String
    private let systemImage: String?
    /// 与明文输入框共用可选自动聚焦行为，切换显示状态后仍可继续键盘输入。
    private let autofocus: Bool

    init(
        _ placeholder: String,
        text: Binding<String>,
        systemImage: String? = nil,
        autofocus: Bool = false
    ) {
        self.placeholder = placeholder
        self._text = text
        self.systemImage = systemImage
        self.autofocus = autofocus
    }

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            SecureField(placeholder, text: $text)
                .font(.system(.body, design: .monospaced))
                .focused($isFocused)
                .textFieldStyle(.plain)
                .onAppear { if autofocus { isFocused = true } }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("action.clear".localized())
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(
            Capsule().fill(QuotioTheme.Colors.cardInset(for: colorScheme))
        )
        .overlay(
            Capsule().strokeBorder(
                isFocused
                    ? Color.accentColor.opacity(0.4)
                    : QuotioTheme.Colors.sidebarBorder(for: colorScheme),
                lineWidth: isFocused ? 1.5 : 0.5
            )
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.18 : 0), lineWidth: 3)
                .blur(radius: 2)
        )
        .animation(.easeInOut(duration: 0.18), value: isFocused)
        .animation(.easeInOut(duration: 0.15), value: text.isEmpty)
    }
}

// MARK: - Circular Icon Button

/// 26pt circular inline action target (close, delete, add) with hover wash
/// and tactile press physics per the design spec's row-action rule.
struct QuotioCircularIconButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    let systemImage: String
    var tint: Color = .secondary
    var backgroundTint: Color? = nil
    var tooltip: String? = nil
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(fillColor)

                if let backgroundTint {
                    Circle()
                        .strokeBorder(backgroundTint.opacity(0.35), lineWidth: 0.5)
                } else {
                    Circle()
                        .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme).opacity(isHovered ? 0.8 : 0.4), lineWidth: 0.5)
                }

                if isLoading {
                    SmallProgressView()
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(TactileCircularButtonStyle())
        .disabled(isLoading)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .modifier(OptionalTooltipModifier(tooltip: tooltip))
    }

    private var fillColor: Color {
        if let backgroundTint {
            return isHovered ? backgroundTint.opacity(0.18) : backgroundTint.opacity(0.10)
        }
        return isHovered ? QuotioTheme.Colors.cardElevated(for: colorScheme) : QuotioTheme.Colors.cardInset(for: colorScheme)
    }
}

/// Press compression physics for circular icon buttons.
struct TactileCircularButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .focusEffectDisabled(true)
    }
}

/// 26pt circular inline menu target with hover wash and hidden indicator
/// per the design spec's row-action rule.
struct QuotioCircularMenu<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    let systemImage: String
    var tint: Color = .secondary
    var backgroundTint: Color? = nil
    var tooltip: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            ZStack {
                Circle()
                    .fill(fillColor)

                if let backgroundTint {
                    Circle()
                        .strokeBorder(backgroundTint.opacity(0.35), lineWidth: 0.5)
                } else {
                    Circle()
                        .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme).opacity(isHovered ? 0.8 : 0.4), lineWidth: 0.5)
                }

                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .modifier(OptionalTooltipModifier(tooltip: tooltip))
    }

    private var fillColor: Color {
        if let backgroundTint {
            return isHovered ? backgroundTint.opacity(0.18) : backgroundTint.opacity(0.10)
        }
        return isHovered ? QuotioTheme.Colors.cardElevated(for: colorScheme) : QuotioTheme.Colors.cardInset(for: colorScheme)
    }
}

// MARK: - Native Tooltip Support

class TooltipWindow: NSWindow {
    static let shared = TooltipWindow()
    private weak var activeView: NSView?

    private let label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        return label
    }()

    private init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.ignoresMouseEvents = true

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .toolTip
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 4

        label.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor, constant: -4)
        ])

        self.contentView = visualEffect
    }

    func show(text: String, near view: NSView) {
        guard !text.isEmpty else {
            hide(from: view)
            return
        }
        activeView = view
        label.stringValue = text
        label.sizeToFit()

        let labelSize = label.fittingSize
        let windowSize = NSSize(width: labelSize.width + 16, height: labelSize.height + 8)

        guard let screen = view.window?.screen ?? NSScreen.main else { return }
        let viewFrameInScreen = view.window?.convertToScreen(view.convert(view.bounds, to: nil)) ?? .zero
        var origin = NSPoint(
            x: viewFrameInScreen.midX - windowSize.width / 2,
            y: viewFrameInScreen.minY - windowSize.height - 4
        )

        // Keep tooltip on screen
        if origin.x < screen.visibleFrame.minX {
            origin.x = screen.visibleFrame.minX
        }
        if origin.x + windowSize.width > screen.visibleFrame.maxX {
            origin.x = screen.visibleFrame.maxX - windowSize.width
        }
        if origin.y < screen.visibleFrame.minY {
            origin.y = viewFrameInScreen.maxY + 4
        }

        setFrame(NSRect(origin: origin, size: windowSize), display: true)
        orderFront(nil)
    }

    func hide(from view: NSView? = nil) {
        if let view = view, activeView !== view {
            return
        }
        activeView = nil
        orderOut(nil)
    }
}

class TooltipTrackingView: NSView {
    var text: String = ""

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        TooltipWindow.shared.show(text: text, near: self)
    }

    override func mouseExited(with event: NSEvent) {
        TooltipWindow.shared.hide(from: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

struct NativeTooltipView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> TooltipTrackingView {
        let view = TooltipTrackingView()
        view.text = text
        return view
    }

    func updateNSView(_ nsView: TooltipTrackingView, context: Context) {
        nsView.text = text
    }
}

struct OptionalTooltipModifier: ViewModifier {
    let tooltip: String?

    func body(content: Content) -> some View {
        if let tooltip, !tooltip.isEmpty {
            content
                .nativeTooltip(tooltip)
                .help(tooltip)
        } else {
            content
        }
    }
}

extension View {
    func nativeTooltip(_ text: String) -> some View {
        self.overlay(NativeTooltipView(text: text))
    }
}


// MARK: - Capsule Action Buttons

/// Primary capsule button: solid accent gradient pill, 0.5pt inner top highlight,
/// white semibold label, spring press compression (des-button-002/004).
struct QuotioPrimaryCapsuleButtonStyle: ButtonStyle {
    var height: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: height)
            .background(
                ZStack {
                    Capsule().fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.92), Color.accentColor],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    // Subtle inner top highlight
                    Capsule()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.15), location: 0),
                                    .init(color: .white.opacity(0), location: 0.45)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            )
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Secondary capsule button: quiet inset-well pill with secondary text (des-button-002).
struct QuotioSecondaryCapsuleButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    var height: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 18)
            .frame(height: height)
            .background(
                Capsule().fill(QuotioTheme.Colors.cardInset(for: colorScheme))
            )
            .overlay(
                Capsule().strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == QuotioPrimaryCapsuleButtonStyle {
    static var quotioPrimaryCapsule: QuotioPrimaryCapsuleButtonStyle { QuotioPrimaryCapsuleButtonStyle() }
}

extension ButtonStyle where Self == QuotioSecondaryCapsuleButtonStyle {
    static var quotioSecondaryCapsule: QuotioSecondaryCapsuleButtonStyle { QuotioSecondaryCapsuleButtonStyle() }
}

/// Micro capsule button (24pt height) for inline actions (add key, select all, fetch)
/// per `des-button-003` (Small - 24pt, font 11pt medium, horizontal padding 10pt).
struct QuotioMicroCapsuleButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    var height: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(
                Capsule().fill(QuotioTheme.Colors.cardTag(for: colorScheme))
            )
            .overlay(
                Capsule().strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
            )
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == QuotioMicroCapsuleButtonStyle {
    static var quotioMicroCapsule: QuotioMicroCapsuleButtonStyle { QuotioMicroCapsuleButtonStyle() }
    static func quotioMicroCapsule(height: CGFloat) -> QuotioMicroCapsuleButtonStyle {
        QuotioMicroCapsuleButtonStyle(height: height)
    }
}

/// Primary micro capsule button (24pt height) for compact primary actions
struct QuotioPrimaryMicroCapsuleButtonStyle: ButtonStyle {
    var height: CGFloat = 24
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: height)
            .background(
                Capsule().fill(tint)
            )
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == QuotioPrimaryMicroCapsuleButtonStyle {
    static var quotioPrimaryMicroCapsule: QuotioPrimaryMicroCapsuleButtonStyle { QuotioPrimaryMicroCapsuleButtonStyle() }
    static func quotioPrimaryMicroCapsule(height: CGFloat = 24, tint: Color = .accentColor) -> QuotioPrimaryMicroCapsuleButtonStyle {
        QuotioPrimaryMicroCapsuleButtonStyle(height: height, tint: tint)
    }
}

// MARK: - Inline Apply Field

/// 行内输入与提交/应用控件，符合 [des-commit-001] 设计规范。
/// 将 LabeledContent、输入框、行内胶囊“应用”按钮、基线变更感知、回车提交、
/// 异步保存进度反馈及行内实时校验警告整合为统一的标准交互。
struct QuotioInlineApplyField: View {
    let titleKey: String
    let placeholderKey: String
    @Binding var text: String
    let savedText: String
    var isValid: Bool = true
    var validationErrorMessage: String? = nil
    var isSaving: Bool = false
    var buttonTitleKey: String = "settings.navigation.apply"
    var minWidth: CGFloat = 200
    var idealWidth: CGFloat = 280
    var maxWidth: CGFloat = 360
    var accessibilityPrefix: String = "settings.inlineApply"
    let onApply: () async -> Void

    private var hasChanges: Bool {
        text != savedText
    }

    private var canApply: Bool {
        !isSaving && isValid && hasChanges
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(titleKey.localized()) {
                HStack(spacing: 8) {
                    TextField("", text: $text, prompt: Text(placeholderKey.localized()))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth)
                        .accessibilityLabel(titleKey.localized())
                        .onSubmit {
                            guard canApply else { return }
                            Task { await onApply() }
                        }
                        .accessibilityIdentifier("\(accessibilityPrefix).input")

                    Button {
                        Task { await onApply() }
                    } label: {
                        HStack(spacing: 4) {
                            if isSaving {
                                ProgressView().controlSize(.small).scaleEffect(0.7)
                            }
                            Text(buttonTitleKey.localized())
                        }
                    }
                    .buttonStyle(.quotioPrimaryMicroCapsule(height: 24))
                    .disabled(!canApply)
                    .accessibilityIdentifier("\(accessibilityPrefix).apply")
                }
            }

            if let validationErrorMessage, !validationErrorMessage.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(validationErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Preview

#Preview("Capsule Controls") {
    VStack(spacing: 20) {
        QuotioCapsuleTextField("e.g., OpenRouter, Ollama Local", text: .constant(""), systemImage: "puzzlepiece.extension")

        QuotioCapsuleTextField("https://api.example.com", text: .constant("https://api"), systemImage: "network", monospaced: true)

        QuotioCapsuleSecureField("API Key", text: .constant(""), systemImage: "key")

        HStack {
            QuotioCircularIconButton(systemImage: "xmark", action: {})
            QuotioCircularIconButton(systemImage: "trash", tint: .red, backgroundTint: .red, action: {})
            QuotioCircularIconButton(systemImage: "plus", tint: .blue, backgroundTint: .blue, action: {})
        }

        HStack {
            Button("action.cancel".localized()) {}
                .buttonStyle(.quotioSecondaryCapsule)
            Button("customProviders.addProvider".localized()) {}
                .buttonStyle(.quotioPrimaryCapsule)
        }
    }
    .padding(24)
    .frame(width: 420)
}
