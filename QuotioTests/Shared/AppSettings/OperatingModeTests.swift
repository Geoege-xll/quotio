import XCTest
@testable import QuotioPlus

@MainActor
final class OperatingModeTests: XCTestCase {
    func testRemoteModeIsNoLongerAvailable() {
        XCTAssertNil(OperatingMode(rawValue: "remote"))
    }

    func testPersistedModeMarkersRemainDecodable() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(OperatingMode.self, from: Data(#""monitor""#.utf8)), .monitor)
        XCTAssertEqual(try decoder.decode(OperatingMode.self, from: Data(#""local""#.utf8)), .localProxy)
    }

    func testCurrentLaunchMigratesStoredAndLegacyModesToLocal() throws {
        for existing in [nil, "monitor", "local", "remote", "unknown"] as [String?] {
            let name = "operating-mode-migration-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            // 模拟旧远程、监控或无有效新值的升级；引导已完成而且用户曾关闭自动启动。
            defaults.set(existing, forKey: "operatingMode")
            defaults.set("full", forKey: "appMode")
            defaults.set("remote", forKey: "connectionMode")
            defaults.set(true, forKey: "hasCompletedOnboarding")
            defaults.set(false, forKey: "autoStartProxy")

            let manager = OperatingModeManager(defaults: defaults)
            XCTAssertEqual(manager.currentMode, .localProxy)
            XCTAssertTrue(manager.hasCompletedOnboarding)
            XCTAssertEqual(defaults.string(forKey: "operatingMode"), "local")
            XCTAssertEqual(defaults.string(forKey: "appMode"), "full")
            XCTAssertEqual(defaults.string(forKey: "connectionMode"), "remote")
            XCTAssertEqual(defaults.object(forKey: "autoStartProxy") as? Bool, false)
            if existing == nil {
                XCTAssertTrue(defaults.bool(forKey: "migratedToOperatingMode"))
            }
        }
    }

    func testFreshOnboardingPersistsCompletionIndependentlyOfMode() throws {
        let name = "operating-mode-onboarding-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = OperatingModeManager(defaults: defaults)
        XCTAssertEqual(manager.currentMode, .localProxy)
        XCTAssertFalse(manager.hasCompletedOnboarding)
        // 旧调用签名仍可完成引导，但历史模式不能改变应用运行方式。
        manager.completeOnboarding(mode: .monitor)
        XCTAssertEqual(manager.currentMode, .localProxy)
        XCTAssertTrue(OperatingModeManager(defaults: defaults).hasCompletedOnboarding)
    }
}
