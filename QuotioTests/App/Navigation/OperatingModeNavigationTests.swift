import XCTest
@testable import QuotioPlus

/// 验证实际侧栏列表与被移除的设置深链接。无需启动服务或修改真实用户偏好。
@MainActor
final class OperatingModeNavigationTests: XCTestCase {
    func testSidebarShowsLocalProxyPagesInExpectedOrder() {
        XCTAssertEqual(NavigationPage.sidebarPages,
            [.dashboard, .analytics, .providers, .agents, .agentManagement, .apiKeys, .settings, .about])
    }

    func testRemovedModeLinkFallsBackToProxyServerSettings() {
        let target = SettingsDestination(category: .general, topic: .mode)
        XCTAssertEqual(target, SettingsDestination(category: .service, topic: .server))
        XCTAssertFalse(SettingsTopic.mode.matches("operating mode"))
        XCTAssertFalse(SettingsTopic.mode.matches("运行模式"))
    }
}
