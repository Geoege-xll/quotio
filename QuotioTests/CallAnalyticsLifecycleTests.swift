import XCTest
@testable import Quotio

/// 使用隔离日志证明筛选与侧栏重入复用快照；不读取真实会话，也不为测试加入生产诊断接口。
@MainActor
final class CallAnalyticsLifecycleTests: XCTestCase {
    private func temporaryHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quotio-call-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeCalls(_ count: Int, home: URL) throws {
        let file = home.appendingPathComponent(".claude/projects/p/session.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for index in 0..<count {
            let value: [String: Any] = ["type": "assistant", "timestamp": "2026-09-04T23:30:00Z", "sessionId": "session-one",
                "message": ["content": [["type": "tool_use", "id": "call-\(index)", "name": "Read"]]]]
            data.append(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
            data.append(0x0A)
        }
        try data.write(to: file)
    }

    private func waitForRefresh(_ model: CallAnalyticsViewModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isLoading, "隔离小型扫描必须在截止前完成")
        XCTAssertNil(model.errorMessage)
    }

    func testFreshnessAndFiltersReuseSnapshotUntilExplicitRefresh() async throws {
        let home = try temporaryHome()
        try writeCalls(1, home: home)
        let engine = CallAnalyticsEngine(homeDirectory: home.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:])
        let model = CallAnalyticsViewModel(engine: engine)
        model.range = .all
        model.refresh()
        model.refresh()
        try await waitForRefresh(model)
        XCTAssertEqual(model.report.totalCalls, 1)
        XCTAssertEqual(model.snapshot.sources.first { $0.source == .claude }?.filesScanned, 1)
        let generation = model.snapshot.generatedAt

        // 日志已经改变；筛选及一分钟内重入仍只操作最近快照，因此数量保持 1。
        try writeCalls(2, home: home)
        model.refreshIfNeeded()
        XCTAssertFalse(model.isLoading)
        for source in CallSourceKind.allCases {
            model.source = source
            XCTAssertEqual(model.report.totalCalls, source == .claude ? 1 : 0)
            _ = model.report.trend
            _ = model.report.rankings
        }
        model.source = .claude
        model.kind = .skill
        XCTAssertEqual(model.report.totalCalls, 0)
        model.kind = nil
        model.range = .custom
        model.customStart = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 4)))
        model.customEnd = model.customStart
        XCTAssertEqual(model.report.totalCalls, 1)
        XCTAssertEqual(model.snapshot.generatedAt, generation)
        XCTAssertFalse(model.isLoading)

        // 过期后后台刷新才看到新增日志；已缓存的相同筛选必须随新快照失效。
        model.refreshIfNeeded(now: Date().addingTimeInterval(61))
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.report.totalCalls, 1)
        try await waitForRefresh(model)
        XCTAssertEqual(model.report.totalCalls, 2)
        XCTAssertEqual(model.aggregationTimeZone.identifier, TimeZone(secondsFromGMT: 0)!.identifier)
        model.refreshIfNeeded()
        XCTAssertFalse(model.isLoading)
    }

    func testNewViewModelLoadsSQLiteSnapshotAndSkipsUnchangedSource() async throws {
        let home = try temporaryHome()
        try writeCalls(3, home: home)
        let original = CallAnalyticsEngine(homeDirectory: home.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:])
        _ = try await original.refresh()
        let restarted = CallAnalyticsEngine(homeDirectory: home.path, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!, environment: [:])
        let model = CallAnalyticsViewModel(engine: restarted)
        model.range = .all
        model.refreshIfNeeded()
        try await waitForRefresh(model)
        XCTAssertEqual(model.report.totalCalls, 3)
        XCTAssertTrue(model.snapshot.sources.allSatisfy { $0.filesScanned == 0 })
        XCTAssertEqual(model.aggregationTimeZone.identifier, TimeZone(secondsFromGMT: 0)!.identifier)
        XCTAssertEqual(Set(model.report.trend.map(\.day)), ["2026-09-04"])
    }
}
