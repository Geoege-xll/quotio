import XCTest
@testable import QuotioPlus

/// 使用独立偏好域验证统一入口和 Tab 状态，避免修改真实用户的页面选择。
@MainActor
final class AnalyticsNavigationTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "quotio-analytics-navigation-" + UUID().uuidString
        let value = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { value.removePersistentDomain(forName: name) }
        return value
    }

    func testFirstVisitAndUnknownPreferenceDefaultToCPAUsage() throws {
        let preferences = try defaults()
        XCTAssertEqual(AnalyticsNavigationState(defaults: preferences).tab, .usage)
        preferences.set("removed-tab", forKey: AnalyticsNavigationState.selectedTabKey)
        XCTAssertEqual(AnalyticsNavigationState(defaults: preferences).tab, .usage)
    }

    func testTabChoiceSurvivesNavigationRecreationAndDashboardKeepsFilters() throws {
        let preferences = try defaults()
        let state = AnalyticsNavigationState(defaults: preferences)
        state.cpaSelection.range = .days7
        state.cpaSelection.provider = "openai"
        state.cpaSelection.model = "fixture-model"
        state.cpaDashboardModel.dimension = .apiKey
        state.cpaDashboardModel.metric = .requests
        let filters = state.cpaSelection
        state.tab = .calls
        XCTAssertEqual(AnalyticsNavigationState(defaults: preferences).tab, .calls)
        // 仪表盘跳回用量 Tab 只修改 Tab，不把用户筛选重置成首页的“今日”。
        state.openUsage()
        XCTAssertEqual(state.tab, .usage)
        XCTAssertEqual(state.cpaSelection, filters)
        XCTAssertEqual(state.cpaDashboardModel.dimension, .apiKey)
        XCTAssertEqual(state.cpaDashboardModel.metric, .requests)
        XCTAssertEqual(AnalyticsNavigationState(defaults: preferences).tab, .usage)
    }

    func testBothOperatingModesExposeOneAnalyticsEntry() {
        for mode in OperatingMode.allCases {
            XCTAssertEqual(mode.visiblePages.filter { $0 == .analytics }.count, 1)
            XCTAssertFalse(mode.visiblePages.contains { $0.rawValue == "Usage Statistics" || $0.rawValue == "Call Analytics" })
        }
    }
}
