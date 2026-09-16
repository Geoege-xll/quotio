import SwiftUI

/// 仓库头与技能卡片分开，地址按钮不嵌套在展开按钮里，点击链接不会同时改变折叠状态。
/// 折叠由分组视图持有，以稳定仓库 ID 保留；挂载、更新或卸载后不因技能数量变化而重置。
struct WorkspaceSkillRepositorySection<Content: View>: View {
    let group: WorkspaceSkillRepositoryGroup
    let searchText: String
    @ViewBuilder let content: Content
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 12)
                            .foregroundStyle(.secondary)
                        Image(systemName: group.repository == nil ? "folder" : "shippingbox.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.accentColor)
                        Text(group.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(group.skills.count == group.totalCount
                             ? "\(group.totalCount) 个技能"
                             : "\(group.skills.count)/\(group.totalCount) 个技能")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(group.title)
                .accessibilityValue(isExpanded ? "已展开" : "已折叠")
                .accessibilityHint(isExpanded ? "收起技能列表" : "展开技能列表")

                if let repository = group.repository {
                    WorkspaceSkillRepositoryAddressButton(repository: repository)
                }
            }
            .quotioCard(cornerRadius: QuotioTheme.Radius.lg, padding: 14)

            if isExpanded {
                content
                    .padding(.leading, 18)
            }
        }
        .onChange(of: searchText, initial: true) {
            // 搜索结果不能藏在折叠组里；用户仍可手动收起，下一次搜索词变化才再次展开。
            // 无仓库来源的本地技能默认展开，保持原先直接访问本地技能的习惯。
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || group.repository == nil {
                isExpanded = true
            }
        }
    }
}

/// 已纳管分组与 GitHub 发现页复用同一地址入口，由系统默认浏览器打开仓库首页。
struct WorkspaceSkillRepositoryAddressButton: View {
    let repository: SkillRepo

    var body: some View {
        if let url = repository.repositoryURL {
            Link(destination: url) {
                Label("地址", systemImage: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.quotioMicroCapsule(height: 26))
            .fixedSize()
            .help(url.absoluteString)
            .accessibilityLabel("打开 \(repository.id) 的 GitHub 仓库")
        }
    }
}
