import AppKit
import SwiftUI
import XCTest
import Vision
@testable import QuotioPlus

/// 菜单栏升级的定向回归：只使用隔离偏好、内存额度与原生菜单／承载视图。
/// 不读取用户凭据、不启停代理、不注册全局动作宿主；刷新测试只预约原内存槽位。
@MainActor
final class MenuBarUpgradeTests: XCTestCase {
    @Observable final class TrendFixture {
        var points = [
            QuotaAnalyticsPoint(date: "2026-10-13", value: 777, label: "", valueLabel: "777 tokens"),
            QuotaAnalyticsPoint(date: "2026-10-14", value: 1313, label: "", valueLabel: "1313 tokens")
        ]
    }

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

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    /// 同批次前面的普通窗口用例可能尚在完成激活／关闭通知。
    /// 先让测试应用完成激活再启动同步菜单跟踪，避免迟到的窗口事件把菜单提前关闭。
    private func prepareNativeTracking() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    func testNativeCascadeRefreshAndModeSwitchKeepExactAccountAndWindows() throws {
        let f = try fixture(providers: [.codex])
        prepareNativeTracking()
        var account: NSMenuItem?, detail: NSMenu?, analyticsMenu: NSMenu?
        var cardHost: NSView?, detailHost: NSView?, analyticsHost: NSView?
        var completed = false
        var timers: [Timer] = []
        defer { timers.forEach { $0.invalidate() }; f.menu.cancelTracking() }
        func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) {
            let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { action() } }
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
        }
        schedule(0.15) {
            guard let item = try? self.card(f, provider: .codex), let submenu = item.submenu else {
                XCTFail("缺少 Codex 账号菜单"); return
            }
            account = item; detail = submenu; cardHost = item.view; detailHost = submenu.items.first?.view
            analyticsMenu = submenu.items.first { $0.submenu != nil }?.submenu
            analyticsHost = analyticsMenu?.items.first?.view
        }
        schedule(0.35) {
            // 在已跟踪的根菜单中执行 AppKit 的真实辅助功能动作，不直接调用子菜单 popUp。
            // 此入口不依赖测试宿主抢到键盘焦点，也不会向用户正在使用的应用发送全局事件。
            // 当前 AppKit 对带 submenu 的项可能返回 false 却已展开；以下一拍实际窗口为准。
            _ = account?.accessibilityPerformPress()
        }
        schedule(0.65) {
            XCTAssertTrue(detailHost?.window?.isVisible == true, "原生动作应实际展开账号额度明细")
            XCTAssertTrue(detail?.supermenu === f.menu)
            _ = detail?.items.first { $0.submenu != nil }?.accessibilityPerformPress()
        }
        schedule(1.15) {
            XCTAssertTrue(analyticsHost?.window?.isVisible == true, "必须实际展开第三级 Codex 分析窗口")
            XCTAssertNotEqual(detailHost?.window?.windowNumber, analyticsHost?.window?.windowNumber)
            XCTAssertTrue(analyticsMenu?.supermenu === detail)
            let rows = [QuotaAnalyticsRow(id: "fixture-analysis", title: "Fixture analysis", value: "321"),
                QuotaAnalyticsRow(id: "codex-rate-limit-resets", title: "Resets", value: "20 available")]
                + (1...20).map { QuotaAnalyticsRow(id: "codex-rate-limit-reset-\($0)", title: "2030-01-\($0)", value: "in \($0) days") }
            f.model.providerQuotas[.codex]?["fixture"] = self.quota(73, count: 8, analytics: QuotaAnalytics(rows: rows))
            f.manager.rebuildMenuInPlace()
        }
        schedule(1.55) {
            guard let host = analyticsHost, let quotaHost = detailHost else { XCTFail("缺少级联承载视图"); return }
            XCTAssertTrue(host.window?.isVisible == true && quotaHost.window?.isVisible == true)
            XCTAssertTrue(self.text(host).contains("321"), "晚到分析应在已展开的第三级菜单绘制")
            XCTAssertTrue(self.text(quotaHost).contains("73%"))
            XCTAssertGreaterThan(quotaHost.frame.height, 280, "额度桶增加后原生明细必须原位增高")
            XCTAssertGreaterThanOrEqual(quotaHost.visibleRect.height, quotaHost.bounds.height - 1,
                "真实菜单窗口必须显示增高后的完整额度项，不能只改变承载视图而被旧窗口裁剪")
            XCTAssertGreaterThanOrEqual(host.visibleRect.width, host.bounds.width - 1)
            XCTAssertLessThanOrEqual(host.window?.frame.height ?? .infinity,
                host.window?.screen?.visibleFrame.height ?? 0)
            XCTAssertTrue(account?.view === cardHost && account?.submenu === detail)
            XCTAssertTrue(analyticsMenu?.items.first?.view === host)
            for (name, view) in [("Native-root", cardHost), ("Native-quota-details", detailHost), ("Native-Codex-analysis", analyticsHost)] {
                if let view, let data = try? self.capture(view) {
                    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                    attachment.name = name; attachment.lifetime = .keepAlways; self.add(attachment)
                }
            }
            // 库存很多时，真实第三级菜单必须仍限制为原有宽度，并能滚动到最后一张券。
            XCTAssertEqual(host.frame.width, 640, accuracy: 1)
            guard let scroll = self.scrollViews(in: host).first(where: {
                ($0.documentView?.bounds.width ?? 0) > $0.contentSize.width + 10
            }), let document = scroll.documentView else { XCTFail("库存标签应提供局部横向滚动"); return }
            // 从库存起点滚到末尾；首部小号 d/数字存在 OCR 混淆，保留实际截图目视核对，
            // 可达性用真实文档宽度、起点和下方末张券实际读数共同验证。
            XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 1)
            scroll.contentView.scroll(to: NSPoint(x: document.bounds.maxX - scroll.contentSize.width,
                y: scroll.contentView.bounds.minY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        schedule(1.75) {
            if let host = analyticsHost {
                XCTAssertTrue(self.text(host).contains("20d"), "真实级联中最后一张券必须可达")
                if let data = try? self.capture(host) {
                    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                    attachment.name = "Native-Codex-inventory-tail"; attachment.lifetime = .keepAlways; self.add(attachment)
                }
            }
            f.model.modeManager.setMode(.localProxy)
            f.model.providerQuotas[.codex]?["fixture"] = self.quota(91, analytics: QuotaAnalytics(rows: [
                QuotaAnalyticsRow(id: "fixture-analysis", title: "Fixture analysis", value: "742")]))
        }
        schedule(1.95) {
            guard let host = analyticsHost, let quotaHost = detailHost, let rootHost = cardHost else { return }
            XCTAssertTrue(host.window?.isVisible == true && quotaHost.window?.isVisible == true,
                "模式切换只更新内容，不能关闭或替换正在跟踪的级联窗口")
            XCTAssertFalse(self.text(host).contains("321") || self.text(host).contains("742"))
            XCTAssertFalse(self.text(quotaHost).contains("73%") || self.text(quotaHost).contains("91%"))
            XCTAssertFalse(self.text(rootHost).contains("91%"))
            f.model.modeManager.setMode(.monitor)
        }
        schedule(2.25) {
            if let host = analyticsHost { XCTAssertFalse(self.text(host).contains("742"), "返回原模式也不能复活旧菜单") }
            XCTAssertTrue(account?.submenu === detail && analyticsMenu?.items.first?.view === analyticsHost)
            completed = true
            f.menu.cancelTracking()
        }
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        f.menu.popUp(positioning: nil, at: NSPoint(x: frame.minX + 30, y: frame.maxY - 60), in: nil)
        XCTAssertTrue(completed, "必须完成真实三级菜单跟踪，不能提前关闭后跳过验证")
    }

    /// 鼠标只进入测试菜单一次；随后原位替换分析数据，不再发送 hover 事件。
    /// 验证提示来自当前格子，避免用手工改 State 或重建图表掩盖真实的悬停缓存问题。
    func testNativeHeatmapHoverReadsRefreshedDataWithoutMouseMovement() throws {
        let state = TrendFixture()
        // 根闭包的 Observable 读取必须发生在 body，复用实际 SwiftUI 的刷新订阅。
        struct LiveTrend: View {
            let state: TrendFixture
            var body: some View { UsageTrendHeatmap(points: state.points, mode: .daily).frame(width: 640) }
        }
        let liveHost = makeMenuItemHostingView(rootView: LiveTrend(state: state), resizesToFitContent: true)
        liveHost.setFrameSize(liveHost.intrinsicContentSize)
        let item = NSMenuItem()
        item.view = liveHost
        let menu = NSMenu(); menu.autoenablesItems = false; menu.addItem(item)
        prepareNativeTracking()
        let pointer = CGEvent(source: nil)?.location
        var timers: [Timer] = [], completed = false
        defer {
            timers.forEach { $0.invalidate() }; menu.cancelTracking()
            if let pointer { CGWarpMouseCursorPosition(pointer) }
        }
        func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) {
            let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { action() } }
            RunLoop.main.add(timer, forMode: .common); timers.append(timer)
        }
        schedule(0.25) {
            guard let window = liveHost.window else { XCTFail("必须在真实菜单窗口内测试悬停"); return }
            // 54 周布局末列的周三格子，坐标由现有 9pt 格子、2.4pt 间距和标题行组成。
            let local = NSPoint(x: 53 * 11.4 + 4.5,
                y: liveHost.isFlipped ? 58.7 : liveHost.bounds.height - 58.7)
            let location = liveHost.convert(local, to: nil)
            let screen = window.convertPoint(toScreen: location)
            let global = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 900) - screen.y)
            XCTAssertEqual(CGWarpMouseCursorPosition(global), .success)
            window.acceptsMouseMovedEvents = true
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0) { window.sendEvent(event) }
        }
        schedule(0.65) {
            XCTAssertTrue(self.text(liveHost).contains("1313"), "必须先真实悬停读到旧值")
            if let data = try? self.capture(liveHost) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = "Native-hover-before"; attachment.lifetime = .keepAlways; self.add(attachment)
            }
            state.points[1].value = 4242; state.points[1].valueLabel = "4242 tokens"
        }
        schedule(0.95) {
            XCTAssertTrue(self.text(liveHost).contains("4242"), "鼠标不动也应读取本轮值")
            XCTAssertFalse(self.text(liveHost).contains("1313"))
            if let data = try? self.capture(liveHost) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = "Native-hover-after"; attachment.lifetime = .keepAlways; self.add(attachment)
            }
            state.points.removeLast()
        }
        schedule(1.25) {
            XCTAssertFalse(self.text(liveHost).contains("4242"), "被悬停日期删除后旧提示消失")
            completed = true; menu.cancelTracking()
        }
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        menu.popUp(positioning: nil, at: NSPoint(x: frame.minX + 30, y: frame.maxY - 60), in: nil)
        XCTAssertTrue(completed)
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
        prepareNativeTracking()
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
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        f.menu.popUp(positioning: nil, at: NSPoint(x: frame.midX, y: frame.midY), in: nil)
        XCTAssertTrue(completed, "原生菜单必须执行到本轮刷新完成，不能以跳过代替交互回归")
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

    /// Hub 汇总的四个桶从同一份快照进入两处现有布局；不修改账号页面的卡片结构。
    func testAntigravityHubSummaryRendersGeminiInAccountAndMenu() async throws {
        let f = try fixture(providers: [.antigravity])
        let body = Data(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"weekly","window":"weekly","remainingFraction":0.41},{"bucketId":"5h","window":"5h","remainingFraction":0.73}]},{"displayName":"Claude and GPT models","buckets":[{"bucketId":"weekly","window":"weekly","remainingFraction":1},{"bucketId":"5h","window":"5h","remainingFraction":1}]}]}"#.utf8)
        let models = try XCTUnwrap(AntigravityQuotaParser.summaryModels(from: body))
        let quota = ProviderQuotaData(models: models)
        f.model.providerQuotas[.antigravity] = ["fixture": quota]
        let accountView = AccountQuotaContent(settings: f.settings, provider: .antigravity,
            account: AccountQuotaPresentation(key: "fixture", email: email, status: "ready", statusColor: .green,
                authFile: nil, quotaData: quota, subscriptionInfo: nil), isLoading: false, displayStyle: .card)
            .environment(f.model).frame(width: 560)
        let host = NSHostingView(rootView: accountView)
        host.setFrameSize(host.intrinsicContentSize)
        let panel = window(host)
        defer { panel.close() }
        f.manager.menuWillOpen(f.menu)
        let menuHost = try XCTUnwrap(try card(f, provider: .antigravity).view)
        let menuPanel = window(menuHost)
        defer { menuPanel.close() }
        try await Task.sleep(for: .milliseconds(120))
        for (label, view) in [("账号页", host as NSView), ("菜单栏", menuHost)] {
            let value = text(view)
            XCTAssertTrue(value.contains("Gemini"), "\(label)应显示 Hub 响应中的 Gemini 额度")
            // 账号原布局读取既有共享口径；菜单使用隔离偏好。不修改用户显示偏好来凑断言。
            let expected = label == "账号页" ? MenuBarSettingsManager.shared.quotaDisplayMode.displayValue(from: 41) : 41
            XCTAssertTrue(value.contains(String(format: "%.0f", expected)), "\(label)应按原显示口径呈现同一 Gemini 桶")
            let attachment = XCTAttachment(data: try capture(view), uniformTypeIdentifier: "public.png")
            attachment.name = "Antigravity-" + label
            attachment.lifetime = .keepAlways
            add(attachment)
        }
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
        let scroll = try XCTUnwrap(scrollViews(in: host).first)
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
