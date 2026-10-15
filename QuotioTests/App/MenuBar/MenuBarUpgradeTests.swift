import AppKit
import SwiftUI
import XCTest
import Vision
@testable import QuotioPlus

/// 菜单栏升级的定向回归：只使用隔离偏好、内存额度与原生菜单／承载视图。
/// 不读取用户凭据、不启停代理、不注册全局动作宿主；刷新测试只预约原内存槽位。
@MainActor
final class MenuBarUpgradeTests: XCTestCase {
    private struct Fixture {
        let model: QuotaViewModel
        let settings: MenuBarSettingsManager
        let manager: StatusBarManager
        let menu: NSMenu
    }

    private let email = "very-long-account-prefix-for-layout-regression@enterprise-example.invalid"

    private func quota(_ remaining: Double = 55, count: Int = 2, analytics: QuotaAnalytics? = nil) -> ProviderQuotaData {
        ProviderQuotaData(models: (0..<count).map {
            ModelQuota(name: "fixture-limit-\($0)", percentage: remaining, resetTime: "2030-01-01T00:00:00Z")
        }, lastUpdated: Date(timeIntervalSince1970: 1_700_000_000), planType: "pro", analytics: analytics,
           accountDisplayName: email)
    }

    private func fixture(providers: [AIProvider] = [.claude], history: QuotaHistoryService? = nil) throws -> Fixture {
        let suite = "quotio-menubar-upgrade-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(OperatingMode.monitor.rawValue, forKey: "operatingMode")
        defaults.set("", forKey: "menuBarSelectedProvider")
        let settings = MenuBarSettingsManager(defaults: defaults)
        settings.quotaDisplayMode = .remaining
        let model = QuotaViewModel(
            directAuthService: DirectAuthFileService(authDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            startsBackgroundServices: false, modeManager: OperatingModeManager(defaults: defaults),
            menuBarSettings: settings, refreshSettings: RefreshSettingsManager(defaults: defaults),
            warmupSettings: WarmupSettingsManager(defaults: defaults),
            notificationManager: NotificationManager(testDefaults: defaults, notificationSink: { _ in }))
        model.customProvidersForTesting = []
        for provider in providers { model.providerQuotas[provider] = ["fixture": quota()] }
        let manager = StatusBarManager.makeForTesting(viewModel: model, history: history)
        let menu = try XCTUnwrap(manager.menuForTesting)
        manager.menuWillOpen(menu)
        addTeardownBlock { @MainActor in
            manager.removeStatusItem()
            defaults.removePersistentDomain(forName: suite)
        }
        return Fixture(model: model, settings: settings, manager: manager, menu: menu)
    }

    private func card(_ f: Fixture, provider: AIProvider = .claude) throws -> NSMenuItem {
        try XCTUnwrap(f.menu.items.first { $0.title == provider.displayName && $0.submenu != nil })
    }

    func testTrackedAccountAndHistoryKeepOriginalModeGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("menu-mode-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = QuotaHistoryService(store: QuotaHistoryStore(databaseURL: directory.appendingPathComponent("analytics.sqlite")))
        let f = try fixture(history: history)
        let item = try card(f), host = try XCTUnwrap(item.view), detail = try XCTUnwrap(item.submenu)
        let action = try XCTUnwrap(detail.items.first { $0.representedObject is QuotaHistoryWindowContext })
        let context = try XCTUnwrap(action.representedObject as? QuotaHistoryWindowContext)
        let panel = window(host)
        defer { panel.close() }
        XCTAssertTrue(context.isCurrent(mode: .monitor, revision: f.model.modeManager.revision))
        f.model.modeManager.setMode(.localProxy)
        f.model.providerQuotas[.claude] = ["fixture": quota(77)]
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(item.view === host && item.submenu === detail)
        XCTAssertFalse(text(host).contains("77%"), "旧菜单不能借用新模式的同名账号额度")
        XCTAssertFalse(context.isCurrent(mode: .localProxy, revision: f.model.modeManager.revision))
        f.model.modeManager.setMode(.monitor)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(context.isCurrent(mode: .monitor, revision: f.model.modeManager.revision), "A→B→A 也不能复活旧菜单动作")
        XCTAssertFalse(text(host).contains("77%"))
    }

    /// 直接弹出真实原生明细菜单，使动态高度桥接在 NSMenu 窗口中运行；不把视图移到普通窗口。
    /// 不更新任何额度，靠 UI 截止时刻唤醒收回过期预测，原生项及承载视图保持同一身份。
    func testNativeDetailTrackingExpiresPaceWithoutNewQuotaPublication() throws {
        let f = try fixture()
        let date = Date()
        f.model.providerQuotas[.claude] = ["fixture": ProviderQuotaData(models: [
            ModelQuota(name: "session", percentage: 55,
                resetTime: ISO8601DateFormatter().string(from: date.addingTimeInterval(300)), windowSeconds: 3600)
        ], lastUpdated: date.addingTimeInterval(-1798.5))]
        f.manager.menuWillOpen(f.menu)
        let submenu = try XCTUnwrap(card(f).submenu)
        let item = try XCTUnwrap(submenu.items.first), host = try XCTUnwrap(item.view)
        var before: CGFloat = 0, completed = false
        var timers: [Timer] = []
        defer { timers.forEach { $0.invalidate() } }
        func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) {
            let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { action() } }
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
        }
        schedule(0.2) {
            XCTAssertTrue(host.window?.isVisible == true, "必须实际进入原生明细菜单窗口")
            before = host.frame.height
        }
        schedule(2.3) {
            XCTAssertTrue(item.view === host)
            XCTAssertGreaterThan(before, 0)
            XCTAssertLessThan(host.frame.height, before - 20, "到期后提示与预留行高一起消失")
            XCTAssertEqual(f.model.providerQuotas[.claude]?["fixture"]?.lastUpdated, date.addingTimeInterval(-1798.5))
            completed = true
            submenu.cancelTracking()
        }
        submenu.popUp(positioning: nil, at: NSPoint(x: 240, y: 420), in: nil)
        XCTAssertTrue(completed, "定向回归必须执行到真实菜单的过期回调")
    }

    func testHistoryEntryKeepsExactIdentityAndNativeItemWhileRefreshing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("menu-history-" + UUID().uuidString)
        let history = QuotaHistoryService(store: QuotaHistoryStore(databaseURL: directory.appendingPathComponent("analytics.sqlite")))
        defer { try? FileManager.default.removeItem(at: directory) }
        let f = try fixture(history: history)
        let submenu = try XCTUnwrap(card(f).submenu)
        let item = try XCTUnwrap(submenu.items.first { $0.representedObject is QuotaHistoryWindowContext })
        let context = try XCTUnwrap(item.representedObject as? QuotaHistoryWindowContext)
        XCTAssertEqual(context.account, QuotaHistoryAccount(mode: "monitor", provider: .claude, accountKey: "fixture"))
        f.model.providerQuotas[.claude] = ["fixture": quota(35)]
        f.manager.rebuildMenuInPlace()
        XCTAssertTrue(item === submenu.items.first { $0.representedObject is QuotaHistoryWindowContext })
    }

    private func window(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.frame.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func capture(_ host: NSView) throws -> Data {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        // 自定义菜单项背景由 AppKit 提供，直接缓存视图会得到透明底。
        // 在测试截图中补同一外观的窗口底色，保证实际文字可见并供本地 OCR 核对。
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        host.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.fill(bounds)
        context.draw(image, in: bounds)
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage()))
            .representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 500)
        return data
    }

    /// 当前 SwiftUI 测试宿主未提供辅助功能子树；直接在本地读取实际绘制文字，
    /// 不用 ViewModel 同值副本替代渲染验证，不访问任何外部识别服务。
    private func text(_ host: NSView) -> String {
        do {
            let data = try capture(host)
            let image = try XCTUnwrap(NSBitmapImageRep(data: data)?.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        } catch {
            XCTFail("无法读取隔离渲染截图：\(error)")
            return ""
        }
    }

    /// 模拟菜单真实跟踪中的刷新和账号新增；原菜单项、承载视图与子菜单均保持同一对象。
    /// 固定 lastUpdated，图像和实际读数变化必须来自额度及加载状态，不能由更新时间掩盖冻结内容。
    func testTrackedMenuUpdatesQuotaWithoutReplacingItemsOrSubmenus() throws {
        let f = try fixture()
        // popUp 会调用真实 menuWillOpen，因此在跟踪开始后记录身份，避免把上一次打开的对象当作本轮。
        var trackedItem: NSMenuItem?, trackedHost: NSView?, trackedDetail: NSMenu?
        var ids: [ObjectIdentifier] = []
        var before: Data?, loading: Data?, completed = false
        var timers: [Timer] = []
        defer { timers.forEach { $0.invalidate() }; f.model.endScopedRefresh(provider: .claude) }
        func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) {
            let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { action() } }
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
        }
        schedule(0.15) {
            guard let item = try? self.card(f), let host = item.view else { XCTFail("未装配账号"); return }
            trackedItem = item; trackedHost = host; trackedDetail = item.submenu
            ids = f.menu.items.map(ObjectIdentifier.init)
            before = try? self.capture(host)
            XCTAssertTrue(self.text(host).contains("55%"))
            XCTAssertTrue(f.model.beginScopedRefresh(provider: .claude))
            f.manager.rebuildMenuInPlace()
        }
        schedule(0.4) {
            guard let host = trackedHost else { XCTFail("缺少原承载视图"); return }
            loading = try? self.capture(host)
            XCTAssertNotEqual(loading, before, "刷新反馈必须在原卡片中变化")
            let header = f.menu.items.first?.view
            XCTAssertEqual(header?.frame.height ?? 0, header?.intrinsicContentSize.height ?? 0, accuracy: 1)
            f.model.providerQuotas[.claude]?["fixture"] = self.quota(73)
            f.model.providerQuotas[.claude]?["new"] = self.quota(20)
            f.model.endScopedRefresh(provider: .claude)
            for _ in 0..<10 { f.manager.rebuildMenuInPlace() }
        }
        schedule(0.8) {
            guard let item = trackedItem, let host = trackedHost else { XCTFail("缺少原菜单项"); return }
            XCTAssertEqual(f.menu.items.map(ObjectIdentifier.init), ids)
            XCTAssertTrue(item.view === host)
            XCTAssertTrue(item.submenu === trackedDetail)
            XCTAssertNotEqual(try? self.capture(host), before)
            XCTAssertTrue(self.text(host).contains("73%"), "旧视图应读取最新额度")
            XCTAssertFalse(self.text(host).contains("55%"))
            XCTAssertEqual(f.menu.items.filter { $0.submenu != nil }.count, 1, "新账号在下次打开时加入")
            completed = true
            f.menu.cancelTracking()
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        f.menu.popUp(positioning: nil, at: NSPoint(x: frame.midX, y: frame.midY), in: nil)
        if !completed { throw XCTSkip("桌面未保持原生菜单跟踪，需单独验证本用例") }
        f.manager.menuWillOpen(f.menu)
        XCTAssertEqual(f.menu.items.filter { $0.submenu != nil }.count, 2)
    }

    /// 每个提供商都有额度明细；Codex 分析继续保留在嵌套子菜单，原始额度桶不被摘要替换。
    func testAllProvidersHaveUnifiedDetailsAndCodexAnalyticsEntry() throws {
        let f = try fixture(providers: AIProvider.allCases)
        let accounts = f.menu.items.filter { $0.submenu != nil }
        XCTAssertEqual(accounts.count, AIProvider.allCases.count)
        for provider in AIProvider.allCases {
            let item = try card(f, provider: provider)
            XCTAssertNotNil(item.submenu?.items.first?.view, provider.rawValue)
            XCTAssertEqual(item.title, provider.displayName, "原生标题不能泄漏未遮罩邮箱")
            let host = try XCTUnwrap(item.submenu?.items.first?.view)
            XCTAssertGreaterThan(host.frame.height, 50)
            XCTAssertLessThan(host.frame.height, 500)
        }
        let codex = try card(f, provider: .codex)
        XCTAssertNotNil(codex.submenu?.items.first(where: { $0.submenu != nil })?.submenu?.items.first?.view)
    }

    /// 额度桶变多时原子菜单项内滚动；账号删除后原视图清空旧数值，下一次打开才删除原生项。
    func testDetailsResizeScrollAndRejectRemovedAccountSnapshot() async throws {
        let f = try fixture()
        let item = try card(f), detail = try XCTUnwrap(item.submenu), row = try XCTUnwrap(detail.items.first)
        let host = try XCTUnwrap(row.view), panel = window(host)
        defer { panel.close() }
        let beforeHeight = host.frame.height
        f.model.providerQuotas[.claude]?["fixture"] = quota(61, count: 30)
        f.manager.rebuildMenuInPlace()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(item.submenu === detail)
        XCTAssertTrue(detail.items.first === row)
        XCTAssertTrue(row.view === host)
        XCTAssertGreaterThan(host.frame.height, beforeHeight + 50)
        XCTAssertLessThan(host.frame.height, 500, "30 桶明细不能超出普通屏幕可用高度")
        func scrolls(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrolls)
        }
        let scroll = try XCTUnwrap(scrolls(host).first)
        XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, scroll.contentSize.height)
        scroll.documentView?.scroll(NSPoint(x: 0, y: 600))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0, "尾部模型必须可滚动到达")
        f.model.providerQuotas[.claude] = [:]
        f.manager.rebuildMenuInPlace()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(text(host).contains("61%"))
        XCTAssertTrue(row.view === host)
        XCTAssertLessThan(host.frame.height, beforeHeight)
        f.manager.menuDidClose(f.menu)
        f.manager.menuWillOpen(f.menu)
        XCTAssertFalse(f.menu.items.contains { $0.submenu != nil })
    }

    func testLateCodexAnalyticsUpdatesExistingNestedView() async throws {
        let f = try fixture(providers: [.codex])
        let item = try card(f, provider: .codex)
        let submenu = try XCTUnwrap(item.submenu?.items.first(where: { $0.submenu != nil })?.submenu)
        let host = try XCTUnwrap(submenu.items.first?.view), panel = window(host)
        defer { panel.close() }
        let before = try capture(host)
        f.model.providerQuotas[.codex]?["fixture"]?.analytics = QuotaAnalytics(rows: [
            QuotaAnalyticsRow(id: "fixture-analysis", title: "Fixture analysis", value: "321")])
        f.manager.rebuildMenuInPlace()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(submenu.items.first?.view === host)
        XCTAssertNotEqual(try capture(host), before)
        XCTAssertTrue(text(host).contains("321"))
    }

    /// 三种原样式、已用／剩余和金额／未知混合值均真实渲染；隐私切换不会留下旧邮箱文本。
    func testAllStylesRenderMixedMetricsAndLivePrivacy() async throws {
        let f = try fixture()
        var images: Set<Data> = []
        for style in QuotaDisplayStyle.allCases {
            for mode in QuotaDisplayMode.allCases {
                f.settings.quotaDisplayStyle = style
                f.settings.quotaDisplayMode = mode
                f.settings.hideSensitiveInfo = false
                var data = quota(55, count: 1)
                data.models += [ModelQuota(name: "unknown", percentage: -1, resetTime: ""),
                    ModelQuota(name: "balance", percentage: -1, resetTime: "", presentation: .amount(value: 12.5, unit: .usd, semantics: .balance))]
                f.model.providerQuotas[.claude]?["fixture"] = data
                let host = try XCTUnwrap(try card(f).view), panel = window(host)
                defer { panel.close() }
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(host.frame.width, 360, accuracy: 1)
                XCTAssertLessThan(host.frame.height, 260, "收紧后的三桶账号卡片应保持紧凑")
                let value = text(host)
                try capture(host).write(to: URL(fileURLWithPath: "/tmp/quotio-menu-\(style.rawValue)-\(mode.rawValue).png"))
                // 小号彩色百分比／环内文字可能被 OCR 略过，不将识别器漏字当成 UI 故障。
                // 六套真实截图必须互不相同，验证三样式及已用／剩余切换确实改变绘制。
                // 精确刷新读数另由正常字号的真实跟踪用例检查，未知值转换沿用原单元回归。
                XCTAssertFalse(value.contains("101%"))
                XCTAssertTrue(value.contains("12"), "金额行应保留本地化数值，不能伪装成百分比")
                images.insert(try capture(host))
                if style == .card, mode == .remaining {
                    try capture(host).write(to: URL(fileURLWithPath: "/tmp/quotio-menubar-upgrade-card-preview-20261015.png"))
                }
                let captureBeforePrivacy = try capture(host)
                f.settings.hideSensitiveInfo = true
                try await Task.sleep(for: .milliseconds(80))
                XCTAssertNotEqual(try capture(host), captureBeforePrivacy)
                XCTAssertFalse(text(host).contains("very-long"), "菜单展开时切换隐私，原视图也必须遮罩账号")
            }
        }
        XCTAssertEqual(images.count, 6, "三种布局和已用／剩余应保留各自实际呈现")
    }

    /// 原 IDE 切换仍由按钮回调触发；使用隔离回调验证，不执行真实账号切换或打开系统确认框。
    func testCompactCardRetainsIDEActionForLongAccount() async throws {
        let f = try fixture()
        var uses = 0
        let view = MenuAccountCardView(accountKey: "fixture", email: email, data: quota(), provider: .antigravity,
            subscriptionInfo: nil, isActiveInIDE: false, onUseAccount: { uses += 1 }, settings: f.settings)
            .environment(f.model).frame(width: 360)
        let host = NSHostingView(rootView: view)
        host.setFrameSize(host.intrinsicContentSize)
        let panel = window(host)
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(100))
        panel.orderFront(nil)
        // 向隔离窗口发送真实鼠标事件，不调用按钮回调自身，也不操作用户的实际菜单或账号。
        let location = host.convert(NSPoint(x: 80, y: host.isFlipped ? host.bounds.height - 18 : 18), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            panel.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(uses, 1)
        XCTAssertEqual(host.frame.width, 360, accuracy: 1)
        XCTAssertTrue(text(host).contains("very-long"), "长账号保留可辨认的首部")
        try capture(host).write(to: URL(fileURLWithPath: "/tmp/quotio-menubar-upgrade-ide-preview-20261015.png"))
    }
}
