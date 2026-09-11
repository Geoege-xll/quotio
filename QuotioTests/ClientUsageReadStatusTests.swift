import XCTest
@testable import Quotio

/// 用临时数据库和合成检查点验证状态分离；不扫描、删除或重置真实用户历史。
final class ClientUsageReadStatusTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func store(_ root: URL) throws -> ClientUsageSQLiteStore {
        let result = ClientUsageSQLiteStore(databaseURL: root.appendingPathComponent("analytics.sqlite"))
        _ = try result.loadLedgerMetadata(legacyURL: root.appendingPathComponent("ledger.json"))
        return result
    }

    private func checkpoint(_ session: String, parent: String? = nil, timestamp: Double, total: Int) -> CodexUsageCheckpoint {
        CodexUsageCheckpoint(rawSessionID: session, rawParentSessionID: parent,
            timestamp: Date(timeIntervalSince1970: timestamp), forkDate: parent == nil ? nil : Date(timeIntervalSince1970: 1000),
            model: "fixture", cumulative: .init(input: total, output: 0, cached: 0, reasoning: 0, total: total),
            last: nil, ordinal: 0)
    }

    private func orphanScan() -> ClientUsageScan {
        .init(source: .codex, codexCheckpoints: [
            checkpoint("child", parent: "parent", timestamp: 1010, total: 100),
            checkpoint("child", parent: "parent", timestamp: 1020, total: 120)
        ], filesScanned: 1, available: true)
    }

    func testHistoricalGapSurvivesRefreshAndReopenWithoutReadFailureOrDataLoss() throws {
        let root = try directory()
        let value = try store(root)
        try value.mergeIncrementally(scans: [orphanScan()], at: Date())
        let before = try value.loadRecords(scope: "ledger")
        XCTAssertEqual(before.reduce(0) { $0 + $1.total }, 20)
        // 后续扫描没有新数据：保留全部已确认差额，历史缺口仍如实显示，但读取已经完成。
        try value.mergeIncrementally(scans: [.init(source: .codex, filesScanned: 1, available: true)], at: Date())
        let reopened = try store(root)
        let status = try XCTUnwrap(reopened.ledgerMetadata().statuses.first)
        XCTAssertFalse(status.hasReadErrors)
        XCTAssertTrue(status.hasErrors)
        XCTAssertEqual(status.incompleteSessionCount, 1)
        XCTAssertEqual(status.readingStatusKey, "usage.client.readableWithHistory")
        XCTAssertEqual(try reopened.loadRecords(scope: "ledger"), before)
    }

    func testRealReadFailureStillWinsAndHealthyRefreshOnlyClearsReadFailure() throws {
        let value = try store(directory())
        try value.mergeIncrementally(scans: [orphanScan()], at: Date())
        try value.mergeIncrementally(scans: [.init(source: .codex, codexReadErrors: true, available: true, hasErrors: true)], at: Date())
        let failed = try XCTUnwrap(value.ledgerMetadata().statuses.first)
        XCTAssertTrue(failed.hasReadErrors)
        XCTAssertEqual(failed.readingStatusKey, "usage.client.readFailed")
        try value.mergeIncrementally(scans: [.init(source: .codex, available: true)], at: Date())
        let recovered = try XCTUnwrap(value.ledgerMetadata().statuses.first)
        XCTAssertFalse(recovered.hasReadErrors)
        XCTAssertEqual(recovered.incompleteSessionCount, 1)
    }

    func testLateParentRepairsHistoryAndRecalculatesInsteadOfHidingMissingEvidence() throws {
        let value = try store(directory())
        try value.mergeIncrementally(scans: [orphanScan()], at: Date())
        let parent = checkpoint("parent", timestamp: 990, total: 80)
        try value.mergeIncrementally(scans: [.init(source: .codex, codexCheckpoints: [parent], available: true)], at: Date())
        let status = try XCTUnwrap(value.ledgerMetadata().statuses.first)
        XCTAssertFalse(status.hasErrors)
        XCTAssertFalse(status.hasReadErrors)
        XCTAssertEqual(status.incompleteSessionCount, 0)
        XCTAssertEqual(status.readingStatusKey, "usage.client.readable")
        XCTAssertEqual(try value.loadRecords(scope: "ledger").reduce(0) { $0 + $1.total }, 120)
    }

    func testOldArchiveUsesConservativeFallbackUntilActualScan() throws {
        let data = Data(#"{"source":"codex","available":true,"hasErrors":true,"filesScanned":10}"#.utf8)
        let status = try JSONDecoder().decode(ClientUsageStatus.self, from: data)
        XCTAssertNil(status.readErrors)
        XCTAssertNil(status.incompleteSessionCount)
        XCTAssertTrue(status.hasReadErrors)
        XCTAssertEqual(status.readingStatusKey, "usage.client.readFailed")
    }

    func testOldSQLiteStatusIsNotGuessedAndNewDetailsPreserveExistingRows() throws {
        let root = try directory()
        let database = AnalyticsDatabase(url: root.appendingPathComponent("analytics.sqlite"))
        try database.execute("CREATE TABLE client_usage_status (source TEXT PRIMARY KEY,available INTEGER,has_errors INTEGER,files_scanned INTEGER)")
        try database.execute("INSERT INTO client_usage_status VALUES('codex',1,1,10)")
        let value = try store(root)
        XCTAssertNil(try value.ledgerMetadata().statuses.first?.readErrors)
        XCTAssertTrue(try XCTUnwrap(value.ledgerMetadata().statuses.first).hasReadErrors)
        try value.mergeIncrementally(scans: [orphanScan()], at: Date())
        let status = try XCTUnwrap(value.ledgerMetadata().statuses.first)
        XCTAssertFalse(status.hasReadErrors)
        XCTAssertEqual(status.incompleteSessionCount, 1)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM client_usage_status"), 1)
    }

    func testMissingSourceKeepsHistoryWarningWithoutPretendingItIsAvailable() {
        let status = ClientUsageStatus(source: .codex, available: false, hasErrors: true, filesScanned: 0,
                                       readErrors: false, incompleteSessionCount: 5)
        XCTAssertEqual(status.readingStatusKey, "usage.client.missing")
        XCTAssertTrue(status.hasIncompleteHistory)
    }

    func testRemovedBadFileDoesNotPoisonCurrentReadButKeepsHistoricalEvidence() throws {
        let root = try directory()
        let logs = root.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("fixture.jsonl")
        let contents = """
        {"type":"session_meta","payload":{"id":"fixture-session"}}
        {"timestamp":"2026-01-01T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}
        invalid-json

        """
        try contents.write(to: file, atomically: true, encoding: .utf8)
        let value = try store(root)
        let source = CodexClientUsageSource(homeDirectory: root.path, environment: [:])
        let failed = try source.collect(cacheStore: value, projectRecords: false, incremental: true)
        XCTAssertTrue(failed.codexReadErrors)
        try value.mergeIncrementally(scans: [failed], at: Date())
        let count = try value.database.scalarInt("SELECT COUNT(*) FROM client_usage_checkpoints")
        try FileManager.default.removeItem(at: file)
        let next = try source.collect(cacheStore: value, projectRecords: false, incremental: true)
        XCTAssertFalse(next.codexReadErrors)
        XCTAssertFalse(next.hasErrors)
        try value.mergeIncrementally(scans: [next], at: Date())
        let status = try XCTUnwrap(value.ledgerMetadata().statuses.first)
        XCTAssertFalse(status.hasReadErrors)
        XCTAssertEqual(status.incompleteSessionCount, 1)
        XCTAssertEqual(try value.database.scalarInt("SELECT COUNT(*) FROM client_usage_checkpoints"), count)
    }

    @MainActor
    func testViewModelCompletesReadingWhileKeepingHistoryNotice() async throws {
        let root = try directory()
        let orphan = orphanScan()
        let engine = ClientUsageEngine(url: root.appendingPathComponent("ledger.json"), homeDirectory: root.path,
            environment: [:], scanOverride: { source, _ in
                source == .codex ? orphan : ClientUsageScan(source: source, available: true)
            })
        let model = ClientUsageViewModel(engine: engine)
        model.refresh()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.isLoading && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorKey)
        XCTAssertEqual(model.activities[.codex]?.phase, .complete)
        XCTAssertEqual(model.snapshot.statuses.first { $0.source == .codex }?.incompleteSessionCount, 1)
    }
}
