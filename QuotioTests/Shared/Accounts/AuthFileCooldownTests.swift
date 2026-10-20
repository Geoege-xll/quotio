import AppKit
import SwiftUI
import XCTest
@testable import QuotioPlus

@MainActor
final class AuthFileCooldownTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAbsoluteDeadlineOverridesSnapshotAndExpiresWithoutNetworkRefresh() {
        let expiry = now.addingTimeInterval(30)
        let cooldown = AuthFileCooldown(scope: "model", modelKey: "fixture", retryAt: expiry.ISO8601Format(),
                                        remainingSeconds: 300, observedAt: now)
        XCTAssertEqual(cooldown.secondsRemaining(at: now), 30)
        XCTAssertEqual(AuthFileCooldown.summary(AuthFileCooldown.active([cooldown], at: now.addingTimeInterval(20))), "fixture (10s)")
        XCTAssertTrue(AuthFileCooldown.active([cooldown], at: expiry).isEmpty)
        XCTAssertEqual(cooldown.remainingSeconds, 300, "展示时钟不能改写服务端快照")
    }

    func testMissingOrInvalidDeadlineCountsDownFromObservationAndDoesNotRestart() {
        for retryAt in [nil, "unrecognized"] as [String?] {
            let cooldown = AuthFileCooldown(scope: "credential", retryAt: retryAt, remainingSeconds: 30, observedAt: now)
            XCTAssertEqual(cooldown.secondsRemaining(at: now.addingTimeInterval(29)), 1)
            XCTAssertEqual(cooldown.secondsRemaining(at: now.addingTimeInterval(31)), 0)
        }
    }

    func testFractionalTimestampAndZeroSnapshotRemainSafe() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let value = formatter.string(from: now.addingTimeInterval(1.5))
        let cooldown = AuthFileCooldown(scope: "credential", retryAt: value, remainingSeconds: 2, observedAt: now)
        XCTAssertEqual(cooldown.secondsRemaining(at: now), 2)
        XCTAssertEqual(cooldown.secondsRemaining(at: now.addingTimeInterval(2)), 0)
        let stopped = AuthFileCooldown(scope: "credential", retryAt: now.addingTimeInterval(30).ISO8601Format(), remainingSeconds: 0)
        XCTAssertEqual(stopped.secondsRemaining(at: now), 0)
    }

    func testAccountRowResetEligibilityUsesSameDeadlineAndEncodingKeepsOriginalSchema() throws {
        let expiry = now.addingTimeInterval(3)
        let cooldown = AuthFileCooldown(scope: "credential", retryAt: expiry.ISO8601Format(), remainingSeconds: 3, observedAt: now)
        let file = AuthFile(id: "fixture", name: "fixture.json", provider: "codex", authIndex: "index", cooldowns: [cooldown])
        let row = AccountRowData.from(authFile: file, provider: .codex)
        XCTAssertTrue(row.canResetCooldown(at: now))
        XCTAssertFalse(row.canResetCooldown(at: expiry))
        XCTAssertTrue(row.activeCooldowns(at: expiry).isEmpty)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(cooldown)) as? [String: Any])
        XCTAssertEqual(object["remaining_seconds"] as? Int, 3)
        XCTAssertNil(object["deadline"], "观测到期值不能进入持久化协议")
    }
}
