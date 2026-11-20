import XCTest
@testable import QuotioPlus

/// 验证真实应用服务之间的维护屏障；只注入临时账本和模拟队列，不访问用户代理。
@MainActor
final class AnalyticsMaintenanceLifecycleTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("维护生命周期等待超时"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func client(_ directory: URL, scans: ScanCounter) -> ClientUsageViewModel {
        ClientUsageViewModel(engine: ClientUsageEngine(url: directory.appendingPathComponent("ledger.json"),
            homeDirectory: directory.path, environment: [:], scanOverride: { source, _ in await scans.collect(source) }))
    }

    /// 新增历史维护参与者也使用临时数据库，避免跨生命周期测试暂停应用级 shared 实例。
    private func history(_ directory: URL) -> QuotaHistoryService {
        QuotaHistoryService(store: QuotaHistoryStore(databaseURL: directory.appendingPathComponent("analytics.sqlite")))
    }

    func testEnteringUsageDuringMaintenanceRefreshesAfterResume() async throws {
        let scans = ScanCounter()
        let model = client(try root(), scans: scans)
        await model.suspendForMaintenance()
        model.start()
        let before = await scans.count
        XCTAssertEqual(before, 0)
        model.resumeAfterMaintenance()
        try await waitUntil { !model.isLoading && model.snapshot.statuses.count == ClientUsageSource.allCases.count }
        let after = await scans.count
        XCTAssertEqual(after, ClientUsageSource.allCases.count)
        model.cancel()
    }

    func testLeavingUsageDuringMaintenanceDoesNotStartBackgroundScan() async throws {
        let scans = ScanCounter()
        let model = client(try root(), scans: scans)
        await model.suspendForMaintenance()
        model.start()
        model.stopAutomaticRefresh()
        model.resumeAfterMaintenance()
        try await Task.sleep(for: .milliseconds(50))
        let count = await scans.count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(model.isLoading)
    }

    func testMaintenanceCoordinatorSurvivesDestinationRecreation() throws {
        let directory = try root()
        let model = client(directory, scans: ScanCounter())
        let calls = CallAnalyticsViewModel(engine: CallAnalyticsEngine(homeDirectory: directory.path, environment: [:]))
        let usage = UsageStatisticsStore(ledger: UsageLedger(url: directory.appendingPathComponent("cpa.json")))
        let coordinator = AnalyticsMaintenanceCoordinator()
        coordinator.configure(clientUsage: model, callAnalytics: calls, usage: usage,
            store: StorageMaintenanceStore(databaseURL: directory.appendingPathComponent("analytics.sqlite")), history: history(directory))
        let first = try XCTUnwrap(coordinator.service)
        // 两次配置模拟目的地销毁后重建，仍必须使用同一个 busy 状态与维护操作实例。
        coordinator.configure(clientUsage: model, callAnalytics: calls, usage: usage)
        XCTAssertTrue(first === coordinator.service)
    }

    func testFailedClientReloadStillInvalidatesOtherClearedModules() async throws {
        let directory = try root()
        let databaseURL = directory.appendingPathComponent("analytics.sqlite")
        let scans = ScanCounter()
        let engine = ClientUsageEngine(url: directory.appendingPathComponent("ledger.json"),
            homeDirectory: directory.path, environment: [:], scanOverride: { source, _ in await scans.collect(source) })
        let record = ClientUsageRecord(identity: "maintenance-fixture", source: .claude,
            timestamp: Date(), model: "fixture", input: 40, output: 2)
        _ = try await engine.merge(scans: [ClientUsageScan(source: .claude, records: [record], available: true)], at: Date())
        let model = ClientUsageViewModel(engine: engine)
        model.reloadPresentation()
        try await waitUntil { !model.buckets.isEmpty }

        let ledger = UsageLedger(url: directory.appendingPathComponent("cpa.json"))
        let batch = try JSONDecoder().decode(UsageQueueBatch.self,
            from: Data(#"[{"timestamp":"2026-09-08T01:00:00Z","model":"fixture","tokens":{"total_tokens":17}}]"#.utf8))
        _ = try await ledger.ingest(batch.records, collectedAt: Date())
        let usage = UsageStatisticsStore(ledger: ledger)
        await usage.restore()
        XCTAssertEqual(usage.totals.totalTokens, 17)

        // 故障只作用于删除提交后的日历元数据重建；删除事务本身仍成功。
        // 这比注入一个总是抛错的回调更能验证真实账本缓存不会在恢复采集后复活旧数据。
        let database = AnalyticsDatabase(url: databaseURL)
        try database.execute("""
            CREATE TRIGGER benchmark_reload_failure BEFORE INSERT ON client_usage_summary_metadata
            BEGIN SELECT RAISE(ABORT, 'fixture reload failure'); END
            """)
        let calls = CallAnalyticsViewModel(engine: CallAnalyticsEngine(homeDirectory: directory.path, environment: [:]))
        let coordinator = AnalyticsMaintenanceCoordinator()
        coordinator.configure(clientUsage: model, callAnalytics: calls, usage: usage,
            store: StorageMaintenanceStore(databaseURL: databaseURL), history: history(directory))
        let service = try XCTUnwrap(coordinator.service)
        await service.clearStatistics([.clientUsage, .dashboard])

        XCTAssertEqual(service.errorKey, "storage.data.clearedRefreshFailed")
        XCTAssertTrue(model.buckets.isEmpty, "重读失败也不能继续展示已经删除的客户端统计")
        XCTAssertNotNil(model.errorKey)
        XCTAssertTrue(usage.statisticsBuckets.isEmpty)
        XCTAssertEqual(usage.totals.totalTokens, 0)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM cpa_events"), 0)
        let afterResume = try await ledger.ingest([], collectedAt: Date())
        XCTAssertTrue(afterResume.buckets.isEmpty, "恢复后空批次不能重新发布删除前的缓存")
        model.cancel()
    }

    func testCallOnlyClearDoesNotRestoreOldSessionCalls() async throws {
        try await verifyCallReset(modules: [.callAnalytics])
    }

    func testAllModulesClearDoesNotRestoreOldSessionCalls() async throws {
        try await verifyCallReset(modules: Set(AnalyticsStorageModule.allCases))
    }

    /// 通过设置页共用的真实服务验证两种模块集合，不使用真实应用的任何统计库或会话目录。
    private func verifyCallReset(modules: Set<AnalyticsStorageModule>) async throws {
        let directory = try root()
        let databaseURL = AnalyticsDatabase.defaultURL(homeDirectory: directory.path)
        let file = directory.appendingPathComponent(".claude/projects/p/session.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        // 避免测试恰好跨 UTC 午夜时把同日验收变成不同日；测试数据只由隔离快照的水位派生。
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let zone = hour == 0 || hour == 23 ? TimeZone(secondsFromGMT: 12 * 3600)! : utc
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        func declaration(_ id: String, at date: Date) -> String {
            #"{"type":"assistant","timestamp":"\#(format.format(date))","sessionId":"same-session","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"Read"}]}}"# + "\n"
        }
        let old = now.addingTimeInterval(-60)
        let original = Data(declaration("before", at: old).utf8)
        try original.write(to: file)

        let engine = CallAnalyticsEngine(homeDirectory: directory.path, timeZone: zone, environment: [:])
        let calls = CallAnalyticsViewModel(engine: engine)
        calls.range = .all
        calls.refresh()
        try await waitUntil { !calls.isLoading && calls.report.totalCalls == 1 }
        XCTAssertEqual(calls.snapshot.agentInvocations.first?.count, 1)
        let clientUsage = ClientUsageViewModel(engine: ClientUsageEngine(databaseURL: databaseURL,
            homeDirectory: directory.path, environment: [:]))
        let usage = UsageStatisticsStore(ledger: UsageLedger(databaseURL: databaseURL))
        let quotaHistory = QuotaHistoryService(store: QuotaHistoryStore(databaseURL: databaseURL))
        let coordinator = AnalyticsMaintenanceCoordinator()
        coordinator.configure(clientUsage: clientUsage, callAnalytics: calls, usage: usage,
            store: StorageMaintenanceStore(databaseURL: databaseURL), history: quotaHistory)
        let service = try XCTUnwrap(coordinator.service)
        await service.clearStatistics(modules)
        XCTAssertNil(service.errorKey)
        XCTAssertEqual(service.messageKey, "storage.data.cleared")
        XCTAssertEqual(Set((try XCTUnwrap(service.lastClearResult)).deletedCounts.keys), modules)
        XCTAssertEqual(calls.report.totalCalls, 0)
        XCTAssertEqual(try Data(contentsOf: file), original)

        let archive = CallAnalyticsArchiveStore(homeDirectory: directory.path)
        let reset = try XCTUnwrap(archive.lastReset())
        let cutoff = reset.clearedAt
        let zero = try await engine.refresh()
        XCTAssertEqual(zero.totalCalls, 0)
        XCTAssertTrue(zero.agentInvocations.isEmpty)
        XCTAssertEqual(zero.sources.first { $0.source == .claude }?.filesScanned, 1)
        XCTAssertGreaterThanOrEqual(zero.generatedAt, cutoff)
        // 刷新更新时间和指纹，但不能推进仅由清理事务持久化的代次。
        XCTAssertEqual(try archive.lastReset(), reset)

        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let newTime = cutoff.addingTimeInterval(1)
        let lateResult = #"{"type":"user","timestamp":"\#(format.format(newTime))","sessionId":"same-session","message":{"content":[{"type":"tool_result","tool_use_id":"before"}]}}"# + "\n"
        try handle.write(contentsOf: Data(lateResult.utf8))
        let late = try await engine.refresh()
        XCTAssertEqual(late.totalCalls, 0)
        XCTAssertTrue(late.agentInvocations.isEmpty)
        try handle.write(contentsOf: Data(declaration("after", at: newTime).utf8))
        // mtime 保留为旧值，证明追加到旧会话的资格只由声明决定。
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        XCTAssertEqual(try Data(contentsOf: file).prefix(original.count), original)

        let dayClock = CallAnalyticsClock(timeZone: zone)
        XCTAssertEqual(dayClock.dayKey(old), dayClock.dayKey(newTime))
        let added = try await engine.refresh()
        XCTAssertEqual(added.totalCalls, 1)
        XCTAssertEqual(added.entries.first?.dayKey, dayClock.dayKey(old))
        XCTAssertTrue(added.agentInvocations.isEmpty, "旧会话追加工具调用不是新会话启动")
        let restarted = CallAnalyticsEngine(homeDirectory: directory.path, timeZone: zone, environment: [:])
        let cached = try await restarted.cachedSnapshot()
        XCTAssertEqual(cached.totalCalls, 1)
        // 强制重扫而不是仅命中成功指纹，验证新引擎确实读到已持久化的重置边界。
        try FileManager.default.setAttributes([.modificationDate: old.addingTimeInterval(-1)], ofItemAtPath: file.path)
        let rescanned = try await restarted.refresh()
        XCTAssertEqual(rescanned.sources.first { $0.source == .claude }?.filesScanned, 1)
        XCTAssertEqual(rescanned.totalCalls, 1)
        XCTAssertTrue(rescanned.agentInvocations.isEmpty)
        calls.cancel()
    }

    func testFreshCallPageEnteredDuringMaintenanceRefreshesAfterDataClear() async throws {
        let directory = try root()
        let model = CallAnalyticsViewModel(engine: CallAnalyticsEngine(homeDirectory: directory.path, environment: [:]))
        model.refreshIfNeeded()
        try await waitUntil { !model.isLoading && model.snapshot.generatedAt != .distantPast }
        await model.suspendForMaintenance()
        model.refreshIfNeeded()
        let storage = StorageMaintenanceStore(databaseURL: AnalyticsDatabase.defaultURL(homeDirectory: directory.path))
        _ = try await storage.clearStatistics([.callAnalytics])
        try await model.reloadAfterMaintenance()
        XCTAssertEqual(model.snapshot.generatedAt, .distantPast)
        model.resumeAfterMaintenance()
        try await waitUntil { !model.isLoading && model.snapshot.generatedAt != .distantPast }
        model.cancel()
    }

    func testManualRefreshDuringMaintenanceBypassesFreshnessWhenPageIsActive() async throws {
        let scans = ScanCounter()
        let model = client(try root(), scans: scans)
        model.start()
        try await waitUntil { !model.isLoading && model.snapshot.collectedAt != nil }
        await model.suspendForMaintenance()
        model.refresh()
        model.resumeAfterMaintenance()
        try await waitUntil {
            let count = await scans.count
            return !model.isLoading && count == ClientUsageSource.allCases.count * 2
        }
        model.cancel()
    }

    func testReplacingCalendarReloadDoesNotPublishCancellationAsFailure() async throws {
        let model = client(try root(), scans: ScanCounter())
        model.refresh()
        try await waitUntil { !model.isLoading && model.snapshot.collectedAt != nil }
        for index in 0..<20 {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: index.isMultiple(of: 2) ? 0 : 28_800)!
            model.reloadPresentation(calendar: calendar)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(model.errorKey)
        model.cancel()
    }

    func testMaintenanceDrainsConsumedResponseWithoutCancellingQueueRequest() async throws {
        let directory = try root()
        let ledger = UsageLedger(url: directory.appendingPathComponent("cpa.json"))
        let store = UsageStatisticsStore(ledger: ledger)
        let queue = GatedQueue()
        store.start(client: queue, sessionID: UUID())
        defer { store.stop() }
        try await waitUntil { await queue.started }
        var suspended = false
        let maintenance = Task {
            try await store.suspendForMaintenance()
            suspended = true
        }
        try await Task.sleep(for: .milliseconds(50))
        let cancelled = await queue.cancelled
        XCTAssertFalse(cancelled, "服务器已经消费的批次必须允许响应正常返回")
        XCTAssertFalse(suspended, "响应未入库前维护屏障不能通过")
        await queue.release()
        try await maintenance.value
        let saved = try await ledger.load()
        XCTAssertEqual(saved.totals.requests, 1)
        XCTAssertEqual(saved.totals.totalTokens, 17)
        store.resumeAfterMaintenance()
    }

    private actor ScanCounter {
        var count = 0
        func collect(_ source: ClientUsageSource) -> ClientUsageScan {
            count += 1
            return ClientUsageScan(source: source, available: true)
        }
    }

    /// 使用取消敏感的门闩模拟 URLSession：请求被取消时立即报错，能捕获错误的“先 cancel 再 drain”。
    private actor GatedQueue: UsageStatisticsClient {
        var started = false
        var cancelled = false
        private var delivered = false
        private var waiter: CheckedContinuation<UsageQueueBatch, Error>?
        func getUsageStatisticsEnabled() async throws -> Bool { true }
        func setUsageStatisticsEnabled(_ enabled: Bool) async throws { }
        func fetchUsageQueue(count: Int) async throws -> UsageQueueBatch {
            if delivered { return try JSONDecoder().decode(UsageQueueBatch.self, from: Data("[]".utf8)) }
            started = true
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { waiter = $0 }
            } onCancel: {
                Task { await self.cancelRequest() }
            }
        }
        func release() {
            delivered = true
            let batch = try! JSONDecoder().decode(UsageQueueBatch.self,
                from: Data(#"[{"timestamp":"2026-09-08T01:00:00Z","model":"fixture","tokens":{"total_tokens":17}}]"#.utf8))
            waiter?.resume(returning: batch)
            waiter = nil
        }
        private func cancelRequest() {
            cancelled = true
            waiter?.resume(throwing: CancellationError())
            waiter = nil
        }
    }
}
