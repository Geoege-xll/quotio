import AppKit
import SwiftUI
import XCTest
@testable import QuotioPlus

/// 仅使用合成队列、临时账本和内存展示模型；不启动 CPA、不读取真实账号或消费用户队列。
@MainActor
final class CPARoutingTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return result
    }
    private var now: Date { Date(timeIntervalSince1970: 1_792_000_000) }

    private func record(_ id: String, time: Date? = nil, failed: Bool = false,
                        context: CPAUsageContext = .init()) -> UsageRecord {
        UsageRecord(timestamp: time ?? now.addingTimeInterval(-10), provider: "claude", model: "model-alias",
            requestID: id, failed: failed, tokens: .init(input: 100, output: 20), context: context)
    }

    private func file(_ name: String, index: String?, email: String = "fixture@example.invalid",
                      disabled: Bool = false) throws -> AuthFile {
        var value: [String: Any] = ["name": name, "provider": "claude", "email": email, "disabled": disabled]
        if let index { value["auth_index"] = index }
        return try JSONDecoder().decode(AuthFile.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func ledger() throws -> UsageLedger {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return UsageLedger(databaseURL: directory.appendingPathComponent("routing.sqlite"), calendar: calendar)
    }

    func testV8IdentitiesArePreservedAsDigestsWithoutRawUserAgentOrKeys() throws {
        let data = Data(#"{"timestamp":"2026-10-14T01:00:00Z","provider":"claude","model":"alias","request_id":"private-request","trace_id":"private-trace","execution_id":"private-execution","auth_index":17,"api_key":"fixture-private-key-1234","source":"private@example.invalid","user_agent":"claude-cli/2.1.0 local-path-private","stream":false,"response_model":"actual-model","tokens":{"input_tokens":100}}"#.utf8)
        let record = try JSONDecoder().decode(UsageRecord.self, from: data)
        let context = try XCTUnwrap(record.context)
        XCTAssertEqual(context.authIndexID, CPAUsageContext.authIdentity("17"))
        XCTAssertEqual(context.client, "Claude Code")
        XCTAssertEqual(context.stream, false)
        XCTAssertEqual(context.responseModel, "actual-model")
        for id in [context.inboundID, context.traceID, context.executionID, context.authIndexID] {
            XCTAssertEqual(id?.count, 64)
        }
        let encoded = try JSONEncoder().encode(CPAUsageEvent(record: record))
        let text = String(decoding: encoded, as: UTF8.self)
        for secret in ["private-request", "private-trace", "private-execution", "fixture-private-key",
                       "private@example.invalid", "local-path-private", "claude-cli/"] {
            XCTAssertFalse(text.contains(secret), "原始敏感元数据不能进入持久化事件")
        }
        let reopened = try JSONDecoder().decode(CPAUsageEvent.self, from: encoded)
        XCTAssertEqual(reopened.context, context)
    }

    func testOldPersistedContextWithoutNewFieldsStillDecodes() throws {
        let event = CPAUsageEvent(record: record("old"))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        payload["context"] = ["canceled": false, "generate": true]
        let old = try JSONDecoder().decode(CPAUsageEvent.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(old.id, event.id)
        XCTAssertNil(old.context.authIndexID)
        XCTAssertNil(old.context.inboundID)
        XCTAssertNil(old.context.client)
        XCTAssertNil(old.latency)
    }

    func testIndexSelectsActualSecondAccountEvenIfFirstIsDisabled() throws {
        var context = CPAUsageContext()
        context.authIndexID = CPAUsageContext.authIdentity("b")
        let event = CPAUsageEvent(record: record("r", context: context))
        let files = [try file("first.json", index: "a", disabled: true), try file("second.json", index: "b")]
        XCTAssertEqual(CPARoutingPresentation.account(for: event, files: files)?.name, "second.json")
        XCTAssertEqual(CPARoutingPresentation.account(for: event, files: files.reversed())?.name, "second.json")
    }

    func testUnknownAuthoritativeIndexNeverFallsBackToSameEmail() throws {
        var context = CPAUsageContext()
        context.authIndexID = CPAUsageContext.authIdentity("removed-account")
        context.sourceID = CPAUsageContext.sourceIdentity("fixture@example.invalid")
        let event = CPAUsageEvent(record: record("r", context: context))
        XCTAssertNil(CPARoutingPresentation.account(for: event, files: [try file("new.json", index: "new")]))
    }

    func testSourceFallbackRequiresUniqueIdentityAndNeverProviderFirst() throws {
        let files = [try file("a.json", index: "a"), try file("b.json", index: "b")]
        var context = CPAUsageContext()
        let unknown = CPAUsageEvent(record: record("unknown", context: context))
        XCTAssertNil(CPARoutingPresentation.account(for: unknown, files: [files[0]]), "唯一账号也不能猜测")
        context.sourceID = CPAUsageContext.sourceIdentity("fixture@example.invalid")
        let ambiguous = CPAUsageEvent(record: record("ambiguous", context: context))
        XCTAssertNil(CPARoutingPresentation.account(for: ambiguous, files: files))
        XCTAssertEqual(CPARoutingPresentation.account(for: ambiguous, files: [files[1]])?.name, "b.json")
    }

    func testAccountPrivacyAndAccessKeyPrivacyUseExistingMaskingRules() throws {
        var context = CPAUsageContext()
        context.authIndexID = CPAUsageContext.authIdentity("b")
        context.apiKeyLabel = "****1234"
        context.client = "Claude Code"
        let event = CPAUsageEvent(record: record("r", context: context))
        let files = [try file("b.json", index: "b")]
        let visible = CPARoutingPresentation.accountName(for: event, files: files, hidden: false)
        let hidden = CPARoutingPresentation.accountName(for: event, files: files, hidden: true)
        XCTAssertEqual(visible, "fixture@example.invalid")
        XCTAssertEqual(hidden, visible.masked())
        XCTAssertFalse(hidden.contains("fixture"))
        XCTAssertFalse(CPARoutingPresentation.sourceName(for: event, hidden: true).contains("1234"))
    }

    func testSameKeySuffixDoesNotMergeDifferentAccessKeys() throws {
        func event(_ key: String) throws -> CPAUsageEvent {
            let raw: [String: Any] = ["timestamp": "2026-10-14T01:00:00Z", "api_key": key]
            return CPAUsageEvent(record: try JSONDecoder().decode(UsageRecord.self,
                from: JSONSerialization.data(withJSONObject: raw)))
        }
        let first = try event("fixture-first-1234"), second = try event("fixture-second-1234")
        XCTAssertEqual(first.context.apiKeyLabel, second.context.apiKeyLabel)
        XCTAssertNotEqual(CPARoutingPresentation.sourceID(for: first), CPARoutingPresentation.sourceID(for: second))
        XCTAssertNil(CPAUsageContext.clientName(userAgent: "generic-sdk/private-account"))
    }

    func testRecentActivityExpiresAndFutureOrMissingLatencyDoesNotImplyRunning() {
        let event = CPAUsageEvent(record: record("r", time: now))
        XCTAssertNil(event.latency)
        XCTAssertTrue(CPARoutingPresentation.isRecent(event, now: now.addingTimeInterval(11)))
        XCTAssertFalse(CPARoutingPresentation.isRecent(event, now: now.addingTimeInterval(12)))
        XCTAssertFalse(CPARoutingPresentation.isRecent(event, now: now.addingTimeInterval(-1)))
        XCTAssertEqual(CPARoutingPresentation.outcomeKey(event.outcome), "usage.records.outcome.success")
    }

    func testOneInboundRequestCanRetainFailureAndSuccessAsTwoExecutions() async throws {
        let ledger = try ledger()
        var context = CPAUsageContext()
        context.inboundID = "synthetic-inbound-digest"
        context.executionID = "execution-a"
        let failure = record("one-request", time: now.addingTimeInterval(-2), failed: true, context: context)
        context.executionID = "execution-b"
        let success = record("one-request", time: now.addingTimeInterval(-1), context: context)
        _ = try await ledger.ingest([failure, success], collectedAt: now)
        let result = try await ledger.routingSnapshot(now: now, calendar: calendar)
        XCTAssertEqual(result.executions, 2)
        XCTAssertEqual(result.failures, 1)
        XCTAssertEqual(result.canceled, 0, "上游失败换号成功不能被计为取消，也不能推断客户端错误")
        XCTAssertEqual(Set(result.events.compactMap(\.context.inboundID)).count, 1)
        XCTAssertEqual(Set(result.events.compactMap(\.context.executionID)).count, 2)
    }

    func testRoutingSnapshotUsesOneDayAndCountsAllRowsBeyondDisplayLimit() async throws {
        let ledger = try ledger()
        let start = calendar.startOfDay(for: now)
        var records = (0..<25).map { record("today-\($0)", time: start.addingTimeInterval(Double($0 + 1))) }
        var context = CPAUsageContext(); context.canceled = true
        records += [record("cancel", failed: true, context: context), record("fail", failed: true),
                    record("yesterday", time: start.addingTimeInterval(-1)), record("future", time: now.addingTimeInterval(1))]
        _ = try await ledger.ingest(records, collectedAt: now)
        let result = try await ledger.routingSnapshot(now: now, calendar: calendar)
        XCTAssertEqual(result.executions, 27)
        XCTAssertEqual(result.failures, 1)
        XCTAssertEqual(result.canceled, 1)
        XCTAssertEqual(result.events.count, 15)
        XCTAssertEqual(result.start, start)
        XCTAssertTrue(result.events.allSatisfy { $0.timestamp >= start && $0.timestamp <= now })
        let full = try await ledger.queryEvents(CPAUsageQuery(start: start, end: now))
        XCTAssertEqual(result.executions, full.metrics.requests)
        XCTAssertEqual(result.failures, full.metrics.failures)
        XCTAssertEqual(result.canceled, full.metrics.canceled)
        let tomorrow = try await ledger.routingSnapshot(now: start.addingTimeInterval(86401), calendar: calendar)
        XCTAssertEqual(tomorrow.executions, 0)
        XCTAssertTrue(tomorrow.events.isEmpty)
    }

    func testEmptySnapshotClearsLatestExecutionCache() async {
        let model = CPARoutingViewModel()
        var populated = CPARoutingSnapshot.empty(now: now, calendar: calendar)
        populated.events = [CPAUsageEvent(record: record("a"))]; populated.executions = 1
        await model.reload(now: now) { _ in populated }
        await model.reload(now: now) { _ in .empty(now: self.now, calendar: self.calendar) }
        XCTAssertTrue(model.snapshot.events.isEmpty)
        XCTAssertTrue(model.displayedEvents.isEmpty)
        XCTAssertEqual(model.snapshot.executions, 0)
    }

    func testBatchUpdateShowsLatestBatchReceived() async {
        let model = CPARoutingViewModel()
        var first = CPARoutingSnapshot.empty(now: now, calendar: calendar)
        first.events = [CPAUsageEvent(record: record("a"))]; first.executions = 1
        await model.reload(now: now) { _ in first }
        var second = first
        second.events = [CPAUsageEvent(record: record("b"))]; second.executions = 2
        await model.reload(now: now) { _ in second }
        XCTAssertEqual(model.displayedEvents.first?.id, second.events.first?.id)
        XCTAssertEqual(model.snapshot.executions, 2)
    }

    func testSlowOldReloadCannotOverwriteNewerRevision() async {
        let model = CPARoutingViewModel()
        var old = CPARoutingSnapshot.empty(now: now, calendar: calendar)
        old.events = [CPAUsageEvent(record: record("old"))]; old.executions = 1
        var continuation: CheckedContinuation<CPARoutingSnapshot, Never>?
        let pending = Task { await model.reload(now: now) { _ in await withCheckedContinuation { continuation = $0 } } }
        while continuation == nil { await Task.yield() }
        var newer = old; newer.events = [CPAUsageEvent(record: record("new"))]; newer.executions = 2
        await model.reload(now: now) { _ in newer }
        continuation?.resume(returning: old)
        await pending.value
        XCTAssertEqual(model.snapshot.events.first?.id, newer.events.first?.id)
        XCTAssertEqual(model.snapshot.executions, 2)
        XCTAssertFalse(model.isLoading)
    }

    func testReadFailureIsDistinctFromSuccessfulEmptyState() async {
        let model = CPARoutingViewModel()
        await model.reload(now: now) { _ in throw URLError(.cannotOpenFile) }
        XCTAssertTrue(model.hasReadError)
        XCTAssertTrue(model.snapshot.events.isEmpty)
        await model.reload(now: now) { _ in .empty(now: self.now, calendar: self.calendar) }
        XCTAssertFalse(model.hasReadError)
    }

    func testFirstRealActivityAfterEmptyLoadAndReadRecoveryDoesNotReplayHistory() async {
        let model = CPARoutingViewModel()
        await model.reload(now: now) { _ in .empty(now: self.now, calendar: self.calendar) }
        var snapshot = CPARoutingSnapshot.empty(now: now, calendar: calendar)
        snapshot.events = [CPAUsageEvent(record: record("new"))]; snapshot.executions = 1
        await model.reload(now: now) { _ in snapshot }
        XCTAssertEqual(model.latestActivityID, snapshot.events.first?.id, "首次空态后的真实执行应强调")
        await model.reload(now: now) { _ in throw URLError(.cannotOpenFile) }
        XCTAssertNil(model.latestActivityID)
        await model.reload(now: now) { _ in snapshot }
        XCTAssertNil(model.latestActivityID, "读取恢复同一历史记录不应重播分发动画")
    }

    func testSlowArrivalBehindLatestTimestampGetsFreshClockAndVisibleNodes() async {
        let model = CPARoutingViewModel()
        var snapshot = CPARoutingSnapshot.empty(now: now, calendar: calendar)
        snapshot.events = [CPAUsageEvent(record: record("recent", time: now))]; snapshot.executions = 1
        await model.reload(now: now, activityClock: { self.now }) { _ in snapshot }
        XCTAssertTrue(model.activities.isEmpty, "首次打开的历史不播放")
        var context = CPAUsageContext(); context.client = "Codex"; context.authIndexID = "slow-account-digest"
        let slow = CPAUsageEvent(record: record("slow", time: now.addingTimeInterval(-180), context: context))
        snapshot.events.append(slow); snapshot.executions = 2
        let arrival = now.addingTimeInterval(20)
        await model.reload(now: now, activityClock: { arrival }) { _ in snapshot }
        let activity = model.activities.first
        XCTAssertEqual(activity?.id, slow.id, "首条没有变化也必须识别迟到执行")
        XCTAssertEqual(activity?.receivedAt, arrival)
        XCTAssertTrue(activity?.isRecent(at: arrival, duration: CPARoutingActivity.duration) == true)
        XCTAssertEqual(model.stageEvents.first?.id, slow.id, "迟到执行对应节点应进入舞台")
        XCTAssertEqual(model.snapshot.events.first?.id, snapshot.events.first?.id, "明细排序保持不变")
        await model.reload(now: now, activityClock: { arrival.addingTimeInterval(1) }) { _ in snapshot }
        XCTAssertEqual(model.activities.first?.receivedAt, arrival, "重复刷新不能延长同一事件动画")
        XCTAssertEqual(model.activities.count, 1)
    }

    func testBusyLedgerStillPublishesSlowArrivalOutsideFifteenDisplayedRecords() async throws {
        let ledger = try ledger(), model = CPARoutingViewModel()
        let records = (0..<25).map { record("busy-\($0)", time: now.addingTimeInterval(Double($0 - 25))) }
        _ = try await ledger.ingest(records, collectedAt: now)
        let initial = try await ledger.routingSnapshot(now: now, calendar: calendar)
        await model.reload(now: now) { _ in initial }
        var context = CPAUsageContext(); context.authIndexID = "slow-account"; context.client = "Codex"
        let slow = record("late-after-busy", time: now.addingTimeInterval(-180), context: context)
        _ = try await ledger.ingest([slow], collectedAt: now.addingTimeInterval(2))
        let next = try await ledger.routingSnapshot(now: now, calendar: calendar)
        XCTAssertEqual(next.events.count, 15)
        XCTAssertEqual(next.events.map(\.id), initial.events.map(\.id), "慢请求不能改变最新 15 条列表")
        XCTAssertEqual(next.executions, 26)
        XCTAssertLessThanOrEqual(next.arrivalEvents?.count ?? 0, 30, "时间与入库候选联合仍有界")
        XCTAssertEqual(next.arrivalEvents?.first?.id, CPAUsageEvent(record: slow).id)
        await model.reload(now: now, activityClock: { self.now.addingTimeInterval(2) }) { _ in next }
        XCTAssertEqual(model.activities.map(\.id), [CPAUsageEvent(record: slow).id])
        XCTAssertEqual(model.stageEvents.first?.id, CPAUsageEvent(record: slow).id)
        await model.reload(now: now, activityClock: { self.now.addingTimeInterval(3) }) { _ in next }
        XCTAssertEqual(model.activities.count, 1, "候选重复查询不重新发布动画")
    }

    func testBurstCoalescesSameRouteAndBoundsActivityBuffer() async {
        let model = CPARoutingViewModel()
        var snapshot = CPARoutingSnapshot.empty(now: now, calendar: calendar)
        await model.reload(now: now) { _ in snapshot }
        snapshot.events = (0..<15).map { index in
            var context = CPAUsageContext(); context.apiKeyID = "source-\(index % 4)"
            context.authIndexID = "target-\(index % 4)"
            return CPAUsageEvent(record: record("burst-\(index)", context: context))
        }
        snapshot.executions = 15
        await model.reload(now: now, activityClock: { self.now }) { _ in snapshot }
        XCTAssertEqual(model.activities.count, 3, "同路径合并，每批最多三条可见光流")
        for batch in 1...3 {
            let events = (0..<15).map { index in
                var context = CPAUsageContext(); context.apiKeyID = "source-\(index)"
                context.authIndexID = "target-\(index)"
                return CPAUsageEvent(record: record("batch-\(batch)-\(index)", context: context))
            }
            snapshot.events = events; snapshot.executions += 15
            await model.reload(now: now, activityClock: { self.now.addingTimeInterval(Double(batch)) }) { _ in snapshot }
            XCTAssertLessThanOrEqual(model.activities.count, CPARoutingActivity.maximumRetained)
        }
        await model.reload(now: now, activityClock: { self.now.addingTimeInterval(20) }) { _ in snapshot }
        XCTAssertTrue(model.activities.isEmpty, "到期记录不留下无限增长的动画队列")
    }

    func testClearAndDayRolloverDoNotReplayHistoryButNextArrivalStillAnimates() async {
        let model = CPARoutingViewModel()
        var snapshot = CPARoutingSnapshot.empty(now: now, calendar: calendar)
        snapshot.events = [CPAUsageEvent(record: record("old"))]; snapshot.executions = 1
        await model.reload(now: now) { _ in snapshot }
        await model.reload(now: now) { _ in .empty(now: self.now, calendar: self.calendar) }
        XCTAssertTrue(model.activities.isEmpty); XCTAssertNil(model.latestActivityID)
        await model.reload(now: now, activityClock: { self.now }) { _ in snapshot }
        XCTAssertEqual(model.activities.count, 1, "清空后的新记录仍触发")
        let tomorrow = calendar.startOfDay(for: now).addingTimeInterval(86401)
        var nextDay = CPARoutingSnapshot.empty(now: tomorrow, calendar: calendar)
        nextDay.events = [CPAUsageEvent(record: record("next-day", time: tomorrow))]; nextDay.executions = 1
        await model.reload(now: tomorrow) { _ in nextDay }
        XCTAssertTrue(model.activities.isEmpty); XCTAssertNil(model.latestActivityID)
    }

    func testReadRecoveryKeepsDedupeBaselineAndAnimatesOnlyNewSlowArrival() async {
        let model = CPARoutingViewModel()
        var snapshot = CPARoutingSnapshot.empty(now: now, calendar: calendar)
        let old = CPAUsageEvent(record: record("old"))
        snapshot.events = [old]; snapshot.executions = 1
        await model.reload(now: now) { _ in snapshot }
        await model.reload(now: now) { _ in throw URLError(.cannotOpenFile) }
        let slow = CPAUsageEvent(record: record("slow-recovery", time: now.addingTimeInterval(-180)))
        snapshot.events.append(slow); snapshot.executions = 2
        await model.reload(now: now, activityClock: { self.now }) { _ in snapshot }
        XCTAssertEqual(model.activities.map(\.id), [slow.id])
        XCTAssertFalse(model.hasReadError)
    }

    private actor DelayedConfiguration: CPARoutingConfigurationClient {
        var continuation: CheckedContinuation<String, Never>?
        func getRoutingStrategy() async -> String { await withCheckedContinuation { continuation = $0 } }
        func getRequestRetry() -> Int { 7 }
        func isWaiting() -> Bool { continuation != nil }
        func finish() { continuation?.resume(returning: "fill-first"); continuation = nil }
    }

    func testStoppedSessionDiscardsLateConfigurationWithoutUsageRevision() async {
        let model = CPARoutingViewModel(), client = DelayedConfiguration()
        let reading = Task { await model.reloadConfiguration(client: client) }
        while !(await client.isWaiting()) { await Task.yield() }
        await model.reloadConfiguration(client: nil)
        await client.finish()
        await reading.value
        XCTAssertNil(model.routingStrategy)
        XCTAssertNil(model.retryRounds, "停止后旧客户端迟到的配置不能回灌，且不依赖用量变化")
    }

    private actor Configuration: CPARoutingConfigurationClient {
        let retry: Int
        let failed: Bool
        init(retry: Int, failed: Bool = false) { self.retry = retry; self.failed = failed }
        func getRoutingStrategy() throws -> String {
            if failed { throw URLError(.cannotConnectToHost) }
            return "weighted-round-robin"
        }
        func getRequestRetry() throws -> Int {
            if failed { throw URLError(.cannotConnectToHost) }
            return retry
        }
    }

    func testRetryReadsZeroAndActualStrategyWithoutInventedDefaults() async {
        let model = CPARoutingViewModel()
        await model.reloadConfiguration(client: Configuration(retry: 0))
        XCTAssertEqual(model.retryRounds, 0)
        XCTAssertEqual(model.routingStrategy, "weighted-round-robin")
        await model.reloadConfiguration(client: Configuration(retry: 2))
        XCTAssertEqual(model.retryRounds, 2)
        await model.reloadConfiguration(client: Configuration(retry: 3, failed: true))
        XCTAssertNil(model.retryRounds); XCTAssertNil(model.routingStrategy)
        await model.reloadConfiguration(client: nil)
        XCTAssertNil(model.retryRounds); XCTAssertNil(model.routingStrategy)
    }
    /// 隐私切换必须只影响展示；原始事件与认证目录不能被组件挂载或重绘改变。
    func testShowingRoutingCardsAndChangingPrivacyPreservesEventsAndAccounts() async throws {
        let suite = "routing-display-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = MenuBarSettingsManager(defaults: defaults)
        let vm = QuotaViewModel(startsBackgroundServices: false)
        vm.authFiles = [try file("fixture.json", index: "a")]
        let routing = CPARoutingViewModel()
        var snapshot = CPARoutingSnapshot.empty(now: now)
        snapshot.events = [CPAUsageEvent(record: record("fixture"))]
        snapshot.executions = 1
        await routing.reload { _ in snapshot }
        let expectedEvents = routing.snapshot.events, expectedAccounts = vm.authFiles
        let root = ScrollView { RoutingCenterCards(settings: settings).padding(20) }
            .environment(vm).environment(routing)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 780)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for hidden in [false, true] {
            settings.hideSensitiveInfo = hidden
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(routing.snapshot.events, expectedEvents)
            XCTAssertEqual(vm.authFiles, expectedAccounts)
        }
    }

}
