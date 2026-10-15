import AppKit
import SwiftUI
import XCTest
@testable import QuotioPlus

/// 在真正的 NSHostingView 中验证两个 Tab 的滚动容器身份与偏移；
/// 所有 CPA 记录、客户端目录和偏好均为隔离夹具，不访问真实代理或用户日志。
@MainActor
final class AnalyticsScreenRenderingTests: XCTestCase {
    private func settle(_ window: NSWindow) async throws {
        // 给 SwiftUI 一小段真实布局时间，等待 Observation 更新及首次 SQL 聚合完成。
        try await Task.sleep(for: .milliseconds(250))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let current = (view as? NSScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func verticalScrollViews(in view: NSView) -> [NSScrollView] {
        // 隐藏 Tab 会禁用交互，AppKit 此时可能暂时隐藏滚动条；滚动条的可见标志不能
        // 代表容器是否仍存在。按真实纵向内容范围识别两份超过一屏的滚动容器。
        scrollViews(in: view).filter {
            ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height
        }
    }


    func testNativeTabSwitchRetainsBothScrollViewsAndOffsets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 在方法局部的窗口、视图和数据库所有者释放之后再清理，避免删除仍打开的 WAL 文件。
        addTeardownBlock {
            try await Task.sleep(for: .milliseconds(100))
            try? FileManager.default.removeItem(at: root)
        }
        let preferencesName = "quotio-analytics-render-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: preferencesName))
        defer { preferences.removePersistentDomain(forName: preferencesName) }
        // 模拟旧版本只看 Token 的偏好。融合后必须仍能看到调用排行并保留其滚动位置，
        // 不能让已删除的维度控件在后台继续隐藏调用模块，也不能删除用户的旧偏好。
        preferences.set("tokens", forKey: "clientAnalytics.ui.section")
        let defaults = UserDefaults.standard
        let originalLanguage = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(originalLanguage.merging(["appLanguage": "zh-Hans"]) { _, new in new },
            forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(originalLanguage, forName: UserDefaults.argumentDomain) }
        let navigation = AnalyticsNavigationState(defaults: preferences)
        let ledger = UsageLedger(url: root.appendingPathComponent("cpa.json"))
        let records = (0..<32).map { index in
            UsageRecord(timestamp: Date().addingTimeInterval(-Double(index) * 3600), provider: "openai",
                model: "fixture-model-\(index % 4)", requestID: "fixture-\(index)",
                latencyMilliseconds: 1200, tokens: .init(input: 800, output: 200, cached: 100),
                context: CPAUsageContext(ttft: 120, cacheRead: 100, cacheWrite: 0))
        }
        _ = try await ledger.ingest(records, collectedAt: Date())
        let store = UsageStatisticsStore(ledger: ledger)
        await store.restore()
        // 构造足够长的 MCP 排行。空页面的内容不足一屏，原生滚动视图会合法地把偏移钳制到零，
        // 不能用空夹具来证明两个 Tab 都保留了实际非零滚动位置。
        let callFile = root.appendingPathComponent(".claude/projects/fixture/session.jsonl")
        try FileManager.default.createDirectory(at: callFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        var callData = Data()
        for index in 0..<60 {
            let event: [String: Any] = ["type": "assistant", "timestamp": Date().ISO8601Format(), "sessionId": "fixture-session",
                "message": ["id": "fixture-message-\(index)", "model": "fixture-model",
                    "usage": ["input_tokens": 800, "output_tokens": 200,
                        "cache_read_input_tokens": 100, "cache_creation_input_tokens": 0],
                    "content": [["type": "tool_use", "id": "fixture-call-\(index)",
                    "name": "mcp__fixture-\(index % 12)__tool"]]]]
            callData.append(try JSONSerialization.data(withJSONObject: event))
            callData.append(0x0A)
        }
        try callData.write(to: callFile)
        let client = ClientUsageViewModel(engine: ClientUsageEngine(url: root.appendingPathComponent("client.json"),
            homeDirectory: root.path, environment: [:]))
        let calls = CallAnalyticsViewModel(engine: CallAnalyticsEngine(homeDirectory: root.path, environment: [:]))
        let view = StatisticsAnalyticsScreen(clientUsage: client, callAnalytics: calls, store: store,
            totalAccounts: 4, readyAccounts: 3)
            .environment(navigation)
            .environment(\.scenePhase, .active)
            // 来源与日期控件也使用独立偏好域，既不依赖用户之前的筛选，也不修改真实偏好。
            .defaultAppStorage(preferences)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close(); client.setPageActive(false); calls.setPageActive(false) }
        try await settle(window)
        XCTAssertEqual(calls.snapshot.generatedAt, .distantPast, "默认 CPA Tab 不能扫描本地调用")
        XCTAssertNil(client.snapshot.collectedAt, "未进入辅助入口不能扫描客户端用量")

        navigation.tab = .calls
        try await settle(window)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while calls.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls.report.totalCalls, 60)
        XCTAssertEqual(preferences.string(forKey: "clientAnalytics.ui.section"), "tokens",
            "新布局应忽略旧维度偏好，而不是修改用户已有配置")
        try await settle(window)

        // 同时挂载的两个纵向 ScrollView 保持各自对象身份，切换只改变可见性。
        let vertical = verticalScrollViews(in: host)
        XCTAssertEqual(vertical.count, 2, "统计根页面应保留 CPA 与调用各一份纵向滚动容器")
        guard vertical.count == 2 else { return }
        for scroll in vertical {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let identities = vertical.map(ObjectIdentifier.init)
        let offsets = vertical.map { $0.contentView.bounds.origin.y }
        XCTAssertTrue(offsets.allSatisfy { $0 > 0 }, "两类分析都必须使用真实非零滚动位置验证")
        navigation.tab = .usage
        try await settle(window)
        navigation.tab = .calls
        try await settle(window)
        navigation.tab = .usage
        try await settle(window)
        let restored = verticalScrollViews(in: host)
        XCTAssertEqual(restored.map(ObjectIdentifier.init), identities)
        XCTAssertEqual(restored.map { $0.contentView.bounds.origin.y }, offsets,
            "切换 Tab 不能重置原生滚动偏移")
        window.appearance = NSAppearance(named: .darkAqua)
        try await settle(window)
    }
}
