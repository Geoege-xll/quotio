import Foundation
import Observation

/// 一级入口合并后仍保留两个清晰的统计口径。首次安装默认打开 CPA 用量；
/// 之后只持久化用户选择的 Tab，不把本地客户端日志与 CPA 请求合并。
nonisolated enum AnalyticsTab: String, CaseIterable, Identifiable, Sendable {
    case usage
    case calls

    var id: Self { self }
    var titleKey: String { self == .usage ? "nav.usageStatistics" : "nav.callAnalytics" }
    var title: String { titleKey.localizedStatic() }

    var icon: String {
        switch self {
        case .usage: return "chart.bar.xaxis"
        case .calls: return "desktopcomputer"
        }
    }
}

/// 统计导航的稳定状态容器，由 ContentView 持有并注入仪表盘和统计页。
/// CPA 筛选与图表模型保持独立于 Tab 的可见性，切换时仅暂停查询，不清空已有结果。
@MainActor @Observable
final class AnalyticsNavigationState {
    static let selectedTabKey = "analytics.selectedTab"

    var tab: AnalyticsTab {
        didSet { defaults.set(tab.rawValue, forKey: Self.selectedTabKey) }
    }
    var cpaSelection = CPAUsageSelection(range: .all)
    let cpaDashboardModel = CPAUsageDashboardViewModel()
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tab = defaults.string(forKey: Self.selectedTabKey).flatMap(AnalyticsTab.init(rawValue:)) ?? .usage
    }

    /// 仪表盘的用量跳转明确打开 CPA Tab，但保留用户在统计页选定的时间、模型及来源。
    /// 仅修改展示状态；后台 CPA 队列仍由应用原有的唯一采集服务消费。
    func openUsage() { tab = .usage }
}
