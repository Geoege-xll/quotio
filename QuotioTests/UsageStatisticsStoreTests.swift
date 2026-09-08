import XCTest
@testable import Quotio

/// 使用可控 actor 模拟 CPA，验证弹出式队列始终只有一个消费者以及启停时的数据提交顺序。
final class UsageStatisticsStoreTests: XCTestCase {
    private actor QueueClient: UsageStatisticsClient {
        var queueCalls = 0
        let started: XCTestExpectation
        let enabled: Bool
        var waiter: CheckedContinuation<UsageQueueBatch, Error>?
        var legacy = false
        init(started: XCTestExpectation, enabled: Bool = true, legacy: Bool = false) {
            self.started = started; self.enabled = enabled; self.legacy = legacy
        }
        func getUsageStatisticsEnabled() async throws -> Bool {
            if !enabled { started.fulfill() }
            return enabled
        }
        func setUsageStatisticsEnabled(_ enabled: Bool) async throws {}
        func fetchUsageStats() async throws -> UsageStats {
            started.fulfill()
            return UsageStats(usage: UsageData(totalRequests: 8, successCount: 7, failureCount: 1,
                                              totalTokens: 100, inputTokens: 60, outputTokens: 40), failedRequests: 1)
        }
        func fetchUsageQueue(count: Int) async throws -> UsageQueueBatch {
            queueCalls += 1
            if legacy { throw APIError.httpError(404) }
            return try await withCheckedThrowingContinuation { continuation in
                waiter = continuation; started.fulfill()
            }
        }
        func release() throws {
            let data = Data(#"[{"timestamp":"2026-09-05T01:00:00Z","request_id":"test","provider":"fixture","model":"fixture","tokens":{"total_tokens":10}}]"#.utf8)
            let batch = try JSONDecoder().decode(UsageQueueBatch.self, from: data)
            waiter?.resume(returning: batch); waiter = nil
        }
    }
    private func ledger() throws -> UsageLedger {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return UsageLedger(url: directory.appendingPathComponent("ledger.json"))
    }

    @MainActor
    func testConcurrentRefreshDoesNotCreateAnotherQueueConsumer() async throws {
        let started = expectation(description: "首个队列请求等待返回")
        let client = QueueClient(started: started)
        let store = UsageStatisticsStore(ledger: try ledger())
        store.start(client: client, sessionID: UUID())
        await fulfillment(of: [started], timeout: 3)
        await store.refresh(); await store.refresh()
        let count = await client.queueCalls
        XCTAssertEqual(count, 1)
        // 停止后仍需提交已弹出的响应，但不能恢复成 live。
        store.stop()
        try await client.release()
        for _ in 0..<100 where store.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.snapshot.totals.requests, 1)
        XCTAssertEqual(store.snapshot.totals.totalTokens, 10)
        XCTAssertEqual(store.state, .stopped)
    }

    @MainActor
    func testDisabledCollectionNeverPopsQueueOrPretendsToHaveZeroData() async throws {
        let started = expectation(description: "读取关闭状态")
        let client = QueueClient(started: started, enabled: false)
        let store = UsageStatisticsStore(ledger: try ledger())
        store.start(client: client, sessionID: UUID())
        await fulfillment(of: [started], timeout: 3)
        for _ in 0..<100 where store.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.state, .disabled)
        XCTAssertFalse(store.hasData)
        let count = await client.queueCalls
        XCTAssertEqual(count, 0)
        store.stop()
    }

    @MainActor
    func testLegacyTotalsAreReadWithoutAddingSnapshotIntoNewLedger() async throws {
        let started = expectation(description: "旧版快照已读取")
        let client = QueueClient(started: started, legacy: true)
        let store = UsageStatisticsStore(ledger: try ledger())
        store.start(client: client, sessionID: UUID())
        await fulfillment(of: [started], timeout: 3)
        for _ in 0..<100 where store.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.state, .legacy)
        XCTAssertEqual(store.totals.requests, 8)
        XCTAssertEqual(store.totals.totalTokens, 100)
        XCTAssertTrue(store.snapshot.buckets.isEmpty)
        store.stop()
    }
}
