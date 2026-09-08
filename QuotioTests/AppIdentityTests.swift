import XCTest
@testable import Quotio

final class AppIdentityTests: XCTestCase {
    func testProductionBundleIdentifierUsesQuotioPlusIdentity() {
        XCTAssertEqual(AppIdentity.productionBundleIdentifier, "com.app.george.quotioplus")
    }

    func testLegacyDefaultsMergePreservesCurrentValuesAndNewestLegacyDomain() {
        let merged = AppIdentity.mergingUserDefaults(
            current: ["existing": "current"],
            legacyDomains: [
                ["existing": "legacy", "legacyOnly": "newest"],
                ["legacyOnly": "oldest", "oldestOnly": true],
            ]
        )

        XCTAssertEqual(merged["existing"] as? String, "current")
        XCTAssertEqual(merged["legacyOnly"] as? String, "newest")
        XCTAssertEqual(merged["oldestOnly"] as? Bool, true)
    }

    func testOldApplicationIdentityRemainsCredentialMigrationSource() {
        XCTAssertEqual(AppIdentity.legacyBundleIdentifiers.first, "app.bytrong.quotio")
        XCTAssertEqual(AppIdentity.legacyKeychainServices(suffix: "monitor-auth").first, "app.bytrong.quotio.monitor-auth")
    }

    func testIdentityMigrationExcludesUpstreamUpdateState() {
        // 用纯字典验证迁移策略，不接触用户真实偏好域或钥匙串。
        let merged = AppIdentity.mergingUserDefaults(current: ["language": "zh-Hans"], legacyDomains: [[
            "language": "en", "hasCompletedOnboarding": true,
            "SUSkippedVersion": "999", "SULastCheckTime": Date(), "atomFeedCache_quotio": Data()
        ]])
        XCTAssertEqual(merged["language"] as? String, "zh-Hans")
        XCTAssertEqual(merged["hasCompletedOnboarding"] as? Bool, true)
        XCTAssertNil(merged["SUSkippedVersion"])
        XCTAssertNil(merged["SULastCheckTime"])
        XCTAssertNil(merged["atomFeedCache_quotio"])
    }

    func testMigrationPreservesAutomaticCheckChoiceAcrossPreferenceFormats() {
        // 覆盖当前选择优先、同域应用偏好优先，以及最近旧域只有 Sparkle 开关的升级路径。
        let cases: [(current: [String: Any], legacy: [[String: Any]], expected: Bool)] = [
            (["autoCheckUpdates": false], [["autoCheckUpdates": true]], false),
            (["autoCheckUpdates": true], [["SUEnableAutomaticChecks": false]], true),
            (["SUEnableAutomaticChecks": false], [["autoCheckUpdates": true]], false),
            ([:], [["autoCheckUpdates": false, "SUEnableAutomaticChecks": true]], false),
            ([:], [["SUEnableAutomaticChecks": false], ["autoCheckUpdates": true]], false),
        ]
        for item in cases {
            let merged = AppIdentity.mergingUserDefaults(current: item.current, legacyDomains: item.legacy)
            XCTAssertEqual(merged["autoCheckUpdates"] as? Bool, item.expected)
        }
    }
}
