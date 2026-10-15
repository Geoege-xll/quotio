import SwiftUI

/// 三种明细表共用同一分页底栏：固定每页 20 条，不提供扩大页容量或滚动追加数据的入口。
struct CPAUsageTablePagination: View {
    let page: CPAUsageTablePage
    var isLoading = false
    let onPageChange: (Int) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                information
                Spacer(minLength: 12)
                controls
            }
            // 紧凑窗口只让底栏换行；页码、总条数和翻页按钮始终完整保留。
            VStack(alignment: .leading, spacing: 8) {
                information
                controls
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private var information: some View {
        HStack(spacing: 8) {
            if isLoading { ProgressView().controlSize(.small) }
            Text(String(format: "usage.records.pageInfo".localized(), page.number, page.totalPages, page.totalCount))
                .monospacedDigit()
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Text("usage.records.pageSize".localized() + ": " + CPAUsageTablePage.size.formatted())
                .monospacedDigit().fixedSize()
            Button { onPageChange(page.number - 1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.quotioMicroCapsule)
                .help("usage.records.previous".localized()).accessibilityLabel("usage.records.previous".localized())
                .disabled(isLoading || page.number <= 1)
            Button { onPageChange(page.number + 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.quotioMicroCapsule)
                .help("usage.records.next".localized()).accessibilityLabel("usage.records.next".localized())
                .disabled(isLoading || page.number >= page.totalPages)
        }
    }
}
