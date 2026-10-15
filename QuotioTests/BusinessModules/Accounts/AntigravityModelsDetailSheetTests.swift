import AppKit
import SwiftUI
import Vision
import XCTest
@testable import QuotioPlus

/// 只验证账号业务内的全模型弹窗：使用内存模型、隔离偏好和原生窗口，不连接真实账号或 CPA。
/// 同时保留独立承载与真实 sheet 两条路径，避免给测试根视图强制尺寸后漏掉开窗尺寸协商。
@MainActor
final class AntigravityModelsDetailSheetTests: XCTestCase {
    // Observation 宏会在类型外生成扩展；嵌套夹具使用测试类内可见性，避免 private 限制宏展开。
    @Observable final class Presentation {
        var isPresented = false
        var models: [ModelQuota] = []
        var displayMode: QuotaDisplayMode = .remaining
        var hideSensitiveInfo = false
        var isLoading = false
    }

    private struct Presenter: View {
        @Bindable var presentation: Presentation

        var body: some View {
            Color.clear
                .sheet(isPresented: $presentation.isPresented) {
                    AntigravityModelsDetailSheet(email: "sample.person@example.com", models: presentation.models,
                        displayMode: presentation.displayMode, hideSensitiveInfo: presentation.hideSensitiveInfo)
                }
        }
    }

    private struct CardPresenter: View {
        @Bindable var presentation: Presentation
        let settings: MenuBarSettingsManager
        let model: QuotaViewModel

        var body: some View {
            AccountQuotaContent(settings: settings, provider: .antigravity,
                account: AccountQuotaPresentation(key: "fixture", email: "sample.person@example.com", status: "ready",
                    statusColor: .green, authFile: nil,
                    quotaData: ProviderQuotaData(models: presentation.models), subscriptionInfo: nil),
                isLoading: presentation.isLoading)
                .padding()
                .environment(model)
        }
    }

    private func models(_ count: Int) -> [ModelQuota] {
        (0..<count).map { index in
            ModelQuota(name: String(format: "Model-%03d", index), percentage: index == 0 ? 37 : 80,
                resetTime: index == 0 ? "2h" : "")
        }
    }

    private func window<V: View>(_ root: V, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderFront(nil)
        return window
    }

    private func waitForSheet(_ parent: NSWindow) async throws -> NSWindow {
        for _ in 0..<100 {
            if let sheet = parent.attachedSheet, sheet.contentView != nil {
                try await Task.sleep(for: .milliseconds(100))
                sheet.contentView?.layoutSubtreeIfNeeded()
                return sheet
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(parent.attachedSheet, "必须实际呈现 macOS sheet，不能只测试普通窗口")
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func image(_ view: NSView, name: String? = nil) throws -> CGImage {
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.bounds.width.isFinite && view.bounds.height.isFinite)
        // 独立测试窗口的 backingScaleFactor 可能为 1；用两倍栅格实际重绘，避免小号中文
        // 在本地 OCR 中因单像素笔画丢失而误判。点坐标和原窗口尺寸保持不变。
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let source = try XCTUnwrap(bitmap.cgImage)
        // 账号内容依赖窗口底色，本身允许透明。缓存视图后需补同一外观的窗口背景，
        // 否则 OCR 会把透明区按黑色处理，让正常的深色标题和“详情”按钮消失。
        let context = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        }
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        context.fill(bounds)
        context.draw(source, in: bounds)
        let result = try XCTUnwrap(context.makeImage())
        if let name {
            let attachment = XCTAttachment(data: try XCTUnwrap(NSBitmapImageRep(cgImage: result)
                .representation(using: .png, properties: [:])),
                uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return result
    }

    private func observations(_ view: NSView) throws -> [VNRecognizedTextObservation] {
        // SwiftUI 在当前原生单元测试宿主中不提供完整 AX 子树；用本地 Vision 读取实际绘制结果，
        // 核对文字、百分比和按钮位置，不把重新计算一份业务值当成渲染成功。
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // 将实际本地化标签作为识别词典，减少小号中文“额／颧”等形近字误识别；
        // 百分比和模型名称仍从绘制结果读取，不向识别器提供预期的额度值。
        request.customWords = ["quota.allModels".localized(), "dashboard.noQuotaData".localized(),
            "quota.details".localized()]
        // 读取当前实际语言，不修改 LanguageManager 单例或持久化语言配置。
        let language: String
        switch LanguageManager.shared.currentLanguage {
        case .english: language = "en-US"
        case .chinese: language = "zh-Hans"
        case .french: language = "fr-FR"
        case .vietnamese: language = "vi-VN"
        }
        let supported = try request.supportedRecognitionLanguages()
        // 首选实际 UI 语言，保留顺序；Set 的随机顺序会让英文识别器漏掉中文标签。
        request.recognitionLanguages = (language == "en-US" ? [language] : [language, "en-US"])
            .filter { supported.contains($0) }
        try VNImageRequestHandler(cgImage: image(view), options: [:]).perform([request])
        return request.results ?? []
    }

    private func text(_ view: NSView) throws -> String {
        try observations(view).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private func contains(_ rendered: String, _ expected: String) -> Bool {
        // Vision 可能在中文字符之间加空格；只规范化空白，不容忍丢失或替换实际业务文字。
        func compact(_ value: String) -> String { value.filter { !$0.isWhitespace } }
        return compact(rendered).contains(compact(expected))
    }

    private func click(_ point: NSPoint, in view: NSView) throws {
        let target = try XCTUnwrap(view.window)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            target.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: target.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)))
        }
    }

    func testStandaloneEmptyFiveNineModelsAcrossSizesWithoutSettingsEnvironment() async throws {
        let sizes = [NSSize(width: 480, height: 360), NSSize(width: 560, height: 440), NSSize(width: 960, height: 680)]
        for count in [0, 5, 9] {
            let root = AntigravityModelsDetailSheet(email: String(repeating: "long-account-", count: 12) + "@example.invalid",
                models: models(count), displayMode: .remaining, hideSensitiveInfo: false)
            let panel = window(root, size: sizes[0])
            defer { panel.close() }
            let host = try XCTUnwrap(panel.contentView)
            for size in sizes {
                panel.setContentSize(size)
                try await Task.sleep(for: .milliseconds(60))
                _ = try image(host, name: "models-\(count)-\(Int(size.width))x\(Int(size.height))")
                XCTAssertEqual(host.bounds.width, size.width, accuracy: 1)
                XCTAssertEqual(host.bounds.height, size.height, accuracy: 1)
                XCTAssertTrue(host.fittingSize.width.isFinite && host.fittingSize.height.isFinite)
                for scroll in scrollViews(in: host) {
                    XCTAssertLessThanOrEqual(scroll.documentView?.bounds.width ?? 0, scroll.contentView.bounds.width + 1,
                        "两列模型卡片不能撑破横向视口")
                }
            }
            let rendered = try text(host)
            XCTAssertTrue(contains(rendered, "quota.allModels".localized()), rendered)
            if count == 0 {
                // 空状态文案已在下面两个真实 sheet 路径核对；此组重点验证不同窗口尺寸，
                // 保留截图与无残留网格断言，避免宽画布上的小号中文 OCR 形近字误报。
                XCTAssertTrue(scrollViews(in: host).isEmpty)
            } else {
                XCTAssertTrue(rendered.contains("37%"), rendered)
            }
        }
    }

    func testExplicitDisplayValuesKeepPrivacyUnknownAndBothModes() async throws {
        let sample = [ModelQuota(name: "Alpha", percentage: 37, resetTime: "2h"),
            ModelQuota(name: "Unknown", percentage: -1, resetTime: ""),
            ModelQuota(name: "Empty", percentage: 0, resetTime: ""),
            ModelQuota(name: "Full", percentage: 100, resetTime: "")]
        let email = "sample.person@example.com"
        let host = NSHostingView(rootView: AntigravityModelsDetailSheet(email: email, models: sample,
            displayMode: .remaining, hideSensitiveInfo: false))
        let panel = window(Color.clear, size: NSSize(width: 560, height: 440))
        panel.contentView = host
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(80))
        let remaining = try text(host)
        XCTAssertTrue(remaining.contains("37%") && remaining.contains(email), remaining)
        XCTAssertFalse(remaining.contains("101%"), "未知额度不能成为实际百分比")

        host.rootView = AntigravityModelsDetailSheet(email: email, models: sample,
            displayMode: .used, hideSensitiveInfo: true)
        panel.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(80))
        let used = try text(host)
        XCTAssertTrue(used.contains("63%") && used.contains("0%") && used.contains("100%"), used)
        XCTAssertFalse(used.contains(email), "隐私输入必须覆盖标题邮箱")
        XCTAssertFalse(used.contains("101%"), used)
        _ = try image(host, name: "used-private-dark-unknown")
    }

    func testRealSheetRemainsStableAcrossEmptyRefreshResizeAndScroll() async throws {
        let state = Presentation()
        let parent = window(Presenter(presentation: state), size: NSSize(width: 520, height: 420))
        defer { parent.close() }
        state.isPresented = true
        let sheet = try await waitForSheet(parent)
        let host = try XCTUnwrap(sheet.contentView)
        // 初次创建即采用生产视图声明的理想尺寸，而非 automatic 的表单尺寸再回调修正。
        XCTAssertEqual(host.bounds.width, 560, accuracy: 1)
        XCTAssertEqual(host.bounds.height, 440, accuracy: 1)
        XCTAssertGreaterThanOrEqual(host.bounds.width, 480)
        XCTAssertGreaterThanOrEqual(host.bounds.height, 360)
        XCTAssertLessThanOrEqual(host.bounds.width, 960)
        XCTAssertLessThanOrEqual(host.bounds.height, 680)
        _ = try image(host, name: "native-sheet-initial-empty")
        let empty = try text(host)
        XCTAssertTrue(contains(empty, "dashboard.noQuotaData".localized()), empty)

        // 同一个打开的弹窗依次经历空、五项、九项和长列表；父窗口与 sheet 独立改变尺寸。
        for (count, size) in [(5, NSSize(width: 480, height: 360)), (9, NSSize(width: 840, height: 600))] {
            parent.setContentSize(NSSize(width: size.width + 100, height: size.height + 100))
            state.models = models(count)
            sheet.setContentSize(size)
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertTrue(parent.attachedSheet === sheet, "刷新不应关闭或重建弹窗")
            XCTAssertEqual(host.bounds.width, size.width, accuracy: 1)
            XCTAssertEqual(host.bounds.height, size.height, accuracy: 1)
            XCTAssertTrue(try text(host).contains("37%"))
            _ = try image(host, name: "native-sheet-\(count)-models")
        }
        state.models = models(60) + [ModelQuota(name: "ZZZ-LAST", percentage: 42, resetTime: "")]
        sheet.setContentSize(NSSize(width: 480, height: 360))
        try await Task.sleep(for: .milliseconds(120))
        let scroll = try XCTUnwrap(scrollViews(in: host).first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
        let lastOffset = document.bounds.height - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? lastOffset : 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(100))
        let tail = try text(host)
        XCTAssertTrue(tail.contains("ZZZ-LAST") && contains(tail, "quota.allModels".localized()), tail)
        _ = try image(host, name: "native-sheet-scrolled-last-model")

        state.models = []
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(parent.attachedSheet === sheet)
        _ = try image(host, name: "native-sheet-refreshed-empty")
        let refreshed = try text(host)
        XCTAssertTrue(contains(refreshed, "dashboard.noQuotaData".localized()), refreshed)
        XCTAssertTrue(scrollViews(in: host).isEmpty)
        // 关闭按钮始终固定在标题右侧；发送原生鼠标事件，验证刷新成空状态后仍能 dismiss。
        let closePoint = NSPoint(x: host.bounds.width - 28, y: host.isFlipped ? 34 : host.bounds.height - 34)
        try click(closePoint, in: host)
        for _ in 0..<50 where parent.attachedSheet != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(parent.attachedSheet)
        XCTAssertFalse(state.isPresented)
    }

    func testAccountCardPassesInjectedPreferencesIntoRealSheet() async throws {
        let suite = "quotio-antigravity-sheet-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = MenuBarSettingsManager(defaults: defaults)
        settings.quotaDisplayMode = .used
        settings.hideSensitiveInfo = true
        let vm = QuotaViewModel(startsBackgroundServices: false, menuBarSettings: settings)
        let state = Presentation()
        state.models = models(5)
        let root = CardPresenter(presentation: state, settings: settings, model: vm)
        let parent = window(root, size: NSSize(width: 560, height: 440))
        defer { parent.close() }
        try await Task.sleep(for: .milliseconds(100))
        let content = try XCTUnwrap(parent.contentView)
        _ = try image(content, name: "production-card-before-details")
        let cardText = try text(content)
        let details = try XCTUnwrap(observations(content).first {
            contains($0.topCandidates(1).first?.string ?? "", "quota.details".localized())
        }, "必须通过生产账号卡片的详情按钮打开：\(cardText)")
        let box = details.boundingBox
        try click(NSPoint(x: box.midX * content.bounds.width,
            y: (content.isFlipped ? 1 - box.midY : box.midY) * content.bounds.height), in: content)
        let sheet = try await waitForSheet(parent)
        let rendered = try text(XCTUnwrap(sheet.contentView))
        XCTAssertTrue(rendered.contains("63%"), rendered)
        XCTAssertFalse(rendered.contains("sample.person"), rendered)
        // 已打开弹窗也应跟随调用方偏好更新，不在弹窗私存一份显示状态。
        settings.quotaDisplayMode = .remaining
        settings.hideSensitiveInfo = false
        try await Task.sleep(for: .milliseconds(100))
        let updated = try text(XCTUnwrap(sheet.contentView))
        XCTAssertTrue(updated.contains("37%") && updated.contains("sample.person@example.com"), updated)

        // 走生产账号卡片的真实分支更新，防止只在始终存在的自定义 Presenter 中验证空状态。
        state.isLoading = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(parent.attachedSheet === sheet, "加载状态不能卸载弹窗宿主")
        state.models = []
        state.isLoading = false
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(parent.attachedSheet === sheet, "空列表不能卸载弹窗宿主")
        XCTAssertTrue(contains(try text(XCTUnwrap(sheet.contentView)), "dashboard.noQuotaData".localized()))
        state.models = models(9)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(parent.attachedSheet === sheet)
        XCTAssertTrue(try text(XCTUnwrap(sheet.contentView)).contains("37%"))
    }
}
