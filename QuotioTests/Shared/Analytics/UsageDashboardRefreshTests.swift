import XCTest
@testable import QuotioPlus

/// 运行真实唯一消费者，验证仪表盘不能把忙碌跳过、失败或上次残留 live 当作本轮成功。
/// 客户端为内存 actor，账本位于临时目录；不会弹出真实 CPA 队列或读取用户历史数据库。
@MainActor
final class UsageDashboardRefreshTests: XCTestCase {
    private let sessionID = UUID()
    private actor QueueClient: UsageStatisticsClient {
        let started: [XCTestExpectation]
        let enabled: Bool
        private(set) var queueCalls = 0
        private var waiter: CheckedContinuation<UsageQueueBatch, Error>?
        init(started: [XCTestExpectation], enabled: Bool = true) { self.started = started; self.enabled = enabled }
        func getUsageStatisticsEnabled() async throws -> Bool { enabled }
        func setUsageStatisticsEnabled(_ enabled: Bool) async throws {}
        func fetchUsageQueue(count: Int) async throws -> UsageQueueBatch {
            queueCalls += 1
            return try await withCheckedThrowingContinuation {
                waiter = $0
                if queueCalls <= started.count { started[queueCalls - 1].fulfill() }
            }
        }
        func release(error: Error? = nil) throws {
            let waiter = waiter
            self.waiter = nil
            if let error { waiter?.resume(throwing: error) }
            else { waiter?.resume(returning: try JSONDecoder().decode(UsageQueueBatch.self, from: Data("[]".utf8))) }
        }
    }

    private func ledger(blocked: Bool = false) throws -> UsageLedger {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        if blocked {
            let file = directory.appendingPathComponent("not-a-directory")
            try Data("fixture".utf8).write(to: file)
            return UsageLedger(url: file.appendingPathComponent("ledger.json"))
        }
        return UsageLedger(url: directory.appendingPathComponent("ledger.json"))
    }

    /// 明确等到手动任务已进入原等待入口，再释放网络门，避免任务尚未启动就把下一轮误当当前轮。
    private func dashboardWaiter(_ store: UsageStatisticsStore) async -> Task<Bool, Never> {
        var entered = false
        let pending = Task { entered = true; return await store.refreshForDashboard(sessionID: sessionID) }
        while !entered { await Task.yield() }
        return pending
    }

    func testBusyDashboardWaitsForSameConsumerAndReturnsSuccessAfterPersistence() async throws {
        let started = expectation(description: "唯一消费者等待队列")
        let client = QueueClient(started: [started]), store = UsageStatisticsStore(ledger: try ledger())
        store.start(client: client, sessionID: sessionID)
        defer { store.stop() }
        await fulfillment(of: [started], timeout: 3)
        let mismatched = await store.refreshForDashboard(sessionID: UUID())
        XCTAssertFalse(mismatched, "消费者尚未接入当前代理会话时不能借旧会话记成功")
        var entered = false, completed = false
        let pending = Task { entered = true; let result = await store.refreshForDashboard(sessionID: sessionID); completed = true; return result }
        while !entered { await Task.yield() }
        XCTAssertFalse(completed)
        let calls = await client.queueCalls
        XCTAssertEqual(calls, 1)
        try await client.release()
        let success = await pending.value
        XCTAssertTrue(success)
        XCTAssertNotNil(store.snapshot.lastCollectedAt, "只有完成落盘后才可记录仪表盘成功时间")
        let finalCalls = await client.queueCalls
        XCTAssertEqual(finalCalls, 1, "手动等待不能额外消费一批")
    }

    func testNetworkFailureAndUnsupportedQueueAreNotSuccessfulRefreshes() async throws {
        for status in [401, 404] {
            let started = expectation(description: "等待队列失败")
            let client = QueueClient(started: [started]), store = UsageStatisticsStore(ledger: try ledger())
            store.start(client: client, sessionID: sessionID)
            await fulfillment(of: [started], timeout: 3)
            let pending = await dashboardWaiter(store)
            try await client.release(error: APIError.httpError(status))
            let success = await pending.value
            XCTAssertFalse(success)
            XCTAssertEqual(store.state, status == 404 ? .unsupported : .failed)
            store.stop()
        }
    }

    func testDisabledCollectionIsConfirmedWithoutConsumingQueue() async throws {
        let client = QueueClient(started: [], enabled: false), store = UsageStatisticsStore(ledger: try ledger())
        store.start(client: client, sessionID: sessionID)
        defer { store.stop() }
        let success = await store.refreshForDashboard(sessionID: sessionID)
        XCTAssertTrue(success)
        XCTAssertEqual(store.state, .disabled)
        let calls = await client.queueCalls
        XCTAssertEqual(calls, 0)
    }

    func testStorageFailureCannotReportSuccess() async throws {
        let client = QueueClient(started: []), store = UsageStatisticsStore(ledger: try ledger(blocked: true))
        store.start(client: client, sessionID: sessionID)
        defer { store.stop() }
        let success = await store.refreshForDashboard(sessionID: sessionID)
        XCTAssertFalse(success)
        XCTAssertEqual(store.state, .storageError)
        let calls = await client.queueCalls
        XCTAssertEqual(calls, 0)
    }

    func testStopOrMaintenanceWhileWaitingInvalidatesCompletionEvidence() async throws {
        for maintenance in [false, true] {
            let started = expectation(description: "暂停前队列挂起")
            let client = QueueClient(started: [started]), store = UsageStatisticsStore(ledger: try ledger())
            store.start(client: client, sessionID: sessionID)
            await fulfillment(of: [started], timeout: 3)
            let pending = await dashboardWaiter(store)
            var maintenanceTask: Task<Void, Error>?
            if maintenance {
                var entered = false
                maintenanceTask = Task { entered = true; try await store.suspendForMaintenance() }
                // 暂停在进入时同步改变存储世代，再挂起等待同一个消费者；让它先取得屏障。
                while !entered { await Task.yield() }
            } else { store.stop() }
            try await client.release()
            let success = await pending.value
            XCTAssertFalse(success)
            try await maintenanceTask?.value
            store.stop()
        }
    }

    func testCancelledCurrentConsumerCannotBorrowPreviousLiveState() async throws {
        let firstStarted = expectation(description: "首次成功采集")
        let secondStarted = expectation(description: "下一轮独立手动采集")
        let client = QueueClient(started: [firstStarted, secondStarted]), store = UsageStatisticsStore(ledger: try ledger())
        store.start(client: client, sessionID: sessionID)
        defer { store.stop() }
        await fulfillment(of: [firstStarted], timeout: 3)
        let firstWaiter = await dashboardWaiter(store)
        try await client.release()
        let firstSucceeded = await firstWaiter.value
        XCTAssertTrue(firstSucceeded)
        XCTAssertEqual(store.state, .live)

        let consumer = Task { await store.refresh() }
        await fulfillment(of: [secondStarted], timeout: 3)
        let waitingDashboard = await dashboardWaiter(store)
        consumer.cancel()
        try await client.release()
        await consumer.value
        let success = await waitingDashboard.value
        XCTAssertFalse(success, "同会话被取消的本轮不能借用旧 live 状态")
        XCTAssertEqual(store.state, .live, "原取消行为仍保留旧快照与显示状态")
    }
}
