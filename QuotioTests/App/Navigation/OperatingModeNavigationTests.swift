import Foundation
import XCTest
@testable import QuotioPlus

/// 从 App 导航查询共享模式，验证分文件后仍读取同一 manager，查询不会写偏好或推进世代。
/// 使用独立偏好域，仅调用模式切换，不启动／停止 CPA 或执行任何旧模式清理。
@MainActor
final class OperatingModeNavigationTests: XCTestCase {
    func testNavigationReadsSharedModeWithoutChangingRevisionOrPreferences() throws {
        let suite = "quotio-mode-navigation-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = OperatingModeManager(defaults: defaults)

        for mode in OperatingMode.allCases {
            manager.setMode(mode)
            let revision = manager.revision
            let preferences = defaults.persistentDomain(forName: suite) ?? [:]
            let expected: [NavigationPage] = mode == .monitor
                ? [.dashboard, .analytics, .providers, .settings, .about]
                : [.dashboard, .analytics, .providers, .agents, .apiKeys, .settings, .about]
            XCTAssertEqual(manager.currentMode.visiblePages, expected)
            for page in NavigationPage.allCases {
                XCTAssertEqual(manager.isPageVisible(page), expected.contains(page))
                XCTAssertEqual(manager.isPageVisible(page, loggingEnabled: false),
                               page != .logs && expected.contains(page))
            }
            XCTAssertEqual(manager.currentMode, mode)
            XCTAssertEqual(manager.revision, revision, "导航读取不能废弃正在执行的账号／授权会话")
            XCTAssertEqual(defaults.string(forKey: "operatingMode"), mode.rawValue)
            XCTAssertTrue(NSDictionary(dictionary: preferences).isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]))
        }
    }
}
