import XCTest
@testable import Quotio

/// 通过受控慢来源覆盖真实Engine→ViewModel刷新链路；只使用临时账本，不读取用户会话。
@MainActor
final class ClientUsageRefreshTests: XCTestCase {
    private func engine(_ scans: ControlledUsageScans) throws -> ClientUsageEngine {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ClientUsageEngine(url: root.appendingPathComponent("ClientUsage/ledger.json"), homeDirectory: root.path,
            environment: [:], scanOverride: { source, progress in try await scans.collect(source, progress: progress) })
    }
    private func eventually(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "状态应在慢来源完成前可观察", file: file, line: line)
    }
    func testCompletedClientsPublishWhileCodexIsStillScanning() async throws {
        let scans = ControlledUsageScans(slow: .codex)
        let model = ClientUsageViewModel(engine: try engine(scans))
        model.refresh()
        try await eventually { model.snapshot.statuses.count == ClientUsageSource.allCases.count - 1 }
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(Set(model.snapshot.statuses.map(\.source)), [.claude, .opencode, .pi])
        XCTAssertTrue(model.snapshot.hasData(source: .claude))
        XCTAssertEqual(model.activities[.codex]?.progress.filesTotal, 1284)
        XCTAssertFalse(model.buckets.isEmpty)
        await scans.release()
        try await eventually { !model.isLoading }
        XCTAssertEqual(model.snapshot.statuses.count, ClientUsageSource.allCases.count)
        XCTAssertNil(model.errorKey)
    }
    func testRepeatedRefreshCoalescesAndCancelRetainsCompletedClients() async throws {
        let scans = ControlledUsageScans(slow: .codex)
        let model = ClientUsageViewModel(engine: try engine(scans))
        model.refresh(); model.refresh(); model.refresh()
        try await eventually { model.snapshot.statuses.count == ClientUsageSource.allCases.count - 1 }
        let count = await scans.count(.codex)
        XCTAssertEqual(count, 1)
        model.cancelRefresh()
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.errorKey, "usage.client.cancelled")
        XCTAssertEqual(model.snapshot.statuses.count, ClientUsageSource.allCases.count - 1)
        XCTAssertEqual(model.activities[.codex]?.phase, .cancelled)
        await scans.release()
        // 再次手动刷新必须可用，已取消的旧通知不能覆盖新的generation。
        model.refresh()
        try await eventually { !model.isLoading }
        XCTAssertEqual(model.snapshot.statuses.count, ClientUsageSource.allCases.count)
        XCTAssertEqual(model.activities[.codex]?.phase, .complete)
    }
    func testOneFailedClientDoesNotDiscardOtherResultsOrRemainLoading() async throws {
        let scans = ControlledUsageScans(failing: .opencode)
        let model = ClientUsageViewModel(engine: try engine(scans))
        model.refresh()
        try await eventually { !model.isLoading }
        XCTAssertEqual(model.snapshot.statuses.count, ClientUsageSource.allCases.count)
        XCTAssertTrue(model.snapshot.hasData(source: .claude))
        XCTAssertEqual(model.activities[.opencode]?.phase, .failed)
        XCTAssertEqual(model.errorKey, "usage.client.partial")
    }
    func testCompletedClientIsPersistedBeforeSlowClientAndSurvivesCancellation() async throws {
        let scans = ControlledUsageScans(slow: .codex)
        let engine = try engine(scans)
        let model = ClientUsageViewModel(engine: engine)
        model.refresh()
        try await eventually { model.snapshot.statuses.count == ClientUsageSource.allCases.count - 1 }
        model.cancelRefresh()
        let stored = try await engine.load()
        XCTAssertEqual(stored.statuses.count, ClientUsageSource.allCases.count - 1)
        XCTAssertTrue(stored.hasData(source: .claude))
        XCTAssertFalse(stored.records.contains { $0.source == .codex })
    }
    func testLeavingAndReenteringCannotPublishCancelledGeneration() async throws {
        let scans = ControlledUsageScans(slow: .codex)
        let model = ClientUsageViewModel(engine: try engine(scans))
        model.start()
        try await eventually { model.snapshot.statuses.count == ClientUsageSource.allCases.count - 1 }
        model.cancel()
        await scans.release()
        model.start()
        try await eventually { !model.isLoading }
        XCTAssertEqual(model.snapshot.statuses.count, ClientUsageSource.allCases.count)
        XCTAssertNil(model.errorKey)
        model.cancel()
    }
}

/// 用可取消的异步等待模拟大历史，不阻塞线程或依赖真实时间长睡眠。
private actor ControlledUsageScans {
    enum ScanError: Error { case failed }
    let slow: ClientUsageSource?
    let failing: ClientUsageSource?
    private var released = false
    private var counts: [ClientUsageSource: Int] = [:]
    init(slow: ClientUsageSource? = nil, failing: ClientUsageSource? = nil) { self.slow = slow; self.failing = failing }
    func release() { released = true }
    func count(_ source: ClientUsageSource) -> Int { counts[source, default: 0] }
    func collect(_ source: ClientUsageSource, progress: ClientUsageProgressHandler) async throws -> ClientUsageScan {
        counts[source, default: 0] += 1
        progress(ClientUsageProgress(source: source, filesCompleted: 1, filesTotal: source == slow ? 1284 : 1, bytesRead: 1024, bytesTotal: 2048))
        if source == failing { throw ScanError.failed }
        while source == slow && !released { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation()
        let record = ClientUsageRecord(identity: "test", source: source, timestamp: Date(timeIntervalSince1970: 1000),
            model: "test-model", input: 10, output: 2)
        return ClientUsageScan(source: source, records: [record], filesScanned: 1, available: true)
    }
}
