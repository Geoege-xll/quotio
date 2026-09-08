import XCTest
import Darwin
@testable import Quotio

/// 手动性能验收使用只读备份得到的临时数据库副本。普通回归未提供目录时跳过，绝不自动读取生产库。
/// 指标为同一测试进程的 physical footprint，不能与另一个应用的 RSS 直接比较。
final class ClientUsageMemoryBenchmarkTests: XCTestCase {
    private func memoryInfo() throws -> task_vm_info_data_t {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw NSError(domain: "MemoryBenchmark", code: Int(result)) }
        return info
    }

    func testLargeDatabaseSummaryMemoryAndTotals() throws {
        guard let path = ProcessInfo.processInfo.environment["QUOTIO_MEMORY_BENCHMARK_DIRECTORY"] else {
            throw XCTSkip("仅在显式指定隔离数据库副本时运行大规模性能验收")
        }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard ["/private/tmp/quotio-memory-benchmark-", "/tmp/quotio-memory-benchmark-"].contains(where: root.path.hasPrefix) else {
            throw NSError(domain: "MemoryBenchmarkRequiresTemporaryCopy", code: 1)
        }
        let expectedData = try Data(contentsOf: root.appendingPathComponent("expected.json"))
        let expectedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: expectedData) as? [String: Any])
        let expected = try XCTUnwrap(expectedObject["totals"] as? [Int64])
        let store = ClientUsageSQLiteStore(databaseURL: root.appendingPathComponent("fixture.sqlite"))
        let before = try memoryInfo().phys_footprint
        let began = ContinuousClock.now
        _ = try store.loadLedgerMetadata(legacyURL: root.appendingPathComponent("absent-ledger.json"))
        let cold = try store.loadDisplay(calendar: .current)
        let coldSeconds = elapsed(began)
        let afterCold = try memoryInfo().phys_footprint
        XCTAssertTrue(cold.metadata.records.isEmpty)
        XCTAssertNil(cold.metadata.codexCheckpoints)
        let totals = cold.buckets.reduce(into: [Int64](repeating: 0, count: 6)) { sum, row in
            for (index, value) in [row.requests, row.inputTokens, row.outputTokens, row.cachedTokens, row.reasoningTokens, row.totalTokens].enumerated() {
                sum[index] += Int64(value)
            }
        }
        XCTAssertEqual(totals, expected, "数据库汇总必须完整保留所有历史口径")
        let warmStarted = ContinuousClock.now
        for _ in 0..<20 {
            let warm = try store.loadDisplay(calendar: .current)
            XCTAssertTrue(warm.buckets == cold.buckets, "重复读取必须保持全部汇总一致")
        }
        let warmSeconds = elapsed(warmStarted)
        let afterWarm = try memoryInfo().phys_footprint
        // 单独覆盖首次升级待投影的消费；之后再重复无变化刷新，确保不会每轮重新构造全历史。
        let mergeStarted = ContinuousClock.now
        try store.mergeIncrementally(scans: [ClientUsageScan(source: .codex, available: true)], at: Date())
        let mergeSeconds = elapsed(mergeStarted)
        let afterMerge = try memoryInfo().phys_footprint
        let finalDisplay = try store.loadDisplay(calendar: .current)
        // 在线备份可能恰好落在“扫描已提交、账本尚未投影”的间隙，因此恢复后允许补入待处理事件。
        // 逐列验证备份时已经入账的事实不变，并要求新增记录全部来自副本中原有的扫描检查点。
        // 比对在 SQLite 内完成，不让验收逻辑自身重新分配 66 万条 Swift 记录或输出整份统计。
        let comparison = ClientUsageSQLiteStore.recordColumns.split(separator: ",")
            .map { "current.\($0) IS NOT previous.\($0)" }.joined(separator: " OR ")
        let changedExisting = try store.database.scalarInt("""
            SELECT COUNT(*) FROM benchmark_ledger_before previous
            LEFT JOIN client_usage_records current ON current.scope='ledger' AND current.id=previous.id
            WHERE \(comparison)
            """) ?? -1
        XCTAssertEqual(changedExisting, 0, "重新投影不能修改或丢失副本中已验证的历史事实")
        let recovered = try store.database.scalarInt("""
            SELECT COUNT(*) FROM client_usage_records current WHERE current.scope='ledger'
              AND NOT EXISTS (SELECT 1 FROM benchmark_ledger_before previous WHERE previous.id=current.id)
            """) ?? -1
        let unsupported = try store.database.scalarInt("""
            SELECT COUNT(*) FROM client_usage_records current WHERE current.scope='ledger'
              AND NOT EXISTS (SELECT 1 FROM benchmark_ledger_before previous WHERE previous.id=current.id)
              AND NOT EXISTS (SELECT 1 FROM client_usage_checkpoints staged
                              WHERE staged.scope LIKE 'scan:%' AND staged.id=current.id)
            """) ?? -1
        XCTAssertEqual(unsupported, 0, "恢复新增的事件必须有原有扫描检查点支撑")
        XCTAssertEqual(Int64(finalDisplay.buckets.reduce(0) { $0 + $1.requests }), expected[0] + recovered)
        XCTAssertEqual(try store.database.scalarInt("SELECT COUNT(*) FROM client_usage_projection_dirty"), 0)
        let repeatStarted = ContinuousClock.now
        for _ in 0..<3 {
            try store.mergeIncrementally(scans: [ClientUsageScan(source: .codex, available: true)], at: Date())
        }
        let repeatSeconds = elapsed(repeatStarted)
        XCTAssertTrue(try store.loadDisplay(calendar: .current).buckets == finalDisplay.buckets,
                      "待处理事件恢复完成后，无变化刷新必须保持统计不变")
        store.clearMemoryCaches()
        let finalInfo = try memoryInfo()
        let finalMemory = finalInfo.phys_footprint
        let measurements: [String: Any] = [
            "records": expected[0], "buckets": cold.buckets.count,
            "recovered_pending_records": recovered, "changed_existing_records": changedExisting,
            "cold_summary_seconds": coldSeconds, "twenty_cached_summaries_seconds": warmSeconds,
            "first_projection_seconds": mergeSeconds, "three_unchanged_merges_seconds": repeatSeconds,
            "baseline_footprint_bytes": before, "after_cold_footprint_bytes": afterCold,
            "after_twenty_reads_footprint_bytes": afterWarm, "after_projection_footprint_bytes": afterMerge,
            "final_footprint_bytes": finalMemory,
            "peak_footprint_bytes": finalInfo.ledger_phys_footprint_peak
        ]
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("measurements.json"))
        // 阈值留出测试宿主和 SQLite 页缓存空间，同时捕获先前接近 1 GiB 的全历史数组回归。
        XCTAssertLessThan(finalMemory - min(finalMemory, before), 256 * 1024 * 1024)
    }

    private func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
