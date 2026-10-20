import AppKit
import SwiftUI
import Vision
import XCTest
@testable import QuotioPlus

/// 从生产列表点击真实“配置／应用”按钮，覆盖首次弹窗与关闭重开时的身份传递。
/// 配置和 Shell 均写入临时目录，目录与客户端检测离线注入；不启动 CPA、不改用户配置。
@MainActor
final class AgentConfigurationApplyInteractionTests: XCTestCase {
    private actor PreviewRecorder {
        private(set) var configuration: AgentConfiguration?
        func record(_ configuration: AgentConfiguration) { self.configuration = configuration }
    }
    private struct Fixture {
        let root: QuotaViewModel
        let setup: AgentSetupViewModel
        let service: AgentConfigurationService
        let path: URL
        let original: Data
    }

    private func fixture() throws -> Fixture {
        let suite = "claude-apply-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let path = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 刻意没有受管菜单版本：验证旧配置首次应用也只有一个普通保存入口，备份自动生成。
        let original = Data(#"{"model":"opus","unknown-root":{"keep":true},"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:8317","ANTHROPIC_AUTH_TOKEN":"fixture-client-key","ANTHROPIC_DEFAULT_OPUS_MODEL":"live-one","ANTHROPIC_DEFAULT_SONNET_MODEL":"live-one","ANTHROPIC_DEFAULT_HAIKU_MODEL":"live-one"}}"#.utf8)
        try original.write(to: path)
        let root = QuotaViewModel(directAuthService: DirectAuthFileService(authDirectory: home.appendingPathComponent("auth")),
            startsBackgroundServices: false, modeManager: OperatingModeManager(defaults: defaults),
            menuBarSettings: MenuBarSettingsManager(defaults: defaults), refreshSettings: RefreshSettingsManager(defaults: defaults),
            warmupSettings: WarmupSettingsManager(defaults: defaults),
            notificationManager: NotificationManager(testDefaults: defaults, notificationSink: { _ in }))
        root.apiKeys = ["fixture-client-key"]
        let manager = root.proxyManager, previousStatus = manager.proxyStatus, previousSession = manager.runtimeSessionID
        manager.setRuntimeStateForTesting(running: false, sessionID: UUID())
        let service = AgentConfigurationService(homeDirectory: home)
        let setup = AgentSetupViewModel(configurationService: service,
            shellManager: ShellProfileManager(profilePath: { _ in home.appendingPathComponent("profile").path }),
            fetchModels: { _, _ in ["live-one", "live-two"].map {
                AvailableModel(id: $0, name: $0, provider: "fixture", isDefault: false)
            } }, configurationEndpoint: { "http://127.0.0.1:8317" }, detectAgentStatuses: { _ in
                [AgentStatus(agent: .claudeCode, installed: true, configured: true, binaryPath: "/fixture/claude",
                    version: "2.1.292 (Claude Code)", installMethod: .homebrewCask(name: "claude-code"))]
            })
        root.setAgentSetupViewModelForTesting(setup)
        let detectionKeys = ["configured", "lastConfigured"].map { "agent.\(CLIAgent.claudeCode.rawValue)." + $0 }
        let detectionValues = detectionKeys.map { UserDefaults.standard.object(forKey: $0) }
        addTeardownBlock { @MainActor in
            setup.dismissConfiguration(sessionID: setup.configurationSessionID)
            manager.setRuntimeStateForTesting(running: previousStatus.running, sessionID: previousSession)
            for (key, value) in zip(detectionKeys, detectionValues) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        return Fixture(root: root, setup: setup, service: service, path: path, original: original)
    }

    private func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(message)
    }

    private func observations(_ view: NSView, modelWords: [String] = []) throws -> [VNRecognizedTextObservation] {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.customWords = ["agents.configure".localized(), "agents.apply".localized(), "action.done".localized()]
            + modelWords
        if !modelWords.isEmpty { request.usesLanguageCorrection = false }
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        return request.results ?? []
    }

    private func click(_ title: String, in view: NSView, trailingButton: Bool = true) throws {
        // 只发送本测试窗口内的鼠标事件，不移动系统指针；按实际绘制子矩形命中按钮。
        // 严格排除 Configured／已配置，防止状态标签被误当成 Configure／配置按钮。
        let texts = try observations(view)
        for observation in texts {
            guard let candidate = observation.topCandidates(1).first,
                  let range = candidate.string.range(of: title, options: .caseInsensitive) else { continue }
            if range.lowerBound != candidate.string.startIndex {
                let before = candidate.string[candidate.string.index(before: range.lowerBound)]
                if before.isLetter || before.isNumber {
                    // 若目标为纯中文词汇（如“配置”），前置的 ASCII 字符（如 C/O）系 OCR 误识紧随的图标，不排除真实配置按钮。
                    if before.isASCII && title.allSatisfy({ $0.unicodeScalars.first?.properties.isIdeographic == true }) {
                        // 允许命中带图标字形的按钮文本
                    } else {
                        continue
                    }
                }
            }
            if range.upperBound != candidate.string.endIndex {
                let after = candidate.string[range.upperBound]
                if after.isLetter || after.isNumber { continue }
            }
            let rect = try candidate.boundingBox(for: range)?.boundingBox ?? observation.boundingBox
            // 本回归的配置、应用和完成按钮都在右侧；排除页面左上方 Configure CLI agents 的介绍文字。
            guard !trailingButton || rect.midX > 0.5 else { continue }
            let y = view.isFlipped ? view.bounds.maxY - rect.midY * view.bounds.height : view.bounds.minY + rect.midY * view.bounds.height
            let point = view.convert(NSPoint(x: rect.midX * view.bounds.width, y: y), to: nil)
            let window = try XCTUnwrap(view.window)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
            }
            return
        }
        XCTFail("未找到按钮 \(title)，实际：\(texts.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | "))")
    }

    func testFirstPresentationAndReopenApplyEditsWithoutExtraMigrationAction() async throws {
        let f = try fixture()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 920),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AgentSetupScreen().environment(f.root))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await waitUntil("必须加载离线客户端卡片") { !f.setup.isLoading && !f.setup.agentStatuses.isEmpty }
        try await Task.sleep(for: .milliseconds(150))
        let list = try XCTUnwrap(window.contentView)
        var previousSession: UUID?
        for model in ["live-two", "live-one"] {
            try click("agents.configure".localized(), in: list)
            XCTAssertEqual(f.setup.selectedAgent, .claudeCode, "必须命中卡片真实配置动作")
            try await waitUntil("实际列表必须打开原生配置弹窗") { window.attachedSheet != nil }
            try await waitUntil("已有配置和当前模型目录必须回填完成") { !f.setup.isLoadingConfiguration && !f.setup.isFetchingModels }
            try await Task.sleep(for: .milliseconds(150))
            let sheet = try XCTUnwrap(window.attachedSheet)
            let content = try XCTUnwrap(sheet.contentView)
            let session = f.setup.configurationSessionID
            if let previousSession { XCTAssertNotEqual(session, previousSession) }
            previousSession = session
            f.setup.updateModelSlot(.opus, model: model)
            XCTAssertNil(f.setup.configurationValidationMessage)
            try await Task.sleep(for: .milliseconds(80))
            // 新旧文件均直接点击同一个“应用”，不允许恢复“备份并迁移”的独立操作。
            try click("agents.apply".localized(), in: content)
            try await waitUntil("第一次点击应用就应进入保存结果，不能静默拒绝或要求取消重开") {
                f.setup.configResult != nil || f.setup.errorMessage != nil
            }
            XCTAssertNil(f.setup.errorMessage)
            guard let result = f.setup.configResult else { return XCTFail("应用没有返回结果，需检查弹窗和 VM 的会话 ID 是否一致") }
            XCTAssertTrue(result.success, result.error ?? "保存失败")
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.path)) as? [String: Any])
            XCTAssertEqual((saved["env"] as? [String: Any])?["ANTHROPIC_DEFAULT_OPUS_MODEL"] as? String, model)
            XCTAssertEqual((saved["unknown-root"] as? [String: Bool])?["keep"], true)
            let backups = await f.service.listBackups(agent: .claudeCode)
            XCTAssertFalse(backups.isEmpty, "普通应用自动备份，不需要额外迁移操作")
            if model == "live-two" {
                XCTAssertTrue(try backups.contains { try Data(contentsOf: URL(fileURLWithPath: $0.path)) == f.original })
            }
            try await Task.sleep(for: .milliseconds(100))
            try click("action.done".localized(), in: content)
            try await waitUntil("完成后应关闭本轮弹窗") { window.attachedSheet == nil }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// 迟到的 CPA 客户端 key 只允许补入同源草稿，不能因外部配置缺少凭据就跨服务共享认证。
    func testExternalSourceWithoutKeyNeverBorrowsCurrentCPAKeyOnRetry() async throws {
        let f = try fixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.path)) as? [String: Any])
        var env = try XCTUnwrap(object["env"] as? [String: String])
        env["ANTHROPIC_BASE_URL"] = "https://external.invalid/gateway"
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        object["env"] = env
        try JSONSerialization.data(withJSONObject: object).write(to: f.path)
        f.setup.quotaViewModel = f.root
        let session = f.setup.startConfiguration(for: .claudeCode, apiKey: "current-cpa-key")
        try await waitUntil("外部配置回填必须结束") { !f.setup.isLoadingConfiguration && !f.setup.isFetchingModels }
        XCTAssertEqual(f.setup.currentConfiguration?.proxyURL, "https://external.invalid/gateway/v1")
        XCTAssertEqual(f.setup.currentConfiguration?.apiKey, "")
        XCTAssertFalse(f.setup.usesCPAModelService)
        let externalRetry = await f.setup.loadModels(forceRefresh: true, sessionID: session)
        XCTAssertFalse(externalRetry)
        XCTAssertEqual(f.setup.currentConfiguration?.apiKey, "")
        // 用户明确改回当前 CPA 后，原重试补 key 能力仍可用。
        f.setup.currentConfiguration?.proxyURL = "http://127.0.0.1:8317/v1"
        let cpaRetry = await f.setup.loadModels(forceRefresh: true, sessionID: session)
        XCTAssertTrue(cpaRetry)
        XCTAssertEqual(f.setup.currentConfiguration?.apiKey, "fixture-client-key")
    }

    /// 使用完整生产配置页，预览必须在高级区仍收起时可独立展开；只读操作不得写入真实或临时配置。
    func testModelMenuPreviewIsIndependentWhileAdvancedRemainsCollapsed() async throws {
        let f = try fixture()
        let session = f.setup.startConfiguration(for: .claudeCode, apiKey: "fixture-client-key")
        try await waitUntil("离线回填应完成") { !f.setup.isLoadingConfiguration && !f.setup.isFetchingModels }
        let window = NSWindow(contentRect: NSRect(x: 120, y: 100, width: 720, height: 780),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AgentConfigSheet(viewModel: f.setup, agent: .claudeCode, configurationSessionID: session))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let before = try JSONEncoder().encode(XCTUnwrap(f.setup.currentConfiguration))
        let diskBefore = try Data(contentsOf: f.path)
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        // 滚动完整配置页，保留原来的固定页脚。只对本窗口内容操作，不改变其他页面或系统鼠标。
        let scroll = try XCTUnwrap(scrollViews(host).max { $0.frame.width < $1.frame.width })
        let document = try XCTUnwrap(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped
            ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(100))
        let text = try observations(host).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("agents.claudePicker.preview".localized()), text)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("agents.claude.advanced.context.placeholder".localized()))
        try click("agents.claudePicker.preview".localized(), in: host, trailingButton: false)
        try await Task.sleep(for: .milliseconds(250))
        let expanded = try observations(host).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(expanded.localizedCaseInsensitiveContains("Default"), expanded)
        XCTAssertFalse(expanded.localizedCaseInsensitiveContains("agents.claude.advanced.context.placeholder".localized()))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(f.setup.currentConfiguration))) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: before) as? NSDictionary)
        XCTAssertEqual(try Data(contentsOf: f.path), diskBefore)
    }

    /// 整份草稿是原弹窗预览任务的唯一输入；此前漏掉的 FORCE、上下文、压缩和逐槽 1M 均须刷新。
    /// 通过真实 SwiftUI 宿主观察生成调用，不测试另造的字段数组或改变用户配置。
    func testManualPreviewObservesCompleteDraftWithoutFieldSpecificCallbacks() async throws {
        let f = try fixture()
        let recorder = PreviewRecorder()
        let setup = AgentSetupViewModel(configurationService: f.service,
            generateConfiguration: { _, configuration, mode, storage, _ in
                XCTAssertEqual(mode, .manual)
                XCTAssertEqual(storage, .jsonOnly)
                await recorder.record(configuration)
                return .success(type: .both, mode: .manual, instructions: "preview-fixture")
            })
        setup.selectedAgent = .claudeCode
        setup.currentConfiguration = AgentConfiguration(agent: .claudeCode,
            proxyURL: "https://fixture.invalid/v1", apiKey: "fixture-only-key")
        let host = NSHostingView(rootView: AgentConfigSheet(viewModel: setup, agent: .claudeCode))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 720, height: 780),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        setup.configStorageOption = .shellOnly
        setup.configurationMode = .manual

        func expectLatestDraft() async throws {
            let expected = try XCTUnwrap(setup.currentConfiguration)
            for _ in 0..<100 {
                if await recorder.configuration == expected { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("手动预览未跟随最新完整草稿")
        }
        try await expectLatestDraft()
        setup.updateClaudeSubagentForce(true)
        try await expectLatestDraft()
        setup.currentConfiguration?.claudeDefaultModel1M = true
        try await expectLatestDraft()
        setup.currentConfiguration?.claudeModel1M[.haiku] = true
        try await expectLatestDraft()
        setup.currentConfiguration?.claudeMaxContextTokens = 300_001
        try await expectLatestDraft()
        setup.currentConfiguration?.claudeAutoCompactPercentage = 61
        try await expectLatestDraft()
        setup.currentConfiguration?.claudeDisableAutoCompact = true
        try await expectLatestDraft()
        setup.currentConfiguration?.claudeGatewayModelDiscovery = true
        try await expectLatestDraft()
        setup.currentConfiguration?.setupMode = .defaultSetup
        try await expectLatestDraft()
        XCTAssertEqual(try Data(contentsOf: f.path), f.original, "纯预览不得写入配置")
    }

    /// 真实 FORCE-only 页面：默认收起但显示覆盖摘要，展开后可直接关闭，模型缺省不会隐藏控件。
    func testForceOnlySubagentShowsCollapsedStatusAndCanBeDisabledInAdvanced() async throws {
        let f = try fixture()
        f.setup.selectedAgent = .claudeCode
        f.setup.currentConfiguration = AgentConfiguration(agent: .claudeCode,
            proxyURL: "https://fixture.invalid/v1", apiKey: "fixture-only-key")
        f.setup.currentConfiguration?.claudeSubagentModelForce = "1"
        let before = f.setup.currentConfiguration
        var changes = 0
        let host = NSHostingView(rootView: ClaudeSubagentModelSection(viewModel: f.setup, onChange: { changes += 1 })
            .padding(20).frame(width: 680, height: 330, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 680, height: 330),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let forceTitle = "agents.claudeSubagent.force.title".localized()
        func forceObservations() throws -> [VNRecognizedTextObservation] {
            try observations(host, modelWords: [forceTitle, "agents.claude.advanced".localized()])
        }
        // 只用于核对屏幕文案的 i/l 字形归一；开关命中使用真正 NSSwitch 的 frame。
        func normalizedOCR(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .replacingOccurrences(of: "l", with: "i").filter { !$0.isWhitespace }
        }
        func forceRows() throws -> [VNRecognizedTextObservation] {
            try forceObservations().filter {
                $0.topCandidates(1).first.map { normalizedOCR($0.string).contains(normalizedOCR(forceTitle)) } == true
            }
        }
        XCTAssertEqual(try forceRows().count, 1, "默认收起时应只有覆盖摘要，不能常驻显示强制开关")
        XCTAssertEqual(f.setup.currentConfiguration, before, "显示强制状态不应规范化历史原值")
        XCTAssertEqual(changes, 0)
        try click("agents.claude.advanced".localized(), in: host, trailingButton: false)
        try await Task.sleep(for: .milliseconds(250))
        let rows = try forceRows()
        XCTAssertEqual(rows.count, 2, "展开后必须同时显示覆盖摘要和实际开关")
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        let nativeViews = views(host)
        let viewFrames = nativeViews.map { "\(type(of: $0)): \($0.convert($0.bounds, to: host))" }.joined(separator: " | ")
        let snapshot = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: snapshot)
        let snapshotURL = FileManager.default.temporaryDirectory.appendingPathComponent("claude-force-expanded-\(UUID().uuidString).png")
        try XCTUnwrap(snapshot.representation(using: .png, properties: [:])).write(to: snapshotURL)
        // 原生 small switch 紧跟文字，宽度不占满整行。必须找到其真正子控件，
        // 不把 AX 缺失或自绘实现悄悄回退为猜测文字左右坐标；失败时保留截图和完整 frame 诊断。
        let targetView = nativeViews.first { $0 is NSSwitch }
            ?? nativeViews.first { ($0 as? NSButton)?.title == forceTitle }
        let nativeToggle = try XCTUnwrap(targetView, "缺少真实开关，视图：\(viewFrames)，截图：\(snapshotURL.path)")
        let target = nativeToggle.convert(NSPoint(x: nativeToggle.bounds.midX, y: nativeToggle.bounds.midY), to: host)
        let point = host.convert(target, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(f.setup.currentConfiguration?.claudeSubagentModelForce, "",
            "实际点击 \(target)，视图：\(viewFrames)，截图：\(snapshotURL.path)")
        XCTAssertNil(f.setup.currentConfiguration?.claudeSubagentModel)
        XCTAssertEqual(changes, 1)
        if f.setup.currentConfiguration?.claudeSubagentModelForce == "", changes == 1 {
            try? FileManager.default.removeItem(at: snapshotURL)
        }
    }

    /// 显式角色覆盖与角色自身开关独立；实际目标说明必须包含覆盖，不只在标题中显示“1M”。
    func testExplicitRoleOneMillionSelectionShowsFullRequestInPicker() async throws {
        let host = NSHostingView(rootView: AgentDefaultModelPicker(agent: .claudeCode,
                selectedModel: .constant("sonnet[1m]"),
                availableModels: [.init(id: "live-one", name: "live-one", provider: "fixture", isDefault: false)],
                isFetchingModels: false, onRefresh: {}, slotModels: [.sonnet: "live-one"], showsHeader: false)
            .padding(16).frame(width: 620, height: 200, alignment: .topLeading)
            // 独立宿主补上真实窗口背景，避免透明位图被 Vision 当作黑底，漏掉黑色正文。
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 100, width: 620, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(120))
        let text = try observations(host, modelWords: ["live-one[1m]", "Sonnet"])
            .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            .folding(options: .widthInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertTrue(text.lowercased().contains("[1m]"), text)
    }

    /// 从临时磁盘回填“同型号、不同 1M”的真实配置，验证只读上下文和原保存入口。
    /// 核对实际绘制的行与无开关状态，防止只读展示漏掉历史后缀或意外修改原草稿。
    func testSameModelRoleSuffixesAndOneMillionControlsRoundTripIndependently() async throws {
        let f = try fixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: f.original) as? [String: Any])
        var env = try XCTUnwrap(object["env"] as? [String: String])
        env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = "live-one[1m]"
        object["env"] = env; object["model"] = "sonnet"
        try JSONSerialization.data(withJSONObject: object).write(to: f.path)
        let diskBefore = try Data(contentsOf: f.path)
        let session = f.setup.startConfiguration(for: .claudeCode, apiKey: "fixture-client-key")
        try await waitUntil("已有独立 1M 设置必须回填完成") { !f.setup.isLoadingConfiguration && !f.setup.isFetchingModels }
        XCTAssertEqual(f.setup.currentConfiguration?.claudeRequestModel(for: .sonnet), "live-one")
        XCTAssertEqual(f.setup.currentConfiguration?.claudeRequestModel(for: .haiku), "live-one[1m]")
        var changes = 0
        let host = NSHostingView(rootView: ClaudeModelMappingView(viewModel: f.setup, configurationSessionID: session,
            onOneMillionChange: { changes += 1 }).padding(16).frame(width: 680, height: 540, alignment: .top))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 100, width: 680, height: 540),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(120))

        func entries() throws -> [VNRecognizedTextObservation] {
            try observations(host, modelWords: ["Opus", "Fable", "Sonnet", "Haiku", "live-one", "live-one[1m]", "1M"])
        }
        func labelRect(_ label: String, in entries: [VNRecognizedTextObservation]) throws -> CGRect {
            // Vision 可能把同一行的角色和模型合成一项；按实际文字子矩形定位，不能要求独立 observation。
            for entry in entries {
                guard let text = entry.topCandidates(1).first,
                      let range = text.string.range(of: label, options: .caseInsensitive) else { continue }
                let rect = try text.boundingBox(for: range)?.boundingBox ?? entry.boundingBox
                // “跟随 Sonnet”也包含角色词；角色所在的固定左列才是目标行，不能误点默认行。
                guard rect.minX < 0.2 else { continue }
                return rect
            }
            return try XCTUnwrap(nil, "未找到 \(label)：\(entries.compactMap { $0.topCandidates(1).first?.string })")
        }
        func rowText(_ role: ModelSlot) throws -> String {
            let entries = try entries()
            let label = try labelRect(role.rawValue.capitalized, in: entries)
            return entries.filter { abs($0.boundingBox.midY - label.midY) < 0.018 }
                .compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                .folding(options: .widthInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        }
        let ordinary = try rowText(.sonnet), long = try rowText(.haiku)
        XCTAssertFalse(ordinary.lowercased().contains("[1m]"), ordinary)
        XCTAssertTrue(long.lowercased().contains("[1m]"), long)
        XCTAssertEqual(changes, 0, "只读自动标识不能改写存量上下文声明")
        XCTAssertEqual(try Data(contentsOf: f.path), diskBefore)
        // 子代理 FORCE 高级区默认收起，映射表本身已没有任何 NSSwitch，不能留下可操作的 1M 开关。
        func switches(_ view: NSView) -> [NSSwitch] {
            (view as? NSSwitch).map { [$0] } ?? view.subviews.flatMap { switches($0) }
        }
        XCTAssertTrue(switches(host).isEmpty)
        XCTAssertFalse(try XCTUnwrap(f.setup.currentConfiguration).usesClaude1MContext(for: .sonnet))
        XCTAssertTrue(try XCTUnwrap(f.setup.currentConfiguration).usesClaude1MContext(for: .haiku))
        XCTAssertFalse(try XCTUnwrap(f.setup.currentConfiguration).claudeDefaultUses1MContext)

        await f.setup.applyConfiguration(sessionID: session)
        XCTAssertTrue(f.setup.configResult?.success == true, f.setup.errorMessage ?? f.setup.configResult?.error ?? "保存未返回")
        let saved = await f.service.readConfiguration(agent: .claudeCode)
        let loaded = try XCTUnwrap(saved)
        XCTAssertEqual(loaded.modelSlots[.sonnet], "live-one")
        XCTAssertEqual(loaded.modelSlots[.haiku], "live-one")
        XCTAssertNotEqual(loaded.claudeModel1M[.sonnet], true)
        XCTAssertEqual(loaded.claudeModel1M[.haiku], true)
    }
}
