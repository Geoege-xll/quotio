// Copyright 2026 AIUsage contributors
// SPDX-License-Identifier: Apache-2.0
// 移植 CallAnalyticsView+Rankings：Top12 条形排行、来源图例、真实样本指标与 MCP server 下钻。
import SwiftUI

struct CallReplicaRankings: View {
    let rows: [CallReplicaRankRow]
    let derived: CallReplicaDerived
    let lens: CallReplicaLens
    let allSources: Bool
    @Binding var expandedServers: Set<String>
    @Environment(\.colorScheme) private var colorScheme
    @State private var availableWidth: CGFloat = 0
    @State private var hoveredRowID: String? = nil
    private var maxCount: Int { max(rows.map(\.count).max() ?? 1, 1) }
    private var showMetrics: Bool { rows.contains { $0.successRate != nil || $0.duration != nil } }
    private var barColor: Color { lens == .mcp ? .purple : lens == .skill ? .pink : .teal }

    var body: some View {
        if rows.isEmpty {
            Text("callAnalytics.empty.title".localized()).font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
        } else {
            // 宽窗口维持原参考列对齐；窄窗口整张排行横向滚动，名称、指标、来源和次数都可访问。
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 12) {
                    legend
                    VStack(spacing: 4) {
                        ForEach(rows) { row in
                            rankingRow(row, child: false)
                            if lens == .mcp, row.drillable, expandedServers.contains(row.id) {
                                VStack(spacing: 3) {
                                    ForEach(derived.tools(server: row.id)) { rankingRow($0, child: true) }
                                }.padding(.leading, 28).padding(.vertical, 2)
                            }
                        }
                    }.padding(.top, 2)
                }.frame(minWidth: max(availableWidth, showMetrics ? 600 : 500))
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { availableWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in availableWidth = width }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Capsule().fill(barColor).frame(width: 16, height: 7)
                Text("callAnalytics.calls".localized())
            }
            if showMetrics {
                HStack(spacing: 5) {
                    Text("%").foregroundStyle(.green).fontWeight(.semibold)
                    Text("callAnalytics.successRate".localized())
                }
            }
            if allSources {
                HStack(spacing: 9) {
                    ForEach(CallSourceKind.allCases, id: \.self) { source in
                        HStack(spacing: 4) {
                            Circle().fill(Self.sourceColor(source)).frame(width: 7, height: 7)
                            Text(source.displayName)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }.font(.caption2).foregroundStyle(.secondary).padding(.top, 2).padding(.bottom, 4)
    }

    private func rankingRow(_ row: CallReplicaRankRow, child: Bool) -> some View {
        let isHovered = hoveredRowID == row.id

        return HStack(spacing: 10) {
            if lens == .mcp && !child {
                Button {
                    if expandedServers.contains(row.id) { expandedServers.remove(row.id) } else { expandedServers.insert(row.id) }
                } label: {
                    Image(systemName: expandedServers.contains(row.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 16, height: 20)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel((expandedServers.contains(row.id) ? "callReplica.collapse" : "callReplica.expand").localized() + " " + row.name)
                    .accessibilityValue((expandedServers.contains(row.id) ? "callReplica.expanded" : "callReplica.collapsed").localized())
            }
            Text(row.name).font(child ? .caption : .callout).foregroundStyle(child ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle).frame(width: child ? 188 : 200, alignment: .leading)
                .help(row.name).textSelection(.enabled)
            GeometryReader { geometry in
                // 子项与母级共用全局 maxCount，条长始终能直接比较，避免子工具条比父server更长。
                ZStack(alignment: .leading) {
                    Capsule().fill(QuotioTheme.Colors.cardInset(for: colorScheme))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    child ? barColor.opacity(0.65) : barColor,
                                    child ? barColor.opacity(0.45) : barColor.opacity(0.8)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: min(geometry.size.width, max(4, geometry.size.width * CGFloat(row.count) / CGFloat(maxCount))))
                }
            }.frame(height: child ? 10 : 14).accessibilityHidden(true)
            if showMetrics { metrics(row) }
            if allSources {
                HStack(spacing: 3) {
                    ForEach(row.sources.sorted { $0.rawValue < $1.rawValue }, id: \.self) { source in
                        Circle().fill(Self.sourceColor(source)).frame(width: 7, height: 7)
                            .help(source.displayName).accessibilityLabel(source.displayName)
                    }
                }.frame(width: 40, alignment: .trailing)
            }
            Text(row.count.formatted()).font((child ? Font.caption : Font.callout).monospacedDigit())
                .foregroundStyle(child ? Color.secondary : Color.primary).frame(width: 48, alignment: .trailing)
                .accessibilityLabel("callAnalytics.calls".localized())
                .accessibilityValue(row.count.formatted())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            isHovered ? QuotioTheme.Colors.cardInset(for: colorScheme).opacity(0.6) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredRowID = hovering ? row.id : (hoveredRowID == row.id ? nil : hoveredRowID)
            }
        }
    }

    private func metrics(_ row: CallReplicaRankRow) -> some View {
        HStack(spacing: 4) {
            if let rate = row.successRate {
                let statusColor = rate >= 0.999 ? Color.green : rate >= 0.9 ? Color.secondary : Color.orange
                Text(rate.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(statusColor.opacity(0.12), in: Capsule())
                    .help("callAnalytics.successRate".localized())
            }
            if row.successRate != nil && row.duration != nil { Text("·").foregroundStyle(.tertiary) }
            if let duration = row.duration {
                Text(Measurement(value: duration / 1000, unit: UnitDuration.seconds).formatted(.measurement(width: .narrow, usage: .asProvided)))
                    .foregroundStyle(.secondary).help("callAnalytics.averageDuration".localized())
            }
        }.font(.caption2.monospacedDigit()).frame(width: 96, alignment: .trailing)
    }

    static func sourceColor(_ source: CallSourceKind) -> Color {
        switch source {
        case .claude: return QuotioTheme.Colors.claudeOrange
        case .codex: return QuotioTheme.Colors.codexGreen
        case .opencode: return QuotioTheme.Colors.opencodeBlue
        case .pi: return CLIAgent.pi.color
        }
    }
}
