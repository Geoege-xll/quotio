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

                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(TactileCircularButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
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
