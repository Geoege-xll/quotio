import AppKit
import Observation
import SwiftUI
import XCTest
@testable import QuotioPlus

/// 只验证本次问题：真实舞台在 A→B→A 交替采集时，账号卡片的坐标保持不变，
/// 生产光流绘制器按执行账号命中不同曲线。全部使用离线夹具，不启动或操作 CPA。
@MainActor
final class RoutingAccountPositionTests: XCTestCase {
    func testAlternatingAccountsKeepActualAnchorsAndMatchOutboundAndReturnLines() async throws {
        let routing = CPARoutingViewModel(), vm = QuotaViewModel(startsBackgroundServices: false)
        let suite = "routing-account-position-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = MenuBarSettingsManager(defaults: defaults)
        vm.authFiles = try JSONDecoder().decode([AuthFile].self, from: Data(#"[{"name":"a.json","provider":"antigravity","email":"a@example.invalid","auth_index":"account-a"},{"name":"b.json","provider":"antigravity","email":"b@example.invalid","auth_index":"account-b"}]"#.utf8))
        let clock = Date()
        func event(_ account: String, sequence: Int) -> CPAUsageEvent {
            var context = CPAUsageContext()
            context.client = "Claude Code"; context.apiKeyID = "fixture-source-digest"
            context.authIndexID = CPAUsageContext.authIdentity(account)
            return CPAUsageEvent(record: UsageRecord(timestamp: clock.addingTimeInterval(Double(sequence) - 20),
                provider: "antigravity", model: "fixture-model", requestID: "fixture-\(sequence)",
                context: context))
        }
        let initialA = event("account-a", sequence: -2), initialB = event("account-b", sequence: -1)
        let targetA = CPARoutingPresentation.targetID(for: initialA)
        let targetB = CPARoutingPresentation.targetID(for: initialB)
        var snapshot = CPARoutingSnapshot.empty(now: clock)
        snapshot.events = [initialB, initialA]; snapshot.executions = 2
        await routing.reload(now: clock) { _ in snapshot }

        let measurement = AccountPositionMeasurement()
        let root = MeasuredAccountStage(settings: settings, measurement: measurement)
            .environment(vm).environment(routing)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: 740, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let firstA = try XCTUnwrap(measurement.bounds[.target(targetA)])
        let firstB = try XCTUnwrap(measurement.bounds[.target(targetB)])
        XCTAssertNotEqual(firstA.midY, firstB.midY, "两个真实账号必须有不同的物理连线端点")
        let identities = [targetA, targetB].sorted()
        XCTAssertLessThan(try XCTUnwrap(measurement.bounds[.target(identities[0])]).midY,
                          try XCTUnwrap(measurement.bounds[.target(identities[1])]).midY)

        // 使用真实舞台的偏好锚点，不能像旧测试那样直接给账号 A、B 手工固定坐标。
        // 三次更新保留已有时间列表顺序及采集活动生成逻辑，只有目标布局顺序稳定。
        for (sequence, account) in ["account-a", "account-b", "account-a"].enumerated() {
            let newest = event(account, sequence: sequence)
            snapshot.events.insert(newest, at: 0); snapshot.executions += 1
            let arrival = clock.addingTimeInterval(Double(sequence) * 3)
            await routing.reload(now: clock, activityClock: { arrival }) { _ in snapshot }
            try await Task.sleep(for: .milliseconds(70))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(measurement.bounds[.target(targetA)], firstA, "账号 A 不能被最新活动搬行")
            XCTAssertEqual(measurement.bounds[.target(targetB)], firstB, "账号 B 不能被最新活动搬行")
            let activity = try XCTUnwrap(routing.activities.first)
            let expectedID = CPARoutingPresentation.targetID(for: newest)
            XCTAssertEqual(activity.targetID, expectedID)
            let geometry = RoutingFlowGeometry(anchors: measurement.bounds)
            let curve = try XCTUnwrap(geometry.target(activity.targetID))
            let accountBounds = try XCTUnwrap(measurement.bounds[.target(expectedID)])
            XCTAssertEqual(curve.end, CGPoint(x: accountBounds.minX - 2, y: accountBounds.midY))
            XCTAssertEqual(routing.snapshot.events.first?.id, newest.id, "明细仍按执行时间展示最新记录")

            measurement.drawFlow = false
            try await Task.sleep(for: .milliseconds(50))
            let baseline = try capture(host)
            // 对两个方向分别检查目标连线的实际光点像素，旧版“总走顶行”会在 B 到达时
            // 先被坐标断言捕获；硬编码错账号的绘制也无法满足对应光点位置断言。
            for (_, age) in [("outbound", 1.1), ("return", 1.3)] {
                measurement.date = arrival.addingTimeInterval(age)
                measurement.drawFlow = true
                try await Task.sleep(for: .milliseconds(60))
                let frame = try capture(host)
                let sample = try XCTUnwrap(RoutingFlowSample.at(age: age))
                assertLight(frame, baseline: baseline, point: curve.point(at: sample.headParameter))
            }
        }
    }

    private func capture(_ host: NSView) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func assertLight(_ frame: NSBitmapImageRep, baseline: NSBitmapImageRep, point: CGPoint,
                             file: StaticString = #filePath, line: UInt = #line) {
        let scale = CGFloat(frame.pixelsWide) / 740
        let px = Int(point.x * scale), py = Int(point.y * scale), radius = Int(ceil(4 * scale))
        var difference = 0.0
        for x in max(0, px - radius)...min(frame.pixelsWide - 1, px + radius) {
            for y in max(0, py - radius)...min(frame.pixelsHigh - 1, py + radius) {
                guard let a = frame.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = baseline.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                difference = max(difference, abs(a.redComponent - b.redComponent)
                    + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent))
            }
        }
        XCTAssertGreaterThan(difference, 0.15, "光流应出现在实际执行账号的曲线上", file: file, line: line)
    }
}

@MainActor @Observable
private final class AccountPositionMeasurement {
    var bounds: [RoutingNodeAnchor: CGRect] = [:]
    var date = Date()
    var drawFlow = false
}

private struct MeasuredAccountStage: View {
    let settings: MenuBarSettingsManager
    let measurement: AccountPositionMeasurement
    @Environment(CPARoutingViewModel.self) private var routing

    var body: some View {
        RoutingStageView(settings: settings)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlayPreferenceValue(RoutingNodeAnchorPreference.self) { anchors in
                GeometryReader { canvas in
                    let bounds = anchors.mapValues { canvas[$0] }
                    // 离线模型不启动 CPA；这里仅用真实舞台的坐标采样生产绘制器。
                    // 显式帧时间让去程／回程检查可重复，不依赖实时请求或计时器调度。
                    RoutingFlowFrame(geometry: RoutingFlowGeometry(anchors: bounds),
                        activities: routing.activities, date: measurement.date,
                        isEnabled: measurement.drawFlow, reduceMotion: false)
                        .onChange(of: bounds, initial: true) { measurement.bounds = bounds }
                }
            }
    }
}
