// Copyright 2026 AIUsage contributors
// SPDX-License-Identifier: Apache-2.0
// 移植零调用检测芯片：已调用绿色实线、未调用橙色虚线，按内容自动换行，不提供破坏性清理动作。
import SwiftUI

struct CallReplicaInventory: View {
    let title: String
    let rows: [CallReplicaInventoryRow]
    let emptyHint: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if !rows.isEmpty {
                    Text(String(format: "callReplica.inventorySummary".localized(), rows.filter(\.used).count, rows.count, rows.filter { !$0.used }.count))
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            if rows.isEmpty {
                Text(emptyHint).font(.caption).foregroundStyle(.tertiary)
            } else {
                CallReplicaFlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(rows) { row in
                        let statusColor = row.used ? Color.green : Color.orange
                        HStack(spacing: 6) {
                            Image(systemName: row.used ? "checkmark.circle.fill" : "moon.zzz.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(statusColor)
                            Text(row.name).font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                            if row.used {
                                Text(row.count.formatted())
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .help(row.name)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(statusColor.opacity(0.12), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(statusColor.opacity(0.24), lineWidth: 0.5)
                        )
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(row.name + " · " + (row.used ? "callReplica.used" : "callReplica.unused").localized())
                    }
                }
            }
        }
    }
}

/// 在参考 FlowLayout 上限制单个芯片的最大提议宽度；超长名字换行，不横向顶开整个页面。
private struct CallReplicaFlowLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        layout(width: proposal.width ?? 600, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let result = layout(width: bounds.width, subviews: subviews)
        for (index, placement) in result.placements.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y), anchor: .topLeading, proposal: ProposedViewSize(placement.size))
        }
    }
    private func layout(width: CGFloat, subviews: Subviews) -> (size: CGSize, placements: [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        var placements: [CGRect] = []
        let available = max(1, width)
        for subview in subviews {
            let natural = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(available, natural.width), height: nil))
            if x > 0 && x + size.width > available { x = 0; y += rowHeight + lineSpacing; rowHeight = 0 }
            placements.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            widest = max(widest, x + size.width); x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: min(widest, available), height: y + rowHeight), placements)
    }
}
