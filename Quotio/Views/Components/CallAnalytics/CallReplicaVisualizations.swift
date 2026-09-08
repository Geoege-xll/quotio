// Copyright 2026 AIUsage contributors
// SPDX-License-Identifier: Apache-2.0
// 移植 AIUsage 的紧凑日趋势和主/子代理分布；颜色、条高与层级缩进沿用参考项目。
import SwiftUI

struct CallReplicaTrendBars: View {
    let points: [CallAnalyticsTrendPoint]
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredDay: String? = nil

    var body: some View {
        GeometryReader { geometry in
            let maxCount = max(points.map(\.count).max() ?? 1, 1)
            // 长历史保留逐日可访问条形；超出容器时横向滚动，避免参考实现最小条宽造成页面溢出。
            let width = max(geometry.size.width, CGFloat(points.count) * 4)
            let barWidth = max(2.5, (width - 2 * CGFloat(max(points.count - 1, 0))) / CGFloat(max(points.count, 1)))

            VStack(spacing: 4) {
                ScrollView(.horizontal) {
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(points) { point in
                            let ratio = CGFloat(point.count) / CGFloat(maxCount)
                            let isHovered = hoveredDay == point.day
                            let barHeight = max(2.5, (geometry.size.height - 6) * ratio)

                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.accentColor.opacity(isHovered ? 1.0 : (0.45 + 0.55 * ratio)),
                                            Color.accentColor.opacity(isHovered ? 0.85 : (0.2 + 0.45 * ratio))
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: barWidth, height: barHeight)
                                .help(point.day + ": " + point.count.formatted())
                                .onHover { hovering in
                                    withAnimation(.easeInOut(duration: 0.12)) {
                                        hoveredDay = hovering ? point.day : (hoveredDay == point.day ? nil : hoveredDay)
                                    }
                                }
                                .accessibilityLabel(point.day).accessibilityValue(point.count.formatted())
                        }
                    }
                    .frame(width: width, height: geometry.size.height - 6, alignment: .bottomLeading)
                }
                .scrollIndicators(.hidden)

                // 底部基准线
                Rectangle()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06))
                    .frame(height: 1)
            }
        }
    }
}

struct CallReplicaAgentBreakdown: View {
    let rows: [CallReplicaAgentRow]
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredRowID: String? = nil

    var body: some View {
        let total = max(rows.reduce(0) { $0 + $1.count }, 1)
        VStack(spacing: 6) {
            ForEach(rows) { row in
                let main = row.id == "main"
                let label = row.id == "main" ? "callReplica.agent.main".localized() : row.id == "subagent" ? "callReplica.agent.sub".localized() : row.id
                let style = Self.agentStyle(for: row.id)
                let isHovered = hoveredRowID == row.id

                HStack(spacing: 10) {
                    if !main {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 12)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: style.icon)
                            .font(.system(size: main ? 12 : 10, weight: .semibold))
                            .foregroundStyle(style.color)
                            .frame(width: main ? 22 : 18, height: main ? 22 : 18)
                            .background(style.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                        Text(label)
                            .font(main ? .callout.weight(.semibold) : .caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(width: 160, alignment: .leading)
                    .help(label)

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(QuotioTheme.Colors.cardInset(for: colorScheme))
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [style.color.opacity(main ? 0.95 : 0.75), style.color.opacity(main ? 0.8 : 0.6)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: min(geometry.size.width, max(4, geometry.size.width * CGFloat(row.count) / CGFloat(total))))
                        }
                    }
                    .frame(height: main ? 14 : 10)
                    .accessibilityHidden(true)

                    Text(row.count.formatted())
                        .font((main ? Font.callout.weight(.semibold) : Font.caption).monospacedDigit())
                        .foregroundStyle(main ? Color.primary : Color.secondary)
                        .frame(width: 48, alignment: .trailing)
                        .help("callReplica.agent.countHelp".localized())
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    isHovered ? QuotioTheme.Colors.cardInset(for: colorScheme).opacity(0.5) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .onHover { isHovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        hoveredRowID = isHovering ? row.id : (hoveredRowID == row.id ? nil : hoveredRowID)
                    }
                }
                .padding(.leading, main ? 0 : 12)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // 具体子代理的图标按名称分词，颜色按稳定 FNV-1a 分配，刷新时不会随机变色。
    static func agentStyle(for id: String) -> (icon: String, color: Color) {
        if id == "main" { return ("person.crop.circle.fill", .blue) }
        if id == "subagent" { return ("person.2.fill", .gray) }

        let tokens = Set(
            id.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
        func has(_ keywords: String...) -> Bool { keywords.contains(where: tokens.contains) }

        let icon: String
        if has("explore", "explorer") {
            icon = "magnifyingglass"
        } else if has("plan", "planner", "planning") {
            icon = "list.bullet.rectangle"
        } else if has("review", "reviewer") {
            icon = "checkmark.seal"
        } else if has("bug", "debug", "debugger") {
            icon = "ladybug"
        } else if has("test", "tester", "testing") {
            icon = "checkmark.diamond"
        } else if has("doc", "docs", "documentation") {
            icon = "doc.text"
        } else if has("ui", "sketch", "sketcher", "design", "designer") {
            icon = "paintbrush.pointed"
        } else if has("research", "researcher", "search") {
            icon = "magnifyingglass.circle"
        } else if has("story", "write", "writer", "writing") {
            icon = "square.and.pencil"
        } else if has("shell", "command", "terminal") {
            icon = "terminal"
        } else if has("general", "purpose") {
            icon = "sparkles"
        } else {
            icon = "person.2"
        }

        let palette: [Color] = [.orange, .purple, .green, .pink, .teal, .indigo, .mint, .cyan]
        var hash: UInt64 = 1469598103934665603 // FNV-1a 偏移基
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return (icon, palette[Int(hash % UInt64(palette.count))])
    }

}
