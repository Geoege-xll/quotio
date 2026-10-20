import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import QuotioPlus

/// 只用临时数据库、隔离偏好及人工额度观测，不访问用户凭据或连接真实提供商。
/// 覆盖历史的身份、数值、清理水位和维护世代，图表快照不替代这些业务边界断言。
@MainActor
final class QuotaHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quota-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("analytics.sqlite")
    }

    private func defaults() throws -> UserDefaults {
        let name = "quota-history-" + UUID().uuidString
        let value = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { value.removePersistentDomain(forName: name) }
        return value
    }

    private func account(_ key: String = "exact-key", mode: String = "local") -> QuotaHistoryAccount {
        QuotaHistoryAccount(mode: mode, provider: .claude, accountKey: key)
    }

    private func point(_ value: Double, date: Date, basis: String = "same-plan",
                       reset: Date? = nil, window: TimeInterval? = nil) -> QuotaHistoryPoint {
        QuotaHistoryPoint(metricID: "fixture", metricName: "Fixture", date: date, value: value,
            kind: .percentage, unit: nil, direction: .decreasing, basis: basis,
            resetAt: reset, windowSeconds: window)
    }

    func testLegacyQuotaDecodesAndUnknownOrStatusNeverBecomeZero() throws {
        let old = try JSONDecoder().decode(ModelQuota.self,
            from: Data(#"{"name":"old","percentage":55,"resetTime":""}"#.utf8))
        XCTAssertNil(old.windowSeconds)
        let quota = ProviderQuotaData(lastUpdated: now)
        XCTAssertEqual(QuotaHistoryPoint.make(model: old, quota: quota)?.value, 55)
        XCTAssertNil(QuotaHistoryPoint.make(model: ModelQuota(name: "unknown", percentage: -1, resetTime: ""), quota: quota))
        XCTAssertNil(QuotaHistoryPoint.make(model: ModelQuota(name: "status", percentage: 0, resetTime: "",
            presentation: .status(text: "unknown")), quota: quota))
        let balance = ModelQuota(name: "balance", percentage: -1, resetTime: "",
            presentation: .amount(value: 12.5, unit: .usd, semantics: .balance))
        XCTAssertEqual(QuotaHistoryPoint.make(model: balance, quota: quota)?.value, 12.5)
        XCTAssertEqual(QuotaHistoryPoint.make(model: balance, quota: quota)?.kind, .amount)
    }

    func testVMIdentityRekeyDoesNotCreateHistoryInNewMode() async throws {
        let preferences = try defaults(), store = QuotaHistoryStore(databaseURL: try location())
        preferences.set(OperatingMode.monitor.rawValue, forKey: "operatingMode")
        let mode = OperatingModeManager(defaults: preferences)
        let vm = QuotaViewModel(startsBackgroundServices: false, modeManager: mode,
            menuBarSettings: MenuBarSettingsManager(defaults: preferences))
        vm.customProvidersForTesting = []
        let service = QuotaHistoryService(store: store, defaults: preferences)
        let token = NotificationCenter.default.addObserver(forName: QuotaHistoryPublication.notification,
            object: vm, queue: nil) { notification in
            guard let value = notification.userInfo?["publication"] as? QuotaHistoryPublication else { return }
            MainActor.assumeIsolated { service.submit(mode: value.mode, quotas: value.current, previous: value.previous) }
        }
        let running = vm.proxyManager.proxyStatus.running, session = vm.proxyManager.runtimeSessionID
        defer {
            NotificationCenter.default.removeObserver(token)
            vm.proxyManager.setRuntimeStateForTesting(running: running, sessionID: session)
        }
        let date = Date().addingTimeInterval(-10), email = "history-fixture@example.invalid"
        let old = ProviderQuotaData(models: [ModelQuota(name: "session", percentage: 55, resetTime: "")], lastUpdated: date)
        vm.providerQuotas = [.claude: [email: old]]
        await service.waitForWrites()
        mode.setMode(.localProxy)
        vm.proxyManager.setRuntimeStateForTesting(running: true, sessionID: UUID())
        let file = try JSONDecoder().decode(AuthFile.self, from: Data("{\"name\":\"claude-fixture.json\",\"provider\":\"claude\",\"email\":\"\(email)\",\"auth_index\":\"fixture\"}".utf8))
        vm.authFiles = [file]
        vm.reconcileAccountQuotaIdentities()
        XCTAssertNotNil(vm.providerQuotas[.claude]?[file.quotaLookupKey])
        await service.waitForWrites()
        let proxy = QuotaHistoryAccount(mode: OperatingMode.localProxy.rawValue, provider: .claude, accountKey: file.quotaLookupKey)
        let moved = try await service.metrics(account: proxy)
        XCTAssertTrue(moved.isEmpty, "纯重键不能把 monitor 观测复制到 localProxy 历史")

        var fresh = old
        fresh.lastUpdated = date.addingTimeInterval(1)
        vm.providerQuotas[.claude]?[file.quotaLookupKey] = fresh
        await service.waitForWrites()
        let recorded = try await service.metrics(account: proxy)
        XCTAssertEqual(recorded.first?.value, 55, "真正的新源时间仍记录")
        let independent = QuotaHistoryPublication(mode: "fixture", current: [.claude: ["one": fresh, "two": fresh]], previous: [:])
        service.submit(mode: independent.mode, quotas: independent.current, previous: independent.previous)
        await service.waitForWrites()
        for key in ["one", "two"] {
            let values = try await service.metrics(account: QuotaHistoryAccount(mode: "fixture", provider: .claude, accountKey: key))
            XCTAssertEqual(values.count, 1, "无别名关系的同值账号不能去重")
        }
        var laterAlias = fresh
        laterAlias.lastUpdated = date.addingTimeInterval(2)
        let exactFirst = QuotaHistoryPublication(mode: "fixture", current: [.claude: ["canonical": fresh]],
            previous: [.claude: ["canonical": old, "alias": laterAlias]], aliases: [.claude: ["alias": "canonical"]])
        XCTAssertEqual(exactFirst.previous[.claude]?["canonical"]?.lastUpdated, old.lastUpdated,
            "精确键已有基线时，不能让较新的别名阻挡它的真实新观测")
    }

    func testPaceTimelineContainsFreshnessAndResetDeadlinesWithoutPolling() throws {
        let reset = now.addingTimeInterval(1)
        let current = point(50, date: now.addingTimeInterval(-1799), reset: reset, window: 3600)
        var entries = QuotaPaceTimelineSchedule(points: [current]).entries(from: now, mode: .normal)
        XCTAssertEqual(entries.next(), now)
        XCTAssertEqual(entries.next(), reset)
        XCTAssertEqual(entries.next(), current.date.addingTimeInterval(1800.01))
        XCTAssertNotNil(QuotaPace(point: current, now: now))
        XCTAssertNil(QuotaPace(point: current, now: reset), "重置到期立即取消预测")
    }

    func testOnlyExplicitProviderWindowsEnablePace() throws {
        let claude = try ClaudeQuotaMapper.map(data: Data(#"{"five_hour":{"utilization":20},"seven_day":{"utilization":30}}"#.utf8))
        XCTAssertEqual(claude.models.map(\.windowSeconds), [5 * 3600, 7 * 86_400])
        let codex = try CodexUsageMapper.map(data: Data(#"{"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000},"secondary_window":{"used_percent":30}}}"#.utf8))
        XCTAssertEqual(codex.models.first?.windowSeconds, 18_000)
        XCTAssertNil(codex.models.last?.windowSeconds)
        let reset = now.addingTimeInterval(3600)
        XCTAssertNil(QuotaPace(point: point(50, date: now, reset: reset), now: now))
        let pace = try XCTUnwrap(QuotaPace(point: point(20, date: now, reset: reset, window: 5 * 3600), now: now))
        XCTAssertEqual(pace.expectedRemaining, 20, accuracy: 0.001)
        XCTAssertEqual(pace.projectedEmpty, reset)
        XCTAssertNil(QuotaPace(point: point(20, date: now.addingTimeInterval(-1900), reset: reset, window: 5 * 3600), now: now))
    }

    func testCodexRelativeResetDoesNotSplitHistoryOrEnableExactForecast() throws {
        let quota = try CodexUsageMapper.map(data: Data(#"{"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000,"reset_after_seconds":3600}}}"#.utf8), updatedAt: now)
        let mapped = try XCTUnwrap(quota.models.first)
        XCTAssertEqual(mapped.resetTimeIsEstimated, true)
        XCTAssertFalse(mapped.resetTime.isEmpty) // 原倒计时展示仍然保留。
        let formatter = ISO8601DateFormatter()
        let first = ModelQuota(name: mapped.name, percentage: 80,
            resetTime: formatter.string(from: now.addingTimeInterval(3600)),
            windowSeconds: mapped.windowSeconds, resetTimeIsEstimated: mapped.resetTimeIsEstimated)
        let later = ModelQuota(name: mapped.name, percentage: 79,
            resetTime: formatter.string(from: now.addingTimeInterval(3601)),
            windowSeconds: mapped.windowSeconds, resetTimeIsEstimated: mapped.resetTimeIsEstimated)
        let a = try XCTUnwrap(QuotaHistoryPoint.make(model: first, quota: quota))
        let b = try XCTUnwrap(QuotaHistoryPoint.make(model: later, quota: quota))
        XCTAssertEqual(a.basis, b.basis)
        XCTAssertNil(a.windowSeconds)
        XCTAssertNil(QuotaPace(point: a, now: now))
        XCTAssertNil(QuotaHistoryPoint.usedPerDay([a, b], now: now))
        let oldCycle = point(80, date: now.addingTimeInterval(-600), basis: "relative-reset", reset: now.addingTimeInterval(-300))
        let nextCycle = point(70, date: now, basis: "relative-reset", reset: now.addingTimeInterval(18_000 - 300))
        let chart = QuotaHistoryChartPoint.sample([oldCycle, nextCycle], range: .day, now: now)
        XCTAssertNotEqual(chart.first?.segment, chart.last?.segment)
    }

    func testDailyRateKeepsRechargeConsumptionAndDoesNotBridgeChangedPlan() {
        let samples = [point(100, date: now.addingTimeInterval(-2 * 86_400)),
                       point(70, date: now.addingTimeInterval(-86_400)),
                       point(90, date: now.addingTimeInterval(-3600)), point(80, date: now)]
        XCTAssertEqual(QuotaHistoryPoint.usedPerDay(samples, now: now), 20)
        var changed = samples
        changed[2] = point(90, date: samples[2].date, basis: "other-plan")
        XCTAssertNil(QuotaHistoryPoint.usedPerDay(changed, now: now))
        XCTAssertNil(QuotaHistoryPoint.usedPerDay([samples[3]], now: now))
    }

    func testChartKeepsRightEndpointAndRechargeBreakInsideOneBucket() throws {
        // 三十天抽样桶为一小时；同桶内的充值必须带入段标识，不能连成持续消耗线。
        let samples = [point(90, date: now.addingTimeInterval(-7200)),
                       point(20, date: now.addingTimeInterval(-120)),
                       point(80, date: now.addingTimeInterval(-60)), point(70, date: now)]
        let chart = QuotaHistoryChartPoint.sample(samples, range: .month, now: now)
        XCTAssertEqual(chart.last?.point.date, now)
        XCTAssertNotEqual(chart.first?.segment, chart.last?.segment)
        let dense = (0...1440).map { point(50, date: now.addingTimeInterval(Double($0 - 1440) * 60)) }
        let bounded = QuotaHistoryChartPoint.sample(dense, range: .day, now: now)
        XCTAssertLessThanOrEqual(bounded.count, 720)
        XCTAssertEqual(bounded.last?.point.date, now)
    }

    func testStoreDeduplicatesSourceTimeAndSeparatesModeAndExactAccount() async throws {
        let store = QuotaHistoryStore(databaseURL: try location())
        let date = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        let old = QuotaHistorySample(account: account(), point: point(80, date: date))
        let newer = QuotaHistorySample(account: account(), point: point(70, date: date.addingTimeInterval(1)))
        _ = try await store.record([old, newer, old,
            QuotaHistorySample(account: account(mode: "monitor"), point: point(20, date: date)),
            QuotaHistorySample(account: account("another-key"), point: point(30, date: date))], generation: 0, now: date.addingTimeInterval(5))
        let local = try await store.metrics(account: account(), now: date.addingTimeInterval(5))
        let monitor = try await store.metrics(account: account(mode: "monitor"), now: date.addingTimeInterval(5))
        let another = try await store.metrics(account: account("another-key"), now: date.addingTimeInterval(5))
        XCTAssertEqual(local.map(\.value), [70]); XCTAssertEqual(monitor.map(\.value), [20]); XCTAssertEqual(another.map(\.value), [30])
        let unchanged = try await store.record([old], generation: 0, now: date.addingTimeInterval(5))
        XCTAssertFalse(unchanged)
    }

    func testClearRejectsLateGenerationAndFutureToleranceReplay() async throws {
        let store = QuotaHistoryStore(databaseURL: try location())
        let future = QuotaHistorySample(account: account(), point: point(40, date: now.addingTimeInterval(30)))
        _ = try await store.record([future], generation: 0, now: now)
        await store.advanceGeneration(to: 1)
        try await store.clear(account: account(), generation: 1, now: now)
        let oldGeneration = try await store.record([future], generation: 0, now: now)
        let replay = try await store.record([future], generation: 1, now: now)
        XCTAssertFalse(oldGeneration); XCTAssertFalse(replay)
        let fresh = QuotaHistorySample(account: account(), point: point(35, date: now.addingTimeInterval(61)))
        let saved = try await store.record([fresh], generation: 1, now: now.addingTimeInterval(61))
        XCTAssertTrue(saved)
    }

    func testFullMinuteHistoryRateIsIndependentOfChartSampling() async throws {
        let store = QuotaHistoryStore(databaseURL: try location())
        let samples = [point(100, date: now.addingTimeInterval(-2 * 86_400)),
                       point(70, date: now.addingTimeInterval(-120)),
                       point(90, date: now.addingTimeInterval(-60)), point(80, date: now)]
        _ = try await store.record(samples.map { QuotaHistorySample(account: account(), point: $0) }, generation: 0, now: now)
        let rates = try await store.dailyRates(account: account(), now: now)
        XCTAssertEqual(rates["fixture"]?.value, 20)
        let chart = try await store.points(account: account(), metricID: "fixture", range: .month, now: now)
        XCTAssertLessThan(chart.count, samples.count)
        XCTAssertEqual(chart.last?.point.date, now)
    }

    func testRecordingPauseAndMaintenanceKeepCurrentQuotaUnchanged() async throws {
        let store = QuotaHistoryStore(databaseURL: try location())
        let preferences = try defaults()
        let service = QuotaHistoryService(store: store, defaults: preferences)
        let value = ProviderQuotaData(models: [ModelQuota(name: "fixture", percentage: 55, resetTime: "")])
        service.submit(mode: "local", quotas: [.claude: ["exact-key": value]], previous: [:])
        await service.waitForWrites()
        let initial = try await service.metrics(account: account())
        XCTAssertEqual(initial.map(\.value), [55])
        await service.setRecordingEnabled(false)
        await service.suspendForMaintenance()
        service.submit(mode: "local", quotas: [.claude: ["new": value]], previous: [:])
        await service.waitForWrites()
        service.resumeAfterMaintenance()
        let ignored = try await service.metrics(account: account("new"))
        XCTAssertTrue(ignored.isEmpty)
        XCTAssertEqual(value.models.first?.percentage, 55)
        XCTAssertFalse(service.recordingEnabled)
        XCTAssertFalse(try XCTUnwrap(preferences.object(forKey: "quotaHistoryRecordingEnabled") as? Bool))
    }

    func testStorageMaintenanceClearsOnlyHistoryAndPreservesReplayWatermark() async throws {
        let url = try location(), store = QuotaHistoryStore(databaseURL: url)
        let date = Date().addingTimeInterval(30)
        let sample = QuotaHistorySample(account: account(), point: point(55, date: date))
        _ = try await store.record([sample], generation: 0)
        let database = AnalyticsDatabase(url: url)
        try database.execute("CREATE TABLE unrelated_configuration(id INTEGER)")
        try database.execute("INSERT INTO unrelated_configuration VALUES(1)")
        let result = try await StorageMaintenanceStore(databaseURL: url).clearStatistics([.quotaHistory])
        XCTAssertEqual(result.deletedCounts[.quotaHistory], 1)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM unrelated_configuration"), 1)
        let replay = try await store.record([sample], generation: 0)
        XCTAssertFalse(replay)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM quota_history_meta WHERE key='cleared.all'"), 1)
    }

    func testSingleAccountClearKeepsOtherQueuedSamplesAndScreenReadsHistory() async throws {
        let store = QuotaHistoryStore(databaseURL: try location())
        let service = QuotaHistoryService(store: store, defaults: try defaults())
        let value = ProviderQuotaData(models: [ModelQuota(name: "fixture", percentage: 55, resetTime: "")])
        service.submit(mode: "local", quotas: [.claude: ["exact-key": value, "kept-key": value]], previous: [:])
        try await service.clear(account: account())
        let cleared = try await service.metrics(account: account())
        let kept = try await service.metrics(account: account("kept-key"))
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertEqual(kept.map(\.value), [55])
        let screen = QuotaHistoryScreenModel(service: service)
        await screen.load(account: account("kept-key"), metricID: nil, range: .week)
        XCTAssertEqual(screen.selectedMetricID, "fixture")
        XCTAssertEqual(screen.points.last?.point.value, 55)
        XCTAssertNil(screen.errorKey)
    }

    func testStorePrunesExpiredAndExcessSamples() async throws {
        let url = try location(), store = QuotaHistoryStore(databaseURL: url)
        _ = try await store.record([QuotaHistorySample(account: account(), point: point(50, date: now))], generation: 0, now: now)
        let database = AnalyticsDatabase(url: url)
        // 直接建立大量历史夹具，不反复经过服务／主线程；随后触发真实生产 prune 事务。
        let payload = try JSONEncoder().encode(point(50, date: now))
        try database.execute("""
            WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<100001)
            INSERT INTO quota_history_samples(mode,provider,account_key,metric_id,bucket,observed_at,payload)
            SELECT 'local','claude','bulk-'||n,'fixture',0,?,? FROM seq
            """, [.real(now.timeIntervalSince1970 - 60), .blob(payload)])
        _ = try await store.record([QuotaHistorySample(account: account(), point: point(49, date: now.addingTimeInterval(60)))], generation: 0, now: now.addingTimeInterval(60))
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM quota_history_samples"), Int64(QuotaHistoryStore.maximumSamples))
        _ = try await store.record([QuotaHistorySample(account: account(), point: point(48, date: now.addingTimeInterval(31 * 86_400)))], generation: 0, now: now.addingTimeInterval(31 * 86_400))
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM quota_history_samples"), 1)
    }
}
