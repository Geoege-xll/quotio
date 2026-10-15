import AppKit
import Observation
import SwiftUI
import XCTest
@testable import QuotioPlus

/// 直接验证生产曲线、生产 Canvas 中途帧和生产 TimelineView，不只验证活动 ID。
/// 所有事件及账号为合成夹具，不启动 CPA、不读取用户账本或认证文件。
@MainActor
final class RoutingFlowAnimationTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_792_000_000)

    private func activity(at date: Date, outcome: CPAUsageOutcome = .success,
                          index: Int = 0) -> CPARoutingActivity {
        var context = CPAUsageContext()
        context.apiKeyID = "source-\(index)"; context.authIndexID = "target-\(index)"
        context.canceled = outcome == .canceled
        let record = UsageRecord(timestamp: date.addingTimeInterval(-180), provider: "claude",
                                 model: "fixture-model", requestID: "fixture-\(index)",
                                 failed: outcome != .success, context: context)
        return CPARoutingActivity(event: CPAUsageEvent(record: record), receivedAt: date)
    }

    private func geometry(for activities: [CPARoutingActivity], width: CGFloat = 640) -> RoutingFlowGeometry {
        var anchors: [RoutingNodeAnchor: CGRect] = [.hub: CGRect(x: width / 2 - 19, y: 60, width: 38, height: 38)]
        for (index, activity) in activities.enumerated() {
            anchors[.source(activity.sourceID)] = CGRect(x: 10, y: 20 + index * 50, width: 170, height: 32)
            anchors[.target(activity.targetID)] = CGRect(x: width - 180, y: 20 + CGFloat(index) * 50, width: 170, height: 32)
        }
        return RoutingFlowGeometry(anchors: anchors)
    }

    func testCurvesConnectEachRealRowEdgeAndHubIconAfterResize() throws {
        let activities = (0..<3).map { activity(at: instant, index: $0) }
        for width: CGFloat in [580, 840] {
            let geometry = geometry(for: activities, width: width)
            XCTAssertEqual(geometry.allCurves.count, 6)
            for (index, activity) in activities.enumerated() {
                let source = try XCTUnwrap(geometry.source(activity.sourceID))
                let target = try XCTUnwrap(geometry.target(activity.targetID))
                XCTAssertEqual(source.start, CGPoint(x: 182, y: 36 + index * 50))
                XCTAssertEqual(source.end, CGPoint(x: width / 2 - 21, y: 79))
                XCTAssertEqual(target.start, CGPoint(x: width / 2 + 21, y: 79))
                XCTAssertEqual(target.end, CGPoint(x: width - 182, y: 36 + CGFloat(index) * 50))
                XCTAssertEqual(source.point(at: 0), source.start)
                XCTAssertEqual(target.point(at: 1), target.end)
            }
            XCTAssertNil(geometry.target("unknown"), "缺失身份不能连到别的账号")
        }
    }

    func testIntermediateSamplesAreVisibleAndMoveInBothDirections() throws {
        let a = activity(at: instant), geometry = geometry(for: [a])
        let source = try XCTUnwrap(geometry.source(a.sourceID)), target = try XCTUnwrap(geometry.target(a.targetID))
        func point(_ age: Double) throws -> CGPoint {
            let sample = try XCTUnwrap(RoutingFlowSample.at(age: age))
            XCTAssertGreaterThan(sample.opacity, 0)
            return (sample.leg == .source ? source : target).point(at: sample.headParameter)
        }
        XCTAssertLessThan(try point(0.1).x, try point(0.4).x)
        XCTAssertLessThan(try point(0.8).x, try point(1.1).x)
        XCTAssertGreaterThan(try point(1.3).x, try point(1.7).x, "上游回程必须向左输送")
        XCTAssertGreaterThan(try point(1.7).x, target.start.x, "回程止于中枢，不冒充客户端结果")
        XCTAssertNil(RoutingFlowSample.at(age: -1))
        XCTAssertNil(RoutingFlowSample.at(age: 1.8))
    }

    func testFrameClockStopsAtExpiryWhenStoppedHiddenOrReduced() {
        let activities = [activity(at: instant)]
        func enabled(_ age: Double, running: Bool = true, reduced: Bool = false) -> Bool {
            RoutingFlowConnections.shouldAnimate(activities: activities, date: instant.addingTimeInterval(age),
                                                  isEnabled: running, reduceMotion: reduced)
        }
        XCTAssertTrue(enabled(0.2)); XCTAssertTrue(enabled(1.7))
        XCTAssertFalse(enabled(1.8)); XCTAssertFalse(enabled(-1))
        XCTAssertFalse(enabled(0.2, running: false)); XCTAssertFalse(enabled(0.2, reduced: true))
        XCTAssertFalse(RoutingFlowConnections.shouldAnimate(activities: [], date: instant,
                                                            isEnabled: true, reduceMotion: false))
    }

    private func open<V: View>(_ root: V, width: CGFloat = 640) -> (NSHostingView<V>, NSWindow) {
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(x: 0, y: 0, width: width, height: 180)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        return (host, window)
    }

    private func capture<V: View>(_ host: NSHostingView<V>) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    /// 在理论光点附近比较活动帧与基线像素，避免“截图不同”被文字、窗口或背景变化
    /// 假满足。支持 Retina 像素比例，Canvas 的坐标从左上角测量。
    private func assertVisible(_ frame: NSBitmapImageRep, baseline: NSBitmapImageRep,
                               point: CGPoint, width: CGFloat = 640,
                               file: StaticString = #filePath, line: UInt = #line) {
        let scale = CGFloat(frame.pixelsWide) / width
        let px = Int(point.x * scale), py = Int(point.y * scale)
        var difference = 0.0
        for x in max(0, px - 5)...min(frame.pixelsWide - 1, px + 5) {
            for y in max(0, py - 5)...min(frame.pixelsHigh - 1, py + 5) {
                guard let a = frame.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = baseline.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                difference = max(difference, abs(a.redComponent - b.redComponent)
                                 + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent))
            }
        }
        XCTAssertGreaterThan(difference, 0.15, "中途帧的实际光点必须可见", file: file, line: line)
    }

    func testProductionCanvasRendersVisibleOutboundAndReturnFramesLightAndDark() async throws {
        let activity = activity(at: instant), geometry = geometry(for: [activity])
        for scheme in [ColorScheme.light, .dark] {
            let background = scheme == .light ? Color.white : Color.black
            let root = RoutingFlowFrame(geometry: geometry, activities: [activity], date: instant,
                                        isEnabled: false, reduceMotion: false)
                .background(background).environment(\.colorScheme, scheme)
            let (host, window) = open(root)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(80))
            let baseline = try capture(host)
            for age in [0.18, 0.42, 0.86, 1.08, 1.35, 1.62] {
                host.rootView = RoutingFlowFrame(geometry: geometry, activities: [activity],
                    date: instant.addingTimeInterval(age), isEnabled: true, reduceMotion: false)
                    .background(background).environment(\.colorScheme, scheme)
                try await Task.sleep(for: .milliseconds(60))
                let frame = try capture(host)
                let sample = try XCTUnwrap(RoutingFlowSample.at(age: age))
                let curve = try XCTUnwrap(sample.leg == .source ? geometry.source(activity.sourceID) : geometry.target(activity.targetID))
                assertVisible(frame, baseline: baseline, point: curve.point(at: sample.headParameter))
            }
        }
    }

    func testReducedMotionAndStoppedFramesRemainStatic() async throws {
        let a = activity(at: instant), geometry = geometry(for: [a])
        for enabled in [true, false] {
            let frame = RoutingFlowFrame(geometry: geometry, activities: [a], date: instant.addingTimeInterval(0.2),
                                         isEnabled: enabled, reduceMotion: true).background(Color.white)
            let (host, window) = open(frame)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(60))
            let first = try capture(host)
            host.rootView = RoutingFlowFrame(geometry: geometry, activities: [a], date: instant.addingTimeInterval(1.0),
                                             isEnabled: enabled, reduceMotion: true).background(Color.white)
            try await Task.sleep(for: .milliseconds(60))
            let second = try capture(host)
            XCTAssertEqual(first.representation(using: .png, properties: [:]), second.representation(using: .png, properties: [:]))
        }
    }

    func testBurstCanvasKeepsAllThreeResultPathsVisible() async throws {
        let activities = [activity(at: instant, outcome: .success, index: 0),
                          activity(at: instant, outcome: .failed, index: 1),
                          activity(at: instant, outcome: .canceled, index: 2)]
        let geometry = geometry(for: activities)
        let root = RoutingFlowFrame(geometry: geometry, activities: activities, date: instant,
                                    isEnabled: false, reduceMotion: false).background(Color.white)
        let (host, window) = open(root)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(60))
        let baseline = try capture(host)
        let age = 1.45
        host.rootView = RoutingFlowFrame(geometry: geometry, activities: activities,
                                        date: instant.addingTimeInterval(age), isEnabled: true, reduceMotion: false)
            .background(Color.white)
        try await Task.sleep(for: .milliseconds(60))
        let frame = try capture(host)
        let sample = try XCTUnwrap(RoutingFlowSample.at(age: age))
        for activity in activities {
            let curve = try XCTUnwrap(geometry.target(activity.targetID))
            assertVisible(frame, baseline: baseline, point: curve.point(at: sample.headParameter))
        }
    }

    /// 活动在窗口已显示后发布；捕获相隔 240ms 的真正 Timeline 中途帧，防止重现
    /// State 只有终值、手算位置不随插值更新而导致“测试有信号，实际没有移动”的问题。
    func testLiveTimelineMovesAfterArrivalAndMeasuresActualNodePreferences() async throws {
        let driver = FlowFixtureDriver()
        let root = FlowFixture(driver: driver).background(Color.white)
        let (host, window) = open(root)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(driver.anchors.count, 3)
        let baseline = try capture(host)
        let received = Date()
        driver.activities = [activity(at: received)]
        try await Task.sleep(for: .milliseconds(140))
        let first = try capture(host)
        let sample1 = try XCTUnwrap(RoutingFlowSample.at(age: Date().timeIntervalSince(received)))
        let geometry = RoutingFlowGeometry(anchors: driver.anchors)
        let curve = try XCTUnwrap(geometry.source(driver.activities[0].sourceID))
        assertVisible(first, baseline: baseline, point: curve.point(at: sample1.headParameter))
        try await Task.sleep(for: .milliseconds(240))
        let second = try capture(host)
        let sample2 = try XCTUnwrap(RoutingFlowSample.at(age: Date().timeIntervalSince(received)))
        XCTAssertGreaterThan(curve.point(at: sample2.headParameter).x, curve.point(at: sample1.headParameter).x)
        assertVisible(second, baseline: baseline, point: curve.point(at: sample2.headParameter))
        XCTAssertNotEqual(first.representation(using: .png, properties: [:]), second.representation(using: .png, properties: [:]))
        // 活动完成后光流层自然回到静态线，不依赖下一次 CPA 更新来停止。
        try await Task.sleep(for: .milliseconds(1500))
        let finished = try capture(host)
        XCTAssertEqual(baseline.representation(using: .png, properties: [:]), finished.representation(using: .png, properties: [:]))
        host.frame.size.width = 580
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try XCTUnwrap(driver.anchors[.hub]).midX, 290, accuracy: 1)
    }
}

@MainActor @Observable
private final class FlowFixtureDriver {
    var activities: [CPARoutingActivity] = []
    var anchors: [RoutingNodeAnchor: CGRect] = [:]
}

/// 夹具使用与生产节点相同的锚点偏好及解析方式；不使用固定中线替代节点测量。
private struct FlowFixture: View {
    let driver: FlowFixtureDriver
    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12)).frame(width: 170, height: 32)
                .anchorPreference(key: RoutingNodeAnchorPreference.self, value: .bounds) { [.source("unknown:source-0"): $0] }
            Spacer()
            RoundedRectangle(cornerRadius: 12).fill(Color.accentColor).frame(width: 38, height: 38)
                .anchorPreference(key: RoutingNodeAnchorPreference.self, value: .bounds) { [.hub: $0] }
            Spacer()
            RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12)).frame(width: 170, height: 32)
                .anchorPreference(key: RoutingNodeAnchorPreference.self, value: .bounds) { [.target("claude:target-0"): $0] }
        }
        .padding(10)
        .backgroundPreferenceValue(RoutingNodeAnchorPreference.self) { anchors in
            GeometryReader { canvas in
                let bounds = anchors.mapValues { canvas[$0] }
                RoutingFlowConnections(geometry: RoutingFlowGeometry(anchors: bounds), activities: driver.activities, isEnabled: true)
                    .onChange(of: bounds, initial: true) { driver.anchors = bounds }
            }
        }
    }
}
