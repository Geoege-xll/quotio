import XCTest
@testable import QuotioPlus

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
        func fetchUsageQueue(count: Int) async throws -> UsageQueueBatch {
            queueCalls += 1
            if legacy { started.fulfill(); throw APIError.httpError(404) }
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
    func testUserRefreshDuringBackgroundCollectionWaitsWithoutPoppingAnotherBatch() async throws {
        let started = expectation(description: "后台采集等待响应")
        let client = QueueClient(started: started)
        let store = UsageStatisticsStore(ledger: try ledger())
        let manual = ManualRefreshState()
        store.start(client: client, sessionID: UUID())
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(store.isRefreshing)
        XCTAssertFalse(manual.isRefreshing, "后台采集不应驱动手动按钮")
        let clicked = Task { await manual.perform { await store.refreshForUser() } }
        while !manual.isRefreshing { await Task.yield() }
        XCTAssertTrue(manual.isRefreshing)
        let count = await client.queueCalls
        XCTAssertEqual(count, 1)
        try await client.release()
        await clicked.value
        XCTAssertFalse(manual.isRefreshing)
        XCTAssertEqual(store.snapshot.totals.requests, 1, "手动等待应在已消费响应落盘后结束")
        let finalCount = await client.queueCalls
        XCTAssertEqual(finalCount, 1)
        store.stop()
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
    func testMissingV8QueueIsUnsupportedAndNeverFallsBackToLegacyTotals() async throws {
        let started = expectation(description: "v8 队列缺失")
        let client = QueueClient(started: started, legacy: true)
        let store = UsageStatisticsStore(ledger: try ledger())
        store.start(client: client, sessionID: UUID())
        await fulfillment(of: [started], timeout: 3)
        for _ in 0..<100 where store.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.state, .unsupported)
        XCTAssertEqual(store.totals.requests, 0)
        XCTAssertEqual(store.totals.totalTokens, 0)
        XCTAssertFalse(store.hasData)
        await store.refresh()
        let calls = await client.queueCalls
        XCTAssertEqual(calls, 1, "同一失效会话不再访问旧接口，也不重复请求缺失队列")
        XCTAssertTrue(store.snapshot.buckets.isEmpty)
        store.stop()
    }
}
