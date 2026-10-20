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

    func testAgentColorMappingForRoutingActivityCometParticles() {
        let claudeActivity = CPARoutingActivity(id: "1", sourceID: "s1", targetID: "t1", outcome: .success, receivedAt: instant, client: "Claude Code")
        XCTAssertEqual(claudeActivity.agentColor, Color(hex: "D97706") ?? .orange)

        let codexActivity = CPARoutingActivity(id: "2", sourceID: "s2", targetID: "t2", outcome: .success, receivedAt: instant, client: "Codex")
        XCTAssertEqual(codexActivity.agentColor, Color(hex: "10A37F") ?? .green)

        let cursorActivity = CPARoutingActivity(id: "3", sourceID: "s3", targetID: "t3", outcome: .success, receivedAt: instant, client: "Cursor")
        XCTAssertEqual(cursorActivity.agentColor, Color(hex: "007AFF") ?? .blue)

        let openCodeActivity = CPARoutingActivity(id: "4", sourceID: "s4", targetID: "t4", outcome: .success, receivedAt: instant, client: "OpenCode")
        XCTAssertEqual(openCodeActivity.agentColor, Color(hex: "8B5CF6") ?? .purple)

        let piActivity = CPARoutingActivity(id: "5", sourceID: "s5", targetID: "t5", outcome: .success, receivedAt: instant, client: "Pi")
        XCTAssertEqual(piActivity.agentColor, Color(hex: "F97316") ?? .orange)

        let unknownActivity = CPARoutingActivity(id: "6", sourceID: "s6", targetID: "t6", outcome: .success, receivedAt: instant, client: nil)
        XCTAssertEqual(unknownActivity.agentColor, Color.accentColor)
    }
}

