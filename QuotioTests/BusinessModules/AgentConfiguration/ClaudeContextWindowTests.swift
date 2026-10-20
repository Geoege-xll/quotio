import AppKit
import SwiftUI
import Vision
import XCTest
@testable import QuotioPlus

/// 上下文仅验证声明与保存事务，不以模型名推断容量、不调用真实服务。
/// JSON、Shell 和偏好均使用临时夹具；Shell 执行使用 -f，不读取用户启动脚本。
@MainActor
final class ClaudeContextWindowTests: XCTestCase {
    private var home: URL!
    private var service: AgentConfigurationService!
    private var file: URL { home.appendingPathComponent(".claude/settings.json") }
    private var models: [AvailableModel] { ["live-one", "live-two"].map {
        AvailableModel(id: $0, name: $0, provider: "fixture", isDefault: false)
    } }
    private func prepare() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeContext-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        service = AgentConfigurationService(homeDirectory: home)
        let directory = try XCTUnwrap(home)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    }

    private func config() -> AgentConfiguration {
        var value = AgentConfiguration(agent: .claudeCode, proxyURL: "http://127.0.0.1:8317/v1", apiKey: "fixture-only-key")
        value.modelSlots = [.opus: "live-one", .sonnet: "live-two", .haiku: "live-one"]
        return value
    }
    private func write(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
    }
    private func env() throws -> [String: Any] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        return try XCTUnwrap(root["env"] as? [String: Any])
    }
    private func generate(_ value: AgentConfiguration, mode: ConfigurationMode = .automatic,
                          storage: ConfigStorageOption = .jsonOnly) async throws -> AgentConfigResult {
        try await service.generateConfiguration(agent: .claudeCode, config: value, mode: mode,
            storageOption: storage, detectionService: AgentDetectionService(), availableModels: models)
    }

    func testNewAndMissingLegacyFieldsFollowCLIWithoutInjectingCapacity() async throws {
        try prepare()
        let value = config()
        XCTAssertNil(value.claudeMaxContextTokens)
        let encoded = try JSONEncoder().encode(value)
        XCTAssertNil(try JSONDecoder().decode(AgentConfiguration.self, from: encoded).claudeMaxContextTokens)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "claudeMaxContextTokens")
        XCTAssertNil(try JSONDecoder().decode(AgentConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy)).claudeMaxContextTokens)
        let result = try await generate(value)
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertNil(try env()["CLAUDE_CODE_MAX_CONTEXT_TOKENS"])
        let preview = try await generate(value, mode: .manual)
        let shell = try XCTUnwrap(preview.shellConfig)
        XCTAssertTrue(shell.contains("unset CLAUDE_CODE_MAX_CONTEXT_TOKENS"))
        XCTAssertFalse(shell.contains("export CLAUDE_CODE_MAX_CONTEXT_TOKENS="))
        XCTAssertFalse(shell.contains("200000"))
    }

    func testExplicitOldValuesIncluding200KRoundTripAndRemainIndependentOfOneM() async throws {
        try prepare()
        for raw in ["200000", "262144", 500_000] as [Any] {
            try write(["env": ["CLAUDE_CODE_MAX_CONTEXT_TOKENS": raw]])
            let loaded = await service.readConfiguration(agent: .claudeCode)
            let saved = try XCTUnwrap(loaded)
            let expected = Int(String(describing: raw))
            XCTAssertEqual(saved.claudeMaxContextTokens, expected)
            var value = config()
            value.claudeMaxContextTokens = saved.claudeMaxContextTokens
            value.claudeModel1M = [.opus: true]
            let decoded = try JSONDecoder().decode(AgentConfiguration.self, from: JSONEncoder().encode(value))
            XCTAssertEqual(decoded.claudeMaxContextTokens, expected)
            let result = try await generate(decoded, storage: .both)
            XCTAssertTrue(result.success, result.error ?? "")
            XCTAssertEqual(try env()["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] as? String, String(describing: raw))
            XCTAssertEqual(try env()["ANTHROPIC_DEFAULT_OPUS_MODEL"] as? String, "live-one[1m]")
            XCTAssertEqual(try env()["ANTHROPIC_DEFAULT_SONNET_MODEL"] as? String, "live-two")
        }
    }

    func testFollowRemovesOldJSONOverrideAndPreservesUnknownAndIndependentCompaction() async throws {
        try prepare()
        let original: [String: Any] = ["future-root": ["keep": true], "env": [
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "200000", "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "150000",
            "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "8192", "future-env": ["nested": [1, 2, 3]]]]
        try write(original)
        let before = try Data(contentsOf: file)
        var value = config(); value.claudeModel1M = [.opus: true]
        let preview = try await generate(value, mode: .manual)
        XCTAssertTrue(preview.success)
        XCTAssertEqual(try Data(contentsOf: file), before, "手动预览不能清理磁盘或生成备份")
        let beforeBackups = await service.listBackups(agent: .claudeCode)
        XCTAssertTrue(beforeBackups.isEmpty)
        let result = try await generate(value, storage: .both)
        XCTAssertTrue(result.success, result.error ?? "")
        let written = try env()
        XCTAssertNil(written["CLAUDE_CODE_MAX_CONTEXT_TOKENS"])
        XCTAssertEqual(written["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] as? String, "150000")
        XCTAssertEqual(written["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] as? String, "8192")
        XCTAssertEqual((written["future-env"] as? [String: [Int]])?["nested"], [1, 2, 3])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((root["future-root"] as? [String: Bool])?["keep"], true)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(result.backupPath))), before)
    }

    func testGeneratedShellClearsInheritedWindowAndReplacesOnlyManagedBlocks() async throws {
        try prepare()
        let profile = home.appendingPathComponent("profile")
        let outside = "export USER_SETTING=keep\n# 用户保留的独立配置\n"
        let block = "# CLIProxyAPI Configuration for Claude Code\nexport CLAUDE_CODE_MAX_CONTEXT_TOKENS=200000\n# End CLIProxyAPI Configuration for Claude Code\n"
        try (outside + block + block).write(to: profile, atomically: true, encoding: .utf8)
        let manager = ShellProfileManager(profilePath: { _ in profile.path })
        let result = try await generate(config(), storage: .both)
        try await manager.addToProfile(shell: .zsh, configuration: XCTUnwrap(result.shellConfig), agent: .claudeCode)
        let text = try String(contentsOf: profile, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(outside))
        XCTAssertFalse(text.contains("=200000"))
        XCTAssertEqual(text.components(separatedBy: "# End CLIProxyAPI Configuration for Claude Code").count - 1, 1)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", "source \"$1\"; print -r -- \"${CLAUDE_CODE_MAX_CONTEXT_TOKENS-unset}\"", "fixture", profile.path]
        process.environment = ["PATH": "/usr/bin:/bin", "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "200000"]
        process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), "unset")
        let backups = try FileManager.default.contentsOfDirectory(atPath: home.path).filter { $0.hasPrefix("profile.backup.") }
        XCTAssertEqual(backups.count, 1)
    }

    func testShellOnlyCannotClaimToRemoveOrReplaceExistingJSONWindow() async throws {
        try prepare()
        for tokens in [nil, 262_144] as [Int?] {
            for mode in [ConfigurationMode.automatic, .manual] {
                try write(["env": ["CLAUDE_CODE_MAX_CONTEXT_TOKENS": "200000"]])
                let before = try Data(contentsOf: file)
                var value = config(); value.claudeMaxContextTokens = tokens
                let result = try await generate(value, mode: mode, storage: .shellOnly)
                if mode == .automatic {
                    XCTAssertFalse(result.success)
                    XCTAssertEqual(result.error, "agents.claude.advanced.context.requiresJSON".localized())
                } else {
                    // 手动配置隐藏 Shell 存储选项，始终提供可生效的 JSON；不能延用自动模式的拒绝规则。
                    XCTAssertTrue(result.success, result.error ?? "")
                    let json = try XCTUnwrap(result.rawConfigs.first { $0.format == .json })
                    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.content.utf8)) as? [String: Any])
                    XCTAssertEqual((object["env"] as? [String: Any])?["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] as? String, tokens.map(String.init))
                    let shell = try XCTUnwrap(result.rawConfigs.first { $0.format == .shellExport })
                    XCTAssertEqual(shell.instructions, "agents.claude.advanced.context.requiresJSON".localized())
                }
                XCTAssertEqual(try Data(contentsOf: file), before)
                let backups = await service.listBackups(agent: .claudeCode)
                XCTAssertTrue(backups.isEmpty)
            }
        }
        var same = config(); same.claudeMaxContextTokens = 200_000
        let result = try await generate(same, storage: .shellOnly)
        XCTAssertTrue(result.success, result.error ?? "")
    }

    func testEmptyAndInvalidCustomValuesAreRejectedBeforeIO() async throws {
        try prepare()
        let vm = AgentSetupViewModel(configurationService: service)
        vm.selectedAgent = .claudeCode; vm.currentConfiguration = config()
        XCTAssertNil(vm.configurationValidationMessage)
        for tokens in [0, -1] {
            vm.updateClaudeMaxContextTokens(tokens)
            XCTAssertEqual(vm.configurationValidationMessage, "agents.claude.advanced.context.validation".localized())
            let result = try await generate(XCTUnwrap(vm.currentConfiguration))
            XCTAssertFalse(result.success)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
        vm.updateClaudeMaxContextTokens(nil)
        XCTAssertNil(vm.configurationValidationMessage)
    }

    func testShellConflictAndReadUseIdenticalStrictIntegerSemantics() async throws {
        try prepare()
        var value = config(); value.claudeMaxContextTokens = 200_000
        for raw in ["0200000", "+200000", " 200000 ", 200_000] as [Any] {
            try write(["env": ["CLAUDE_CODE_MAX_CONTEXT_TOKENS": raw]])
            let loaded = await service.readConfiguration(agent: .claudeCode)
            XCTAssertEqual(loaded?.claudeMaxContextTokens, 200_000)
            let result = try await generate(value, storage: .shellOnly)
            XCTAssertTrue(result.success, result.error ?? "")
        }
        value.claudeMaxContextTokens = 1
        for raw in [true, 1.5, "invalid"] as [Any] {
            try write(["env": ["CLAUDE_CODE_MAX_CONTEXT_TOKENS": raw]])
            let loaded = await service.readConfiguration(agent: .claudeCode)
            XCTAssertNil(loaded?.claudeMaxContextTokens)
            let result = try await generate(value, storage: .shellOnly)
            XCTAssertFalse(result.success, "非法 JSON 窗口必须先通过 JSON 保存修正")
        }
    }

    func testManagedCatalogSynchronizationPreservesFollowAndExplicitLegacyValues() async throws {
        try prepare()
        for tokens in [nil, 200_000, 262_144] as [Int?] {
            var value = config(); value.claudeCatalogManaged = true; value.claudeMaxContextTokens = tokens
            let initial = try await generate(value)
            XCTAssertTrue(initial.success, initial.error ?? "")
            let loaded = await service.managedClaudeConfiguration(serviceBaseURLs: ["http://127.0.0.1:8317"])
            XCTAssertEqual(loaded?.claudeMaxContextTokens, tokens)
            let result = await service.synchronizeManagedClaudeCatalog(
                sourceID: ClaudeConfigurationPlan.sourceID(url: value.proxyURL, key: value.apiKey),
                serviceBaseURLs: ["http://127.0.0.1:8317"], models: models + [
                    AvailableModel(id: "new-directory-model", name: "new-directory-model", provider: "fixture", isDefault: false)])
            XCTAssertEqual(result?.success, true)
            XCTAssertEqual(try env()["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] as? String, tokens.map(String.init))
            // 先前读取的草稿不能成为后台提交基线：模拟其他编辑器在两次同步间切换窗口声明。
            let externallyChosen: Int? = tokens == nil ? 200_000 : nil
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var externalEnv = try XCTUnwrap(root["env"] as? [String: Any])
            externalEnv["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = externallyChosen.map(String.init)
            root["env"] = externalEnv
            try write(root)
            let refreshed = await service.synchronizeManagedClaudeCatalog(
                sourceID: ClaudeConfigurationPlan.sourceID(url: value.proxyURL, key: value.apiKey),
                serviceBaseURLs: ["http://127.0.0.1:8317"], models: models)
            XCTAssertEqual(refreshed?.success, true)
            XCTAssertEqual(try env()["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] as? String, externallyChosen.map(String.init))
        }
    }

    func testAllContextModeResourcesAreBundled() throws {
        try prepare()
        for language in AppLanguage.allCases {
            for suffix in ["automatic", "custom", "placeholder", "requiresJSON", "info"] {
                let key = "agents.claude.advanced.context." + suffix
                XCTAssertNotEqual(language.bundle.localizedString(forKey: key, value: nil, table: nil), key)
            }
        }
    }

    func testUnfinishedProxyWindowDoesNotBlockRestoringOfficialConfiguration() async throws {
        try prepare()
        let vm = AgentSetupViewModel(configurationService: service, generateConfiguration: { _, configuration, mode, _, _ in
            XCTAssertEqual(configuration.setupMode, .defaultSetup)
            return .success(type: .file, mode: mode, instructions: "fixture")
        })
        vm.selectedAgent = .claudeCode
        var value = config(); value.claudeMaxContextTokens = 0; value.setupMode = .defaultSetup
        vm.currentConfiguration = value; vm.selectedSetupMode = .defaultSetup; vm.configurationMode = .manual
        await vm.applyConfiguration()
        XCTAssertEqual(vm.configResult?.success, true)
        XCTAssertNil(vm.errorMessage)
    }

    func testJSONOnlyApplyRemovesManagedShellAndFailureRestoresOldJSON() async throws {
        try prepare()
        let keys = ["configured", "lastConfigured"].map { "agent.\(CLIAgent.claudeCode.rawValue)." + $0 }
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        for fails in [false, true] {
            var old = config(); old.claudeMaxContextTokens = 200_000
            let seeded = try await generate(old)
            XCTAssertTrue(seeded.success)
            let before = try Data(contentsOf: file)
            let profile = home.appendingPathComponent("profile")
            let outside = "export USER_SETTING=keep\n"
            let original = outside + "# CLIProxyAPI Configuration for Claude Code\nexport CLAUDE_CODE_MAX_CONTEXT_TOKENS=200000\n# End CLIProxyAPI Configuration for Claude Code\n"
            try original.write(to: profile, atomically: true, encoding: .utf8)
            let shell = ShellProfileManager(profilePath: { _ in profile.path }, writeProfile: { text, path in
                if fails { throw CocoaError(.fileWriteUnknown) }
                try text.write(toFile: path, atomically: true, encoding: .utf8)
            })
            let directory = models
            let vm = AgentSetupViewModel(configurationService: service, shellManager: shell, fetchModels: { _, _ in directory },
                configurationEndpoint: { "http://127.0.0.1:8317" }, detectAgentStatuses: { _ in [] })
            let session = vm.startConfiguration(for: .claudeCode, apiKey: "fixture-only-key")
            for _ in 0..<100 {
                if !vm.isLoadingConfiguration && !vm.isFetchingModels { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(vm.currentConfiguration?.claudeMaxContextTokens, 200_000)
            vm.updateClaudeMaxContextTokens(nil)
            await vm.applyConfiguration(sessionID: session)
            XCTAssertEqual(vm.configResult?.success, !fails, vm.errorMessage ?? "")
            if fails {
                XCTAssertEqual(try Data(contentsOf: file), before, "Shell 清理失败必须撤销本次 JSON 窗口移除")
                XCTAssertEqual(try String(contentsOf: profile, encoding: .utf8), original)
            } else {
                XCTAssertNil(try env()["CLAUDE_CODE_MAX_CONTEXT_TOKENS"])
                XCTAssertEqual(try String(contentsOf: profile, encoding: .utf8), outside)
            }
            vm.dismissConfiguration(sessionID: session)
        }
    }

    /// 生产高级区真实展开与分段切换：不通过 VM 调用替代点击，输入发送到本窗口的原生 field editor。
    /// 业务草稿仍只在原 VM，折叠不保存／重置；不把 OCR 截图大小当成功条件。
    func testAdvancedDefaultsCollapsedAndRealSegmentsPreserveOneMAndEditWindow() async throws {
        try prepare()
        let vm = AgentSetupViewModel(configurationService: service)
        vm.selectedAgent = .claudeCode
        var value = config(); value.claudeModel1M = [.opus: true]
        vm.currentConfiguration = value
        var edits = 0
        let host = NSHostingView(rootView: ClaudeAdvancedSettingsSection(viewModel: vm, onSettingsChange: { edits += 1 })
            .padding(16).frame(width: 720).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 180, y: 160, width: 720, height: 640),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let collapsed = try texts(host).map(\.0).joined(separator: " ")
        XCTAssertTrue(collapsed.localizedCaseInsensitiveContains("agents.claude.advanced.context.automatic".localized()), collapsed)
        XCTAssertFalse(collapsed.contains("agents.claude.advanced.context.placeholder".localized()))
        XCTAssertFalse(collapsed.contains("200,000"))
        XCTAssertNil(vm.currentConfiguration?.claudeMaxContextTokens)
        XCTAssertEqual(edits, 0)
        try click("agents.claude.advanced".localized(), in: host)
        try await Task.sleep(for: .milliseconds(100))
        try click("agents.claude.advanced.context.custom".localized(), in: host)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(vm.currentConfiguration?.claudeMaxContextTokens, 0, "选择自定义不自动猜一个容量")
        XCTAssertNotNil(vm.configurationValidationMessage)
        try click("agents.claude.advanced.context.placeholder".localized(), in: host)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "必须进入真实输入框")
        editor.insertText("262144", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(vm.currentConfiguration?.claudeMaxContextTokens, 262_144)
        try click("agents.claude.advanced.context.automatic".localized(), in: host)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(vm.currentConfiguration?.claudeMaxContextTokens)
        XCTAssertEqual(vm.currentConfiguration?.claudeModel1M, [.opus: true])
        XCTAssertNil(vm.configurationValidationMessage)
        XCTAssertGreaterThanOrEqual(edits, 3)
    }

    private func texts(_ view: NSView) throws -> [(String, CGRect, VNRecognizedText)] {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size; view.cacheDisplay(in: view.bounds, to: bitmap)
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.customWords = ["agents.claude.advanced".localized(), "agents.claude.advanced.context.custom".localized(),
            "agents.claude.advanced.context.placeholder".localized()]
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        return (request.results ?? []).compactMap { item in item.topCandidates(1).first.map { ($0.string, item.boundingBox, $0) } }
    }

    private func click(_ title: String, in view: NSView) throws {
        let found = try texts(view)
        let target = try XCTUnwrap(found.first { $0.0.localizedCaseInsensitiveContains(title) },
            "未找到 \(title)，实际：\(found.map(\.0))")
        let range = try XCTUnwrap(target.0.range(of: title, options: .caseInsensitive))
        let rect = try target.2.boundingBox(for: range)?.boundingBox ?? target.1
        let point = view.convert(NSPoint(x: rect.midX * view.bounds.width,
            y: view.isFlipped ? view.bounds.maxY - rect.midY * view.bounds.height : rect.midY * view.bounds.height), to: nil)
        let window = try XCTUnwrap(view.window)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        }
    }
}
