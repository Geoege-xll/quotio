import Foundation

/// 明细列表统一固定为每页 20 条。分页仅决定可见行，不截断用于顶部汇总的完整筛选结果。
nonisolated struct CPAUsageTablePage: Equatable {
    static let size = 20
    let totalCount: Int
    let number: Int
    let totalPages: Int

    init(totalCount: Int, number: Int) {
        let count = max(0, totalCount)
        self.totalCount = count
        // 使用除法与余数计算，避免极大计数加上 pageSize - 1 时溢出。
        totalPages = max(1, count / Self.size + (count % Self.size == 0 ? 0 : 1))
        self.number = min(totalPages, max(1, number))
    }

    /// 价格行和历史日汇总已是完整查询投影，只复制当前页的最多 20 行，保留原始身份与排序。
    func rows<Row>(from rows: [Row]) -> [Row] {
        let start = min(rows.count, (number - 1) * Self.size)
        let end = start + min(Self.size, rows.count - start)
        return Array(rows[start..<end])
    }
}
