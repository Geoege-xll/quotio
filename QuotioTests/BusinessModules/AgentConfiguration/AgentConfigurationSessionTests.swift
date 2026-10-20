import XCTest
@testable import QuotioPlus

/// 通过原 start/dismiss 入口与不响应取消的显式屏障验证会话边界，避免依赖 Task.yield 的偶然次序。
/// 全部 IO 默认注入临时配置、离线目录和内存结果；不创建真实 CPA manager、不访问钥匙串或启动 CLI。
@MainActor
final class AgentConfigurationSessionTests: XCTestCase {
    private typealias Generator = @Sendable (CLIAgent, AgentConfiguration, ConfigurationMode, ConfigStorageOption, [AvailableModel]) async throws -> AgentConfigResult
    private actor Gate<Value: Sendable> {
        let started: XCTestExpectation
        private var continuation: CheckedContinuation<Value, Never>?
        init(_ started: XCTestExpectation) { self.started = started }
        func wait() async -> Value {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }
        func release(_ value: Value) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
    private actor Sequence<Value: Sendable> {
        private var index = 0
        let gates: [Gate<Value>]
        init(_ gates: [Gate<Value>]) { self.gates = gates }
        var count: Int { index }
        func next() async -> Value {
            let current = index
            index += 1
            return await gates[current].wait()
        }
    }
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func model(_ id: String) -> AvailableModel {
        .init(id: id, name: id, provider: "fixture", isDefault: false)
    }
    private func vm(
        home: URL,
        fetch: @escaping @Sendable (String, String) async throws -> [AvailableModel] = { _, _ in [] },
        read: @escaping @Sendable (CLIAgent) async -> AgentConfigurationService.SavedAgentConfig? = { _ in nil },
        probe: @escaping @Sendable (String, String) async -> ConnectionTestResult = { _, _ in
            .init(success: true, message: "fixture", latencyMs: 1, modelResponded: nil)
        },
        generate: @escaping Generator = { _, _, _, _, _ in
            .success(type: .file, mode: .manual, instructions: "fixture")
        }
    ) -> AgentSetupViewModel {
        .init(configurationService: AgentConfigurationService(homeDirectory: home), fetchModels: fetch,
            configurationEndpoint: { "https://fixture.invalid" }, readConfiguration: read,
            probeConnection: probe, generateConfiguration: generate)
    }
    private func ready(_ vm: AgentSetupViewModel) async throws {
        for _ in 0..<100 {
            if !vm.isLoadingConfiguration && !vm.isFetchingModels { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("本轮初次回填和离线模型读取应已完成")
    }
    private func draft(_ vm: AgentSetupViewModel, agent: CLIAgent = .claudeCode) {
        vm.selectedAgent = agent
        vm.currentConfiguration = AgentConfiguration(agent: agent, proxyURL: "https://fixture.invalid/v1", apiKey: "same-key")
    }

    func testReopenSameClientAndSwitchClientRejectOldDirectoryAndUncancelledLateCallbacks() async throws {
        for nextAgent in [CLIAgent.claudeCode, .codexCLI] {
            let oldStarted = expectation(description: "旧页面目录挂起")
            let newStarted = expectation(description: "新页面目录挂起")
            let old = Gate<Result<[AvailableModel], URLError>>(oldStarted)
            let new = Gate<Result<[AvailableModel], URLError>>(newStarted)
            let requests = Sequence([old, new])
            let vm = vm(home: try home(), fetch: { _, _ in try await requests.next().get() })
            let oldID = vm.startConfiguration(for: .claudeCode, apiKey: "same-key")
            await fulfillment(of: [oldStarted], timeout: 2)
            vm.dismissConfiguration(sessionID: oldID)
            let newID = vm.startConfiguration(for: nextAgent, apiKey: "same-key")
            await fulfillment(of: [newStarted], timeout: 2)
            XCTAssertNotEqual(oldID, newID)
            // 模拟旧别名 onDismiss／按钮闭包此时才启动：这个调用从未被取消，必须在入口拒绝。
            let late = await vm.loadModels(forceRefresh: true, sessionID: oldID)
            XCTAssertFalse(late)
            let requestCount = await requests.count
            XCTAssertEqual(requestCount, 2)
            XCTAssertTrue(vm.isFetchingModels)
            await old.release(.failure(URLError(.badServerResponse)))
            await new.release(.success([model("new-directory")]))
            try await ready(vm)
            XCTAssertEqual(vm.availableModels.map(\.id), ["new-directory"])
            XCTAssertNil(vm.modelLoadMessage)
            vm.currentConfiguration?.modelSlots[.sonnet] = "new-unsaved-model"
            vm.dismissConfiguration(sessionID: oldID) // 迟到的旧 onDisappear 不能关闭新页面。
            vm.resetSheetState(sessionID: oldID)
            XCTAssertEqual(vm.selectedAgent, nextAgent)
            XCTAssertEqual(vm.currentConfiguration?.modelSlots[.sonnet], "new-unsaved-model")
            XCTAssertEqual(vm.configurationSessionID, newID)
            vm.dismissConfiguration(sessionID: newID)
        }
    }

    func testThreeRefreshesWithIdenticalCredentialsKeepLatestAndItsLoadingState() async throws {
        let starts = (0..<3).map { expectation(description: "刷新 \($0)") }
        let gates = starts.map { Gate<Result<[AvailableModel], URLError>>($0) }
        let requests = Sequence(gates)
        let vm = vm(home: try home(), fetch: { _, _ in try await requests.next().get() })
        draft(vm)
        let id = vm.configurationSessionID
        let first = Task { await vm.loadModels(sessionID: id) }
        await fulfillment(of: [starts[0]], timeout: 2)
        let second = Task { await vm.loadModels(sessionID: id) }
        await fulfillment(of: [starts[1]], timeout: 2)
        let third = Task { await vm.loadModels(sessionID: id) }
        await fulfillment(of: [starts[2]], timeout: 2)
        await gates[1].release(.success([model("second")]))
        let secondResult = await second.value
        XCTAssertFalse(secondResult)
        await gates[0].release(.failure(URLError(.notConnectedToInternet)))
        let firstResult = await first.value
        XCTAssertFalse(firstResult)
        XCTAssertTrue(vm.isFetchingModels)
        XCTAssertNil(vm.modelLoadMessage)
        await gates[2].release(.success([model("latest")]))
        let thirdResult = await third.value
        XCTAssertTrue(thirdResult)
        XCTAssertEqual(vm.availableModels.map(\.id), ["latest"])
        XCTAssertFalse(vm.isFetchingModels)
    }

    func testCancellingCurrentRefreshStillReleasesItsOwnLoadingState() async throws {
        let started = expectation(description: "当前读取挂起")
        let gate = Gate<[AvailableModel]>(started)
        let vm = vm(home: try home(), fetch: { _, _ in await gate.wait() })
        draft(vm)
        let task = Task { await vm.loadModels(sessionID: vm.configurationSessionID) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await gate.release([model("cancelled")])
        let cancelledResult = await task.value
        XCTAssertFalse(cancelledResult)
        XCTAssertTrue(vm.availableModels.isEmpty)
        XCTAssertFalse(vm.isFetchingModels, "取消检查不能让本轮 defer 失去收尾权限")
    }

    func testOldConnectionResultCannotOverwriteNewSessionOrReleaseItsRequest() async throws {
        let starts = (0..<2).map { expectation(description: "连接测试 \($0)") }
        let gates = starts.map { Gate<ConnectionTestResult>($0) }
        let requests = Sequence(gates)
        let vm = vm(home: try home(), probe: { _, _ in await requests.next() })
        let oldID = vm.startConfiguration(for: .claudeCode, apiKey: "same-key")
        try await ready(vm)
        let old = Task { await vm.testConnection(sessionID: oldID) }
        await fulfillment(of: [starts[0]], timeout: 2)
        vm.dismissConfiguration(sessionID: oldID)
        let newID = vm.startConfiguration(for: .claudeCode, apiKey: "same-key")
        try await ready(vm)
        let new = Task { await vm.testConnection(sessionID: newID) }
        await fulfillment(of: [starts[1]], timeout: 2)
        await gates[0].release(.init(success: false, message: "old-error", latencyMs: 1, modelResponded: nil))
        await old.value
        XCTAssertNil(vm.testResult)
        XCTAssertTrue(vm.isTesting)
        await gates[1].release(.init(success: true, message: "new-result", latencyMs: 1, modelResponded: nil))
        await new.value
        XCTAssertEqual(vm.testResult?.message, "new-result")
        XCTAssertFalse(vm.isTesting)
    }

    func testConsecutiveConnectionTestsInSameSessionKeepLastResponse() async throws {
        let starts = (0..<2).map { expectation(description: "连续测试 \($0)") }
        let gates = starts.map { Gate<ConnectionTestResult>($0) }
        let requests = Sequence(gates)
        let vm = vm(home: try home(), probe: { _, _ in await requests.next() })
        draft(vm)
        let id = vm.configurationSessionID
        let first = Task { await vm.testConnection(sessionID: id) }
        await fulfillment(of: [starts[0]], timeout: 2)
        let second = Task { await vm.testConnection(sessionID: id) }
        await fulfillment(of: [starts[1]], timeout: 2)
        await gates[1].release(.init(success: true, message: "latest", latencyMs: 1, modelResponded: nil))
        await second.value
        await gates[0].release(.init(success: false, message: "old", latencyMs: nil, modelResponded: nil))
        await first.value
        XCTAssertEqual(vm.testResult?.message, "latest")
        XCTAssertFalse(vm.isTesting)
    }

    func testOldSaveSuccessOrFailureCannotPublishIntoNewSessionOrReleaseNewSave() async throws {
        for nextAgent in [CLIAgent.claudeCode, .codexCLI] {
            for oldFails in [false, true] {
                let starts = (0..<2).map { expectation(description: "保存 \($0)") }
                let gates = starts.map { Gate<Result<AgentConfigResult, URLError>>($0) }
                let requests = Sequence(gates)
                // 新生产入口接管目录菜单；会话回归提供真实有效的离线角色映射，
                // 让保存进入原生成屏障，而不是被“目录为空／原生槽未映射”的校验提前结束。
                let vm = vm(home: try home(), fetch: { _, _ in
                    [.init(id: "new-model", name: "new-model", provider: "fixture", isDefault: false)]
                }, generate: { _, _, mode, _, _ in
                    XCTAssertEqual(mode, .manual)
                    return try await requests.next().get()
                })
                let oldID = vm.startConfiguration(for: .claudeCode, apiKey: "same-key")
                try await ready(vm)
                vm.currentConfiguration?.modelSlots = Dictionary(uniqueKeysWithValues: ModelSlot.legacyCases.map { ($0, "new-model") })
                vm.configurationMode = .manual
                let old = Task { await vm.applyConfiguration(sessionID: oldID) }
                await fulfillment(of: [starts[0]], timeout: 2)
                vm.dismissConfiguration(sessionID: oldID)
                let newID = vm.startConfiguration(for: nextAgent, apiKey: "same-key")
                try await ready(vm)
                vm.currentConfiguration?.modelSlots = Dictionary(uniqueKeysWithValues: ModelSlot.legacyCases.map { ($0, "new-model") })
                vm.currentConfiguration?.codexModel = "new-model"
                vm.configurationMode = .manual
                let new = Task { await vm.applyConfiguration(sessionID: newID) }
                await fulfillment(of: [starts[1]], timeout: 2)
                await gates[0].release(oldFails ? .failure(URLError(.badServerResponse)) : .success(.success(type: .file, mode: .manual, instructions: "old")))
                await old.value
                XCTAssertNil(vm.configResult)
                XCTAssertNil(vm.errorMessage)
                XCTAssertTrue(vm.isConfiguring)
                XCTAssertEqual(vm.currentConfiguration?.codexModel, "new-model")
                await gates[1].release(.success(.success(type: .file, mode: .manual, instructions: "new")))
                await new.value
                XCTAssertEqual(vm.configResult?.instructions, "new")
                XCTAssertFalse(vm.isConfiguring)
            }
        }
    }

    func testSaveSnapshotsModeAndResetDoesNotReleaseInFlightOperation() async throws {
        let started = expectation(description: "手动生成挂起")
        let gate = Gate<AgentConfigResult>(started)
        let vm = vm(home: try home(), generate: { _, _, mode, storage, _ in
            XCTAssertEqual(mode, .manual)
            XCTAssertEqual(storage, .jsonOnly, "手动模式不继承自动模式已隐藏的存储选项")
            return await gate.wait()
        })
        draft(vm)
        let id = vm.configurationSessionID
        vm.configurationMode = .manual
        vm.configStorageOption = .both
        let saving = Task { await vm.applyConfiguration(sessionID: id) }
        await fulfillment(of: [started], timeout: 2)
        vm.resetSheetState(sessionID: id)
        XCTAssertTrue(vm.isConfiguring)
        await gate.release(.success(type: .file, mode: .manual, instructions: "manual-result"))
        await saving.value
        XCTAssertEqual(vm.configResult?.instructions, "manual-result")
        XCTAssertFalse(vm.isConfiguring)
    }

    /// 同一页恢复后的磁盘回填即使挂起，也必须继续持有原操作互斥。
    /// 这里拦在实际恢复之后，证明应用和删除都不会越过屏障修改刚恢复的文件／备份。
    func testRestoreOwnsSameSessionBarrierUntilReadAndCatalogFinish() async throws {
        let directory = try home()
        let backup = directory.appendingPathComponent(".claude/settings.json.backup.100")
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        let restored = Data(#"{"env":{"ANTHROPIC_DEFAULT_SONNET_MODEL":"restored-model"},"keep":true}"#.utf8)
        try restored.write(to: backup)
        let started = expectation(description: "实际恢复后回填挂起")
        let gate = Gate<AgentConfigurationService.SavedAgentConfig?>(started)
        let reads = RestoreRead(gate)
        let vm = vm(home: directory, fetch: { _, _ in
            [.init(id: "restored-model", name: "restored-model", provider: "fixture", isDefault: false)]
        }, read: { _ in await reads.read() }, generate: { _, _, _, _, _ in
            XCTFail("恢复持锁期间不应执行保存")
            return .failure(error: "unexpected")
        })
        let id = vm.startConfiguration(for: .claudeCode, apiKey: "same-key")
        try await ready(vm)
        vm.currentConfiguration?.modelSlots[.opus] = "old-before-restore"
        vm.currentConfiguration?.proxyURL = "https://old-external.invalid/v1"
        vm.currentConfiguration?.apiKey = "external-key-not-for-cpa"
        let descriptor = AgentConfigurationService.BackupFile(path: backup.path,
            timestamp: Date(timeIntervalSince1970: 100), agent: .claudeCode)
        let restoring = Task { await vm.restoreFromBackup(descriptor, sessionID: id) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(vm.isConfiguring)
        XCTAssertTrue(vm.isLoadingConfiguration)
        await vm.applyConfiguration(sessionID: id)
        await vm.deleteBackups([descriptor], sessionID: id)
        await vm.restoreFromBackup(descriptor, sessionID: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try Data(contentsOf: backup.deletingLastPathComponent().appendingPathComponent("settings.json")), restored)
        XCTAssertNil(vm.configResult)
        XCTAssertNil(vm.errorMessage)
        await gate.release(.init(baseURL: "https://fixture.invalid", apiKey: "restored-cpa-key", modelSlots: [.sonnet: "restored-model"],
            isProxyConfigured: true, backupFiles: []))
        await restoring.value
        XCTAssertFalse(vm.isConfiguring)
        XCTAssertFalse(vm.isLoadingConfiguration)
        XCTAssertEqual(vm.currentConfiguration?.modelSlots[.sonnet], "restored-model")
        XCTAssertNil(vm.currentConfiguration?.modelSlots[.opus], "备份中缺失的角色不能从恢复前草稿复活")
        XCTAssertEqual(vm.currentConfiguration?.apiKey, "restored-cpa-key", "外部草稿的 key 不能随恢复地址带入 CPA")
        XCTAssertEqual(vm.currentModelCandidates.map(\.id), ["restored-model"])
    }

    /// 页面回读必须保留原服务和它自己的认证；只有同一当前 CPA 才沿用入口提供的新 key。
    func testSavedSourceKeepsExternalCredentialsAndSameCPAKeepsCurrentKey() async throws {
        for (baseURL, expectedURL, expectedKey) in [
            ("https://external.invalid/proxy", "https://external.invalid/proxy/v1", "saved-key"),
            ("https://fixture.invalid", "https://fixture.invalid/v1", "new-cpa-key")
        ] {
            let vm = vm(home: try home(), fetch: { url, key in
                XCTAssertEqual(url, expectedURL)
                XCTAssertEqual(key, expectedKey)
                return []
            }, read: { _ in .init(baseURL: baseURL, apiKey: "saved-key", modelSlots: [:],
                                 isProxyConfigured: true, backupFiles: []) })
            let id = vm.startConfiguration(for: .claudeCode, apiKey: "new-cpa-key")
            try await ready(vm)
            XCTAssertEqual(vm.selectedSetupMode, .proxy)
            XCTAssertEqual(vm.currentConfiguration?.proxyURL, expectedURL)
            XCTAssertEqual(vm.currentConfiguration?.apiKey, expectedKey)
            XCTAssertEqual(vm.usesCPAModelService, baseURL == "https://fixture.invalid")
            vm.dismissConfiguration(sessionID: id)
        }
    }

    /// 保存入口和纯预览必须采取同一份有效手动操作，旧的仅 Shell 选择不应阻断 JSON 方案。
    func testAutomaticShellOnlyThenManualUsesJSONForValidationPreviewAndSave() async throws {
        let vm = vm(home: try home(), generate: { _, _, mode, storage, _ in
            XCTAssertEqual(mode, .manual)
            XCTAssertEqual(storage, .jsonOnly)
            return .success(type: .both, mode: .manual, instructions: "json-plan")
        })
        draft(vm)
        vm.currentConfiguration?.claudeModelPicker = .roleDefaults(mode: .append)
        vm.configStorageOption = .shellOnly
        XCTAssertNotNil(vm.claudeConfigurationValidationMessage)
        vm.configurationMode = .manual
        XCTAssertNil(vm.claudeConfigurationValidationMessage)
        let preview = await vm.generatePreviewConfig(sessionID: vm.configurationSessionID)
        XCTAssertEqual(preview?.instructions, "json-plan")
        await vm.applyConfiguration(sessionID: vm.configurationSessionID)
        XCTAssertEqual(vm.configResult?.instructions, "json-plan")
        XCTAssertEqual(vm.configStorageOption, .shellOnly, "有效操作不应偷偷重写用户的自动模式选择")
    }

    private actor RestoreRead {
        let gate: Gate<AgentConfigurationService.SavedAgentConfig?>
        private var count = 0
        init(_ gate: Gate<AgentConfigurationService.SavedAgentConfig?>) { self.gate = gate }
        func read() async -> AgentConfigurationService.SavedAgentConfig? {
            count += 1
            if count == 2 { return await gate.wait() } // 初次读取立即完成，只有恢复后的回填挂起。
            return nil
        }
    }
    func testRestoreLateReadCannotOverwriteReopenedSameClientOrDifferentClient() async throws {
        for nextAgent in [CLIAgent.claudeCode, .codexCLI] {
            let home = try home()
            let backup = home.appendingPathComponent(".claude/settings.json.backup.100")
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try #"{"env":{}}"#.write(to: backup, atomically: true, encoding: .utf8)
            let started = expectation(description: "恢复后的旧回填挂起")
            let gate = Gate<AgentConfigurationService.SavedAgentConfig?>(started)
            let reads = RestoreRead(gate)
            let vm = vm(home: home, read: { _ in await reads.read() })
            let oldID = vm.startConfiguration(for: .claudeCode, apiKey: "same-key")
            try await ready(vm)
            let restore = Task { await vm.restoreFromBackup(.init(path: backup.path, timestamp: Date(timeIntervalSince1970: 100), agent: .claudeCode), sessionID: oldID) }
            await fulfillment(of: [started], timeout: 2)
            vm.dismissConfiguration(sessionID: oldID)
            let newID = vm.startConfiguration(for: nextAgent, apiKey: "same-key")
            try await ready(vm)
            vm.currentConfiguration?.modelSlots[.sonnet] = "new-unsaved-model"
            vm.currentConfiguration?.claudeAutoCompactPercentage = 71
            await gate.release(.init(baseURL: nil, apiKey: nil, modelSlots: [.sonnet: "old-restored-model"], isProxyConfigured: true, backupFiles: []))
            await restore.value
            XCTAssertEqual(vm.currentConfiguration?.modelSlots[.sonnet], "new-unsaved-model")
            XCTAssertEqual(vm.currentConfiguration?.claudeAutoCompactPercentage, 71)
            XCTAssertNil(vm.errorMessage)
            XCTAssertNil(vm.savedConfig)
            vm.dismissConfiguration(sessionID: newID)
        }
    }

    func testOldPreviewReturnsNoConfigurationAfterReopen() async throws {
        let started = expectation(description: "旧预览挂起")
        let gate = Gate<AgentConfigResult>(started)
        let vm = vm(home: try home(), generate: { _, _, _, _, _ in await gate.wait() })
        let oldID = vm.startConfiguration(for: .claudeCode, apiKey: "same-key")
        try await ready(vm)
        let preview = Task { await vm.generatePreviewConfig(sessionID: oldID) }
        await fulfillment(of: [started], timeout: 2)
        vm.dismissConfiguration(sessionID: oldID)
        let newID = vm.startConfiguration(for: .claudeCode, apiKey: "same-key")
        try await ready(vm)
        await gate.release(.success(type: .file, mode: .manual, instructions: "old-preview"))
        let previewResult = await preview.value
        XCTAssertNil(previewResult)
        XCTAssertEqual(vm.configurationSessionID, newID)
    }

    func testLateActionsAreRejectedBeforeAnyIOOrDraftMutation() async throws {
        let vm = vm(home: try home(), probe: { _, _ in XCTFail("旧连接不得进入 IO"); return .init(success: false, message: "", latencyMs: nil, modelResponded: nil) },
            generate: { _, _, _, _, _ in XCTFail("旧保存／预览不得进入 IO"); return .failure(error: "unexpected") })
        let oldID = vm.startConfiguration(for: .claudeCode, apiKey: "same-key")
        try await ready(vm)
        vm.dismissConfiguration(sessionID: oldID)
        let newID = vm.startConfiguration(for: .claudeCode, apiKey: "same-key")
        try await ready(vm)
        vm.currentConfiguration?.modelSlots[.sonnet] = "new-draft"
        vm.errorMessage = "new-error"
        await vm.applyConfiguration(sessionID: oldID)
        await vm.testConnection(sessionID: oldID)
        let latePreview = await vm.generatePreviewConfig(sessionID: oldID)
        XCTAssertNil(latePreview)
        vm.retryConfiguration(sessionID: oldID)
        vm.dismissConfiguration(sessionID: oldID)
        XCTAssertEqual(vm.errorMessage, "new-error")
        XCTAssertEqual(vm.currentConfiguration?.modelSlots[.sonnet], "new-draft")
        XCTAssertEqual(vm.configurationSessionID, newID)
    }
    private actor PiLookup {
        let first: Gate<[AvailableModel]>
        let later: [AvailableModel]
        private var count = 0
        init(first: Gate<[AvailableModel]>, later: [AvailableModel]) { self.first = first; self.later = later }
        func fetch() async -> [AvailableModel] {
            count += 1
            if count == 1 { return await first.wait() }
            return later
        }
    }

    func testPiAutomaticSavesAndRestoreCannotInterleaveAndRetryKeepsLatestFiles() async throws {
        let home = try home()
        let urls = PiAgentSupport.configURLs(homeDirectory: home)
        guard urls.allSatisfy({ $0.path.hasPrefix(home.path + "/") }) else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: urls[0].deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"baseUrl":"https://fixture.invalid","apiKey":"original"}"#.write(to: urls[0], atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["packages": [PiAgentSupport.package], "defaultProvider": PiAgentSupport.provider,
            "defaultModel": "original-model", "preserve": true]).write(to: urls[1])
        let before = try urls.map { try Data(contentsOf: $0) }
        let backupURL = urls[1].appendingPathExtension("backup.100")
        try before[1].write(to: backupURL)
        let started = expectation(description: "首轮 Pi 保存前查证挂起")
        let gate = Gate<[AvailableModel]>(started)
        let lookup = PiLookup(first: gate, later: [model("new-model")])
        let service = AgentConfigurationService(homeDirectory: home, fetchPiModels: { _, _ in await lookup.fetch() })
        var oldConfig = AgentConfiguration(agent: .pi, proxyURL: "https://fixture.invalid/v1", apiKey: "old-key")
        oldConfig.modelSlots[.sonnet] = "old-model"
        let oldSnapshot = oldConfig
        let old = Task { try await service.generateConfiguration(agent: .pi, config: oldSnapshot, mode: .automatic, detectionService: AgentDetectionService()) }
        await fulfillment(of: [started], timeout: 2)
        var newConfig = oldConfig
        newConfig.modelSlots[.sonnet] = "new-model"
        newConfig.apiKey = "new-key"
        let blocked = try await service.generateConfiguration(agent: .pi, config: newConfig, mode: .automatic, detectionService: AgentDetectionService())
        XCTAssertFalse(blocked.success, "重开页面不能并行写入同一 Pi 配置")
        do {
            try await service.restoreFromBackup(.init(path: backupURL.path, timestamp: Date(timeIntervalSince1970: 100), agent: .pi))
            XCTFail("文件恢复也必须遵守同一 Pi 写入互斥")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Pi")) }
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before)
        await gate.release([model("old-model")])
        let completed = try await old.value
        XCTAssertTrue(completed.success)
        let latest = try await service.generateConfiguration(agent: .pi, config: newConfig, mode: .automatic, detectionService: AgentDetectionService())
        XCTAssertTrue(latest.success, latest.error ?? "")
        let provider = try PiAgentSupport.object(at: urls[0]), settings = try PiAgentSupport.object(at: urls[1])
        XCTAssertEqual(provider["apiKey"] as? String, "new-key")
        XCTAssertEqual(settings["defaultModel"] as? String, "new-model")
        XCTAssertEqual(settings["preserve"] as? Bool, true)
    }

}
