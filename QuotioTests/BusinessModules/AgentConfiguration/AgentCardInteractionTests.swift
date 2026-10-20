import AppKit
import SwiftUI
import Vision
import XCTest
@testable import QuotioPlus

/// 卡片只验证真实布局与交互，不重测版本检测网络和安装命令实现。
/// 使用临时配置服务和内存状态；终端命令注入失败闭包，禁止测试实际升级／卸载本机客户端。
@MainActor
final class AgentCardInteractionTests: XCTestCase {
    private func model() throws -> AgentSetupViewModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentCard-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return AgentSetupViewModel(configurationService: AgentConfigurationService(homeDirectory: root),
            fetchModels: { _, _ in [] }, launchCommand: { _ in
                throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture terminal failure"])
            })
    }

    private var status: AgentStatus {
        AgentStatus(agent: .claudeCode, installed: true, configured: true,
                    binaryPath: "/fixture/install/source/claude", version: "2.1.292 (Claude Code)",
                    installMethod: .homebrewCask(name: "claude-code"))
    }

    private func show(_ vm: AgentSetupViewModel, width: CGFloat = 600, scheme: ColorScheme = .light,
                      onConfigure: @escaping () -> Void = {}) async throws -> NSWindow {
        let root = AgentCard(status: status, viewModel: vm, onConfigure: onConfigure)
            .padding(12).environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 160, y: 220, width: width, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(80))
        return window
    }

    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2),
            pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        // NSPopover 的材质背景由 AppKit 单独合成，cacheDisplay 只提供透明文字层。
        // 合成当前外观的窗口底色后再做 OCR，避免把透明底上的黑字误读成“没有内容”。
        let image = try XCTUnwrap(rep.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var background = CGColor(gray: 1, alpha: 1)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)?.cgColor ?? background
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(background); context.fill(bounds); context.draw(image, in: bounds)
        let opaque = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        opaque.size = view.bounds.size
        return opaque
    }

    private func text(_ view: NSView, attachment: String? = nil) throws -> String {
        let rep = try bitmap(view)
        if let attachment {
            let evidence = XCTAttachment(data: try XCTUnwrap(rep.representation(using: .png, properties: [:])),
                                         uniformTypeIdentifier: "public.png")
            evidence.name = attachment; evidence.lifetime = .keepAlways; add(evidence)
        }
        return try recognize(rep).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func recognize(_ rep: NSBitmapImageRep) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        // 小号文字中的 f/t、i/l/1 容易被 OCR 混淆，提供界面词汇，不替代真实绘制识别。
        request.customWords = ["v2.1.292", "Configured", "fixture", "failure", "install", "/fixture/install/source/claude",
                               "agents.configured".localized(), "agents.installationInfo.path".localized()]
        try VNImageRequestHandler(cgImage: XCTUnwrap(rep.cgImage), options: [:]).perform([request])
        return request.results ?? []
    }
    private func canonical(_ value: String) -> String {
        // 仅用于小号文字的绘制验证：Vision 会将 i/l/1、f/t、v/y 及小号汉字（如“置”与“量”）识别为相邻字形，
        // 归并后仍要求完整内容出现，截断标题无法通过。模型状态、回调和粘贴板断言均使用精确原值。
        String(value.lowercased().filter { $0.isLetter || $0.isNumber }.map { character in
            switch character {
            case "i", "l", "1": return Character("i")
            case "f", "t": return Character("f")
            case "量": return Character("置")
            case "y": return Character("v")
            default: return character
            }
        })
    }

    private func foreignTranslation(_ key: String) throws -> String {
        for language in Bundle.main.localizations {
            guard let path = Bundle.main.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) else { continue }
            let value = bundle.localizedString(forKey: key, value: nil, table: nil)
            if value != key && value != key.localized() { return value }
        }
        throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "缺少跨语言验证资源"])
    }

    func testNormalCardsKeepTwoInformationLinesAndFlatActionRowsAcrossWidthsAndThemes() async throws {
        let vm = try model()
        let previousLanguageResult = try foreignTranslation("agents.latestVersion")
        vm.updateMessages[.claudeCode] = previousLanguageResult
        var configured = 0
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(540), 860] {
                let window = try await show(vm, width: width, scheme: scheme, onConfigure: { configured += 1 })
                defer { window.close() }
                let host = try XCTUnwrap(window.contentView)
                let rendered = try text(host, attachment: "客户端卡片-\(scheme)-\(Int(width))")
                let actual = canonical(rendered)
                for expected in ["Claude Code", "v2.1.292", "Homebrew", "agents.configured".localized(), "agents.configure".localized(), "agents.open".localized()] {
                    XCTAssertTrue(actual.contains(canonical(expected)), "应显示 \(expected)，实际：\(rendered)")
                }
                XCTAssertFalse(actual.contains(canonical("agents.latestVersion".localized())))
                XCTAssertFalse(actual.contains(canonical(previousLanguageResult)), "旧语言的最新结果也不能作为警告常驻")
                XCTAssertFalse(rendered.contains("/fixture/"))
                XCTAssertFalse(rendered.contains("official"))
                XCTAssertFalse(rendered.contains("Cask"))
                // 原生宿主测量内容高度，防止把旧三行内容仅藏到一个固定高度的裁剪框中。
                XCTAssertLessThanOrEqual(host.fittingSize.height, 112, "含外部24pt验证留白，两排操作应保持紧凑且完整显示")
                if width == 540 && scheme == .light {
                    try clickText("agents.configure".localized(), in: host)
                    XCTAssertEqual(configured, 1, "直达配置仍调用原回调")
                }
            }
        }
        XCTAssertEqual(vm.updateMessages[.claudeCode], previousLanguageResult, "显示不能清除原检查结果")
    }

    func testUpdateCheckingAvailableAndFailureKeepReadableActions() async throws {
        let vm = try model()
        let window = try await show(vm, width: 540)
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)
        vm.isCheckingUpdates[.claudeCode] = true
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(canonical(try text(host)).contains(canonical("agents.checkUpdate.checking".localized())))
        vm.isCheckingUpdates[.claudeCode] = false
        vm.remoteVersions[.claudeCode] = "2.2.0"
        let foreignAvailable = String(format: try foreignTranslation("agents.updateAvailable"), "2.2.0")
        vm.updateMessages[.claudeCode] = foreignAvailable
        try await Task.sleep(for: .milliseconds(80))
        let available = try text(host, attachment: "客户端卡片-窄窗口-可升级")
        XCTAssertTrue(canonical(available).contains(canonical("agents.upgrade".localized())))
        XCTAssertTrue(canonical(available).contains("v220"))
        XCTAssertTrue(canonical(available).contains(canonical("agents.configure".localized())))
        XCTAssertTrue(canonical(available).contains(canonical("agents.open".localized())))
        XCTAssertTrue(canonical(available).contains(canonical("Claude Code")), available)
        XCTAssertTrue(canonical(available).contains(canonical("agents.configured".localized())), available)
        XCTAssertFalse(canonical(available).contains(canonical(foreignAvailable)), "成功结果随当前界面展示，不能把旧语言文案当作警告")
        // 调用原生命周期入口模拟终端失败，验证错误仍被新布局呈现，而非只留一个升级按钮。
        await vm.upgradeAgent(status)
        try await Task.sleep(for: .milliseconds(80))
        let failure = try text(host, attachment: "客户端卡片-窄窗口-失败提示")
        XCTAssertTrue(canonical(failure).contains(canonical("terminal failure")), failure)
        XCTAssertEqual(vm.remoteVersions[.claudeCode], "2.2.0")
        XCTAssertEqual(vm.updateMessages[.claudeCode], "fixture terminal failure")
    }

    /// 依据真实绘制文本定位目标，发送本窗口事件；图标复制按钮使用路径行的纵坐标。
    private func clickText(_ title: String, in view: NSView, trailingControl: Bool = false) throws {
        let observations = try recognize(bitmap(view))
        var target: CGRect?
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first,
                  let range = candidate.string.range(of: title, options: .caseInsensitive) else { continue }
            if range.lowerBound != candidate.string.startIndex {
                let prev = candidate.string[candidate.string.index(before: range.lowerBound)]
                if prev.isLetter || prev.isNumber { continue }
            }
            if range.upperBound != candidate.string.endIndex {
                let next = candidate.string[range.upperBound]
                if next.isLetter || next.isNumber { continue }
            }
            // 一个 OCR 行可能合并多个按钮；精确取标题的子矩形，且不能把 Configure 命中 Configured 或 已配置。
            target = try candidate.boundingBox(for: range)?.boundingBox ?? observation.boundingBox
            break
        }
        let rect = try XCTUnwrap(target, title)
        let x = trailingControl ? view.bounds.maxX - 39 : view.bounds.minX + rect.midX * view.bounds.width
        let y = view.isFlipped ? view.bounds.maxY - rect.midY * view.bounds.height : view.bounds.minY + rect.midY * view.bounds.height
        let window = try XCTUnwrap(view.window)
        let point = view.convert(NSPoint(x: x, y: y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        }
    }

    /// 只在本测试窗口点击下排图标，不移动系统鼠标，也不再依赖已经移除的原生更多菜单。
    /// 横向取卡片右侧工具条的 26pt 按钮中心，纵向以真实绘制的配置按钮为锚点定位下排。
    private func clickUtility(_ index: Int, in window: NSWindow) throws {
        let host = try XCTUnwrap(window.contentView)
        let title = "agents.configure".localized()
        var rect: CGRect?
        for observation in try recognize(bitmap(host)) {
            guard let candidate = observation.topCandidates(1).first,
                  let range = candidate.string.range(of: title, options: .caseInsensitive),
                  range.upperBound == candidate.string.endIndex || !candidate.string[range.upperBound].isLetter else { continue }
            rect = try candidate.boundingBox(for: range)?.boundingBox ?? observation.boundingBox
            break
        }
        let anchor = try XCTUnwrap(rect, title)
        let primaryY = host.isFlipped ? host.bounds.maxY - anchor.midY * host.bounds.height
                                     : host.bounds.minY + anchor.midY * host.bounds.height
        let local = NSPoint(x: host.bounds.maxX - 26 - 13 - CGFloat(3 - index) * 32,
                            y: primaryY + (host.isFlipped ? 34 : -34))
        let point = host.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        }
    }

    func testFlatInstallationInformationEntryAndPathCopyRemainAvailable() async throws {
        let vm = try model()
        vm.updateMessages[.claudeCode] = "agents.latestVersion".localized()
        let window = try await show(vm)
        defer { window.close() }
        let host = try XCTUnwrap(window.contentView)
        _ = try text(host, attachment: "客户端平铺工具条")
        let existing = Set(NSApp.windows.map(\.windowNumber))
        try clickUtility(1, in: window)
        try await Task.sleep(for: .milliseconds(150))
        let panel = try XCTUnwrap(NSApp.windows.first { !existing.contains($0.windowNumber) && $0.isVisible }, "安装信息应可打开")
        // Popover 由 SwiftUI/NSPopover 持有，随宿主窗口退出；不能直接 close 系统创建的窗口。
        let info = try text(XCTUnwrap(panel.contentView), attachment: "客户端安装信息")
        XCTAssertTrue(canonical(info).contains(canonical("2.1.292 (Claude Code)")), info)
        XCTAssertTrue(canonical(info).contains("homebrewcask"), info)
        XCTAssertTrue(canonical(info).contains(canonical("/fixture/install/source/claude")), info)
        // 复制使用真实按钮与 NSPasteboard；仅临时保存原数据用于恢复，不输出或持久化用户粘贴板。
        let pasteboard = NSPasteboard.general
        let originals = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { pasteboard.clearContents(); pasteboard.writeObjects(originals) }
        try clickText("agents.installationInfo.path".localized(), in: XCTUnwrap(panel.contentView), trailingControl: true)
        XCTAssertEqual(pasteboard.string(forType: .string), status.binaryPath, "复制必须保留精确路径")
        XCTAssertTrue(vm.isCheckingUpdates.isEmpty, "查看安装信息不能触发扫描或检查网络")
        XCTAssertEqual(vm.updateMessages[.claudeCode], "agents.latestVersion".localized())
    }

    func testUninstallStillRequiresConfirmationAndCancelDoesNotExecuteCommand() async throws {
        let vm = try model()
        let window = try await show(vm)
        defer { window.close() }
        let existing = Set(NSApp.windows.map(\.windowNumber))
        try clickUtility(3, in: window)
        try await Task.sleep(for: .milliseconds(150))
        let confirmation = try XCTUnwrap(window.attachedSheet ?? NSApp.windows.first { !existing.contains($0.windowNumber) && $0.isVisible })
        let content = try XCTUnwrap(confirmation.contentView)
        let rendered = try text(content)
        XCTAssertTrue(canonical(rendered).contains(canonical("action.cancel".localized())), rendered)
        XCTAssertNil(vm.updateMessages[.claudeCode], "打开确认不能执行卸载")
        try clickText("action.cancel".localized(), in: content)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(confirmation.isVisible, "取消应关闭确认")
        XCTAssertNil(vm.updateMessages[.claudeCode], "取消不得调用假终端，更不能执行真实命令")
    }
}
