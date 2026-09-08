// Copyright 2026 AIUsage contributors. Licensed under Apache-2.0.
// 来源：sylearn/AIUsage，提交 bdb83bbe；修改：限定于 Quotio 统计页面，避免影响现有页面外观。
import SwiftUI

/// 等宽分段控件沿用参考界面的尺寸与色阶；补充键盘按钮语义、选中状态和减少动态效果支持。
struct AnalyticsSegmentedControl<Option: Hashable>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let options: [Option]
    @Binding var selection: Option
    let segmentWidth: CGFloat
    let tint: Color
    let title: (Option) -> String

    init(
        _ options: [Option],
        selection: Binding<Option>,
        segmentWidth: CGFloat,
        tint: Color,
        title: @escaping (Option) -> String
    ) {
        self.options = options
        self._selection = selection
        self.segmentWidth = segmentWidth
        self.tint = tint
        self.title = title
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(QuotioTheme.Colors.cardInset(for: colorScheme))
        )
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = selection == option
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                selection = option
            }
        } label: {
            Text(title(option))
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .allowsTightening(true)
                .foregroundStyle(isSelected ? tint : Color.primary.opacity(0.70))
                .frame(width: segmentWidth, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? selectedFill : Color.clear)
                        .shadow(
                            color: isSelected ? Color.black.opacity(colorScheme == .dark ? 0.25 : 0.08) : .clear,
                            radius: isSelected ? 3 : 0,
                            y: isSelected ? 1 : 0
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title(option))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var selectedFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.88)
    }
}
