import SwiftUI

/// 请求明细与价格统计共用一个纵向滚动区域，筛选、摘要、说明、表格和底栏随整页一起移动。
/// GeometryReader 只读取导航目的地已经分配的尺寸，不回写窗口或 State；这层边界避免
/// AppKit 以零宽度探测最小尺寸时，将多行说明测成上千点高的文本列并自动撑大窗口。
struct CPAUsageDetailPage<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                        .frame(maxWidth: .infinity, alignment: .leading)
                    content
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
            // 仅约束页面视口，不约束文档高度；多行说明与完整表格不会成为窗口的最小高度。
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .quotioPage()
    }
}

/// 表格标题、数据区和底栏归入同一张产品卡片。保留原生 Table 的列宽调整、横向滚动、
/// 键盘与辅助功能，仅通过公开样式 API 去掉独立的系统底色及交替条纹，融入页面背景。
struct CPAUsageTableCard<Header: View, Content: View, Footer: View>: View {
    /// 显式传入当前页的布局身份，让原生异步更新行数时也能触发重新测量。
    var layoutIdentity: AnyHashable = 0
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    @Environment(\.colorScheme) private var colorScheme
    /// 空表先保留加载／错误提示空间，真实行布局完成后由局部测量器更新为内容高度。
    @State private var tableHeight: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            content
                .tableStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                .scrollContentBackground(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .font(.callout)
                // SwiftUI Table 没有内容自适应高度接口。测量原生行边界让纵向内容完整展开，
                // 保留 Table 自身的横向滚动、列宽调整与原生单元格复用，不禁用整个滚动控件。
                .background(CPAUsageTableContentHeightReader(height: $tableHeight, layoutIdentity: layoutIdentity))
                .frame(minWidth: 0, maxWidth: .infinity)
                .frame(height: tableHeight)

            footer
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(QuotioTheme.Colors.cardInset(for: colorScheme))
        }
        .clipShape(RoundedRectangle(cornerRadius: QuotioTheme.Radius.lg, style: .continuous))
        // 只裁剪表格及底栏内容，再由外层卡片绘制阴影，避免阴影被同一裁剪层截掉。
        .quotioCard(padding: 0)
        .overlay {
            RoundedRectangle(cornerRadius: QuotioTheme.Radius.lg, style: .continuous)
                .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}
