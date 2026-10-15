//
//  AgentManagementComponents.swift
//  Quotio - Unified Agent Management
//

import SwiftUI

/// 代理管理页面共用的布局及弹窗组件集中在此，供各子页面调用。
// MARK: - Legend Flow Layout

struct QuotioLegendFlowLayout: Layout {
    var spacing: CGFloat = 16
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0
        let maxWidth = proposal.width ?? .infinity

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + lineSpacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxLineWidth = max(maxLineWidth, currentX - spacing)
        }

        let totalHeight = currentY + lineHeight
        let actualWidth = proposal.width ?? maxLineWidth
        return (CGSize(width: actualWidth, height: totalHeight), positions)
    }
}

// MARK: - Modals & Sheets

struct SkillDetailSheet: View {
    let skill: WorkspaceSkill
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var fileContent: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("~/.quotio/skills/\(skill.directory)/SKILL.md")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.quotioSecondaryCapsule)
            }

            Divider()
                .overlay(QuotioTheme.Colors.sidebarBorder(for: colorScheme))

            ScrollView {
                Text(fileContent.isEmpty ? "正在读取 SKILL.md 文档内容..." : fileContent)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(
                RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                    .fill(QuotioTheme.Colors.cardInset(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                    .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
            )
        }
        .padding(24)
        .frame(width: 620, height: 520)
        .background(QuotioTheme.Colors.canvasBackground(for: colorScheme))
        .task {
            let path = (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
                .appendingPathComponent(".quotio/skills/\(skill.directory)/SKILL.md")
            fileContent = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "未找到 SKILL.md 文件"
        }
    }
}

struct AddRepoSheet: View {
    @Bindable var viewModel: WorkspaceViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("添加 GitHub 技能仓库源")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)

                Text("输入开源仓库（例如: anthropics/skills 或完整 GitHub 链接）")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            QuotioCapsuleTextField(
                "例如: anthropics/skills",
                text: $viewModel.newRepoURL,
                systemImage: "network",
                monospaced: true
            )

            HStack(spacing: 12) {
                Button("取消") {
                    viewModel.showAddRepoSheet = false
                }
                .buttonStyle(.quotioSecondaryCapsule)

                Button {
                    Task { await viewModel.addRepo(url: viewModel.newRepoURL) }
                } label: {
                    Text("添加并拉取")
                }
                .buttonStyle(.quotioPrimaryCapsule)
                .disabled(viewModel.newRepoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(QuotioTheme.Colors.canvasBackground(for: colorScheme))
    }
}
