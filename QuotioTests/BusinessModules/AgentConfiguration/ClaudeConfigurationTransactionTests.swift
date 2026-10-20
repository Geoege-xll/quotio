import XCTest
@testable import QuotioPlus

/// Claude 用户配置的业务事务回归：归属、位置、官方恢复与后台同步必须操作同一份文件。
/// 所有服务均显式使用临时 home／环境，不读取真实用户配置，不启动 CPA，也不发送网络请求。
/// CLI 的实际交互保存由独立假网关用例覆盖；本类精确模拟其菜单结构规范化后的磁盘结果。
final class ClaudeConfigurationTransactionTests: XCTestCase {
    private var home: URL!
    private var defaultFile: URL { home.appendingPathComponent(".claude/settings.json") }
    private var models: [AvailableModel] { ["live-one", "live-two"].map {
        AvailableModel(id: $0, name: $0, provider: "fixture", isDefault: false)
    } }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeTransactions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    private func configuration(managed: Bool = true, setup: ConfigurationSetup = .proxy) -> AgentConfiguration {
        var value = AgentConfiguration(agent: .claudeCode, proxyURL: "https://fixture-tunnel.invalid/deployment/v1",
                                       apiKey: "fixture-only-secret", setupMode: setup)
        value.modelSlots = [.opus: "live-one", .sonnet: "live-two", .haiku: "live-one"]
        value.claudeDefaultModel = "opus"
        value.claudeCatalogManaged = managed
        return value
    }

    private func generate(_ service: AgentConfigurationService, configuration value: AgentConfiguration? = nil,
                          storage: ConfigStorageOption = .jsonOnly) async throws -> AgentConfigResult {
        try await service.generateConfiguration(agent: .claudeCode, config: value ?? configuration(), mode: .automatic,
            storageOption: storage, detectionService: AgentDetectionService(), availableModels: models)
    }

    private func write(_ object: [String: Any], to file: URL) throws {
        try writeData(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), to: file)
    }

    private func writeData(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    private func read(_ file: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    private func source() -> String {
        let value = configuration()
        return ClaudeConfigurationPlan.sourceID(url: value.proxyURL, key: value.apiKey)
    }

    private func menuModels(in object: [String: Any]) -> [String] {
        ((object["modelPicker"] as? [String: Any])?["options"] as? [[String: Any]] ?? [])
            .compactMap { $0["model"] as? String }
    }

    private func assertRemovesManagedShell(_ result: AgentConfigResult, file: StaticString = #filePath, line: UInt = #line) {
        guard case .remove? = result.claudeShellAction else {
            XCTFail("官方恢复必须返回移除受管 Shell 段的动作", file: file, line: line)
            return
        }
    }

    func testRootOwnershipSurvivesNormalizedMenuSaveAndAccountChangeSynchronization() async throws {
        let service = AgentConfigurationService(homeDirectory: home, environment: [:])
        // 未知扩展可能在官方恢复之后单独留在命名空间中；再次应用必须保留它并补入当前管理字段。
        try write(["quotioClaudeCatalog": ["future-owner": ["integer": UInt64.max]],
                   "future-root": ["keep": true]], to: defaultFile)
        let applied = try await generate(service)
        XCTAssertTrue(applied.success, applied.error ?? "")
        XCTAssertNotNil(applied.claudeRollback, "每一次 Claude JSON 自动写入都必须可参与后续 Shell 失败回滚")
        var object = try read(defaultFile)
        let ownership = try XCTUnwrap(object["quotioClaudeCatalog"] as? [String: Any])
        XCTAssertEqual(ownership["managed"] as? Bool, true)
        XCTAssertEqual((ownership["version"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(ownership["source"] as? String, source())
        XCTAssertEqual((ownership["future-owner"] as? [String: NSNumber])?["integer"]?.uint64Value, UInt64.max)
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: ownership), as: UTF8.self).contains("fixture-only-secret"))
        var picker = try XCTUnwrap(object["modelPicker"] as? [String: Any])
        for key in ClaudeCatalogOwnership.legacyKeys { XCTAssertNil(picker[key], "归属不能继续依赖 CLI 会剥离的菜单扩展") }

        // 模拟 CLI /model 保存：只留下 CLI 已知的 modelPicker 字段，并写入新的顶层默认选择。
        // 顶层未知归属仍在；随后回读与账号变更同步不能把它误判成外部未受管菜单。
        let options = try XCTUnwrap(picker["options"] as? [[String: Any]])
        let replacesBuiltIns = try XCTUnwrap(picker["replaceBuiltInOptions"] as? Bool)
        picker = ["replaceBuiltInOptions": replacesBuiltIns,
                  "options": options.map { row in row.filter { ["model", "label", "description"].contains($0.key) } }]
        object["modelPicker"] = picker
        object["model"] = "sonnet[1m]"
        try write(object, to: defaultFile)
        let loaded = await service.readConfiguration(agent: .claudeCode)
        XCTAssertEqual(loaded?.defaultModel, "sonnet[1m]")
        XCTAssertEqual(loaded?.claudeModelPicker.isQuotioManaged, true)
        let managed = await service.managedClaudeConfiguration(serviceBaseURLs: ["https://fixture-tunnel.invalid/deployment"])
        XCTAssertNotNil(managed)
        let added = AvailableModel(id: "account-added-model", name: "account-added-model", provider: "fixture", isDefault: false)
        let synchronized = await service.synchronizeManagedClaudeCatalog(sourceID: source(),
            serviceBaseURLs: ["https://fixture-tunnel.invalid/deployment"], models: models + [added])
        XCTAssertEqual(synchronized?.success, true, synchronized?.error ?? "")
        let after = try read(defaultFile)
        XCTAssertTrue(menuModels(in: after).contains("account-added-model"))
        XCTAssertEqual(after["model"] as? String, "sonnet[1m]", "后台刷新只能重建目录，不能覆盖 CLI 刚保存的默认选择")
        var finalOwnership = try XCTUnwrap(after["quotioClaudeCatalog"] as? [String: Any])
        var originalOwnership = ownership
        // 账号新增会更新已知的自动值快照；归属身份与未知扩展必须保持，不要求可变目录投影逐字相同。
        finalOwnership.removeValue(forKey: ClaudeCatalogProjection.key)
        originalOwnership.removeValue(forKey: ClaudeCatalogProjection.key)
        XCTAssertEqual(finalOwnership as NSDictionary, originalOwnership as NSDictionary)
        XCTAssertEqual((after["future-root"] as? [String: Bool])?["keep"], true)
    }

    func testCompleteLegacyNestedOwnershipIsReadAndUpgradedWithoutLosingMenuFields() async throws {
        let service = AgentConfigurationService(homeDirectory: home, environment: [:])
        let value = configuration()
        let legacy: [String: Any] = [
            "model": "opus",
            "env": ["ANTHROPIC_BASE_URL": "https://fixture-tunnel.invalid/deployment", "ANTHROPIC_AUTH_TOKEN": value.apiKey,
                    "ANTHROPIC_DEFAULT_OPUS_MODEL": "live-one", "ANTHROPIC_DEFAULT_SONNET_MODEL": "live-two",
                    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "live-one"],
            "modelPicker": ["replaceBuiltInOptions": true, "quotioManaged": true, "quotioCatalogVersion": 1,
                            "quotioCatalogSource": source(), "future-menu": ["keep": true],
                            "options": [["model": "opus", "label": "工作角色", "future-row": ["keep": true]]]]]
        try write(legacy, to: defaultFile)
        let loaded = await service.readConfiguration(agent: .claudeCode)
        XCTAssertEqual(loaded?.claudeModelPicker.isQuotioManaged, true)
        let managed = await service.managedClaudeConfiguration(serviceBaseURLs: ["https://fixture-tunnel.invalid/deployment"])
        XCTAssertNotNil(managed)
        let synchronized = await service.synchronizeManagedClaudeCatalog(sourceID: source(),
            serviceBaseURLs: ["https://fixture-tunnel.invalid/deployment"], models: models)
        XCTAssertEqual(synchronized?.success, true, synchronized?.error ?? "")
        let after = try read(defaultFile)
        XCTAssertEqual(ClaudeCatalogOwnership.source(in: after), source())
        XCTAssertNotNil(after["quotioClaudeCatalog"])
        let picker = try XCTUnwrap(after["modelPicker"] as? [String: Any])
        for key in ClaudeCatalogOwnership.legacyKeys { XCTAssertNil(picker[key]) }
        XCTAssertEqual((picker["future-menu"] as? [String: Bool])?["keep"], true)
        let rows = try XCTUnwrap(picker["options"] as? [[String: Any]])
        let role = try XCTUnwrap(rows.first { $0["model"] as? String == "opus" })
        XCTAssertEqual(role["label"] as? String, "工作角色")
        XCTAssertEqual((role["future-row"] as? [String: Bool])?["keep"], true)
    }

    func testRootOwnershipOverridesConflictingLegacyAndFutureSchemaIsNeverClaimed() {
        let legacy: [String: Any] = ["quotioManaged": true, "quotioCatalogVersion": 1, "quotioCatalogSource": "old-source"]
        var settings: [String: Any] = ["modelPicker": legacy,
            "quotioClaudeCatalog": ["managed": true, "version": 1, "source": "root-source"]]
        XCTAssertEqual(ClaudeCatalogOwnership.source(in: settings), "root-source")
        settings["quotioClaudeCatalog"] = ["managed": true, "version": 2, "source": "future-source"]
        XCTAssertNil(ClaudeCatalogOwnership.source(in: settings), "未来根协议不能通过旧嵌套字段重新夺取归属")
        XCTAssertFalse(ClaudeCatalogOwnership.canWrite(in: settings))
        settings["quotioClaudeCatalog"] = ["future-only": ["keep": true]]
        XCTAssertTrue(ClaudeCatalogOwnership.canWrite(in: settings), "没有任何已知管理键的未知扩展命名空间允许补入当前协议")
        settings["quotioClaudeCatalog"] = ["managed": true]
        XCTAssertFalse(ClaudeCatalogOwnership.canWrite(in: settings), "已知键残缺时不能当成未知-only 扩展来覆盖")
        settings["quotioClaudeCatalog"] = ["managed": 1, "version": 1, "source": "numeric-managed"]
        XCTAssertNil(ClaudeCatalogOwnership.source(in: settings), "数字 1 不等于协议要求的 JSON 布尔")
        XCTAssertFalse(ClaudeCatalogOwnership.picker(in: settings).isQuotioManaged, "无效根协议不能借旧嵌套标记旁路")
    }

    /// 同一段业务事务分别验证显式注入和 CLAUDE_CONFIG_DIR；默认目录始终作为不可改动的哨兵。
    /// 不是只检查最终生成路径，还逐项执行回读、备份发现、账号同步、备份恢复与官方恢复。
    private func verifyCustomLocation(_ directory: URL, service: AgentConfigurationService) async throws {
        let file = directory.appendingPathComponent("settings.json")
        let defaultBytes = Data("{\"default-directory-sentinel\":true}\n".utf8)
        try writeData(defaultBytes, to: defaultFile)
        let original: [String: Any] = ["future-root": ["keep": true], "permissions": ["allow": ["Read"]]]
        try write(original, to: file)
        let originalBytes = try Data(contentsOf: file)
        let applied = try await generate(service)
        XCTAssertTrue(applied.success, applied.error ?? "")
        XCTAssertEqual(applied.configPath, file.path)
        let backupPath = try XCTUnwrap(applied.backupPath)
        XCTAssertTrue(backupPath.hasPrefix(file.path + ".backup."))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: backupPath)), originalBytes)
        let loaded = await service.readConfiguration(agent: .claudeCode)
        XCTAssertEqual(loaded?.modelSlots[.opus], "live-one")
        XCTAssertEqual(loaded?.isProxyConfigured, true)
        let backups = await service.listBackups(agent: .claudeCode)
        XCTAssertTrue(backups.contains { $0.path == backupPath })
        XCTAssertTrue(backups.allSatisfy { $0.path.hasPrefix(file.path + ".backup.") })
        let added = AvailableModel(id: "custom-directory-added", name: "custom-directory-added", provider: "fixture", isDefault: false)
        let synchronized = await service.synchronizeManagedClaudeCatalog(sourceID: source(),
            serviceBaseURLs: ["https://fixture-tunnel.invalid/deployment"], models: models + [added])
        XCTAssertEqual(synchronized?.success, true, synchronized?.error ?? "")
        XCTAssertTrue(menuModels(in: try read(file)).contains("custom-directory-added"))
        try await service.restoreFromBackup(XCTUnwrap(backups.first { $0.path == backupPath }))
        XCTAssertEqual(try Data(contentsOf: file), originalBytes)
        let reapplied = try await generate(service)
        XCTAssertTrue(reapplied.success, reapplied.error ?? "")
        let official = try await generate(service, configuration: configuration(setup: .defaultSetup))
        XCTAssertTrue(official.success, official.error ?? "")
        XCTAssertEqual(official.configPath, file.path)
        assertRemovesManagedShell(official)
        XCTAssertNil((try read(file)["env"] as? [String: Any])?["ANTHROPIC_BASE_URL"])
        XCTAssertEqual(try Data(contentsOf: defaultFile), defaultBytes, "自定义目录的所有事务都不能触碰 ~/.claude/settings.json")
        let defaultFiles = try FileManager.default.contentsOfDirectory(atPath: defaultFile.deletingLastPathComponent().path)
        XCTAssertEqual(defaultFiles, ["settings.json"], "默认目录不能产生误放的备份或迁移报告")
    }

    func testExplicitCustomDirectoryWinsOverEnvironmentAndOwnsWholeTransaction() async throws {
        let directory = home.appendingPathComponent("显式配置 é")
        let ignored = home.appendingPathComponent("environment-must-not-be-used")
        let service = AgentConfigurationService(homeDirectory: home, claudeConfigDirectory: directory,
            environment: ["CLAUDE_CONFIG_DIR": ignored.path])
        try await verifyCustomLocation(directory, service: service)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ignored.path))
    }

    func testEnvironmentCustomDirectoryOwnsWholeTransactionWithoutChangingDefaultDirectory() async throws {
        let directory = home.appendingPathComponent("custom config")
        let service = AgentConfigurationService(homeDirectory: home,
            environment: ["CLAUDE_CONFIG_DIR": "~/custom config"])
        try await verifyCustomLocation(directory, service: service)
    }

    func testOfficialRestoreCleansKnownMixedEnvironmentAndSupportsRollbackAndReapply() async throws {
        let service = AgentConfigurationService(homeDirectory: home, environment: [:])
        var env: [String: Any] = Dictionary(uniqueKeysWithValues: ClaudeManagedEnvironment.keys.map { ($0, "managed-value" as Any) })
        env["ANTHROPIC_BASE_URL"] = "https://fixture-tunnel.invalid/deployment"
        env["ANTHROPIC_AUTH_TOKEN"] = configuration().apiKey
        env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = "live-one"
        env["future-object"] = ["keep": [1, 2, 3]]
        env["future-boolean"] = true
        env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = "150000"
        env["ANTHROPIC_API_KEY"] = "user-owned-direct-key"
        let original: [String: Any] = ["env": env, "model": "opus",
            "quotioClaudeCatalog": ["managed": true, "version": 1, "source": source(), "future-owner": ["keep": true]],
            "modelPicker": ["replaceBuiltInOptions": true, "options": [["model": "opus"]]],
            "permissions": ["allow": ["Read"]], "future-root": ["integer": UInt64.max]]
        try write(original, to: defaultFile)
        let originalBytes = try Data(contentsOf: defaultFile)
        let result = try await generate(service, configuration: configuration(setup: .defaultSetup), storage: .both)
        XCTAssertTrue(result.success, result.error ?? "")
        assertRemovesManagedShell(result)
        let cleaned = try read(defaultFile), cleanedEnv = try XCTUnwrap(cleaned["env"] as? [String: Any])
        for key in ClaudeManagedEnvironment.keys { XCTAssertNil(cleanedEnv[key], "单个未知非字符串值不能阻止已知键撤下") }
        XCTAssertEqual((cleanedEnv["future-object"] as? [String: [Int]])?["keep"], [1, 2, 3])
        XCTAssertEqual(cleanedEnv["future-boolean"] as? Bool, true)
        XCTAssertEqual(cleanedEnv["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] as? String, "150000")
        XCTAssertEqual(cleanedEnv["ANTHROPIC_API_KEY"] as? String, "user-owned-direct-key")
        XCTAssertEqual(cleaned["permissions"] as? NSDictionary, original["permissions"] as? NSDictionary)
        XCTAssertEqual((cleaned["future-root"] as? [String: NSNumber])?["integer"]?.uint64Value, UInt64.max)
        XCTAssertNil(cleaned["model"])
        XCTAssertNil(cleaned["modelPicker"])
        XCTAssertEqual(cleaned["quotioClaudeCatalog"] as? NSDictionary, ["future-owner": ["keep": true]] as NSDictionary)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(result.backupPath))), originalBytes)
        let receipt = try XCTUnwrap(result.claudeRollback)
        XCTAssertEqual(receipt.original, originalBytes)
        XCTAssertEqual(receipt.written, try Data(contentsOf: defaultFile))
        try await service.rollbackClaudeConfiguration(receipt)
        XCTAssertEqual(try Data(contentsOf: defaultFile), originalBytes, "后续 Shell 清理失败时可完整回滚官方恢复")

        let restored = try await generate(service, configuration: configuration(setup: .defaultSetup))
        XCTAssertTrue(restored.success, restored.error ?? "")
        let reapplied = try await generate(service)
        XCTAssertTrue(reapplied.success, reapplied.error ?? "")
        let final = try read(defaultFile)
        XCTAssertEqual(ClaudeCatalogOwnership.source(in: final), source())
        XCTAssertEqual(((final["quotioClaudeCatalog"] as? [String: Any])?["future-owner"] as? [String: Bool])?["keep"], true)
    }

    func testOfficialRestoreWithoutJSONStillSchedulesManagedShellRemoval() async throws {
        let service = AgentConfigurationService(homeDirectory: home, environment: [:])
        let result = try await generate(service, configuration: configuration(setup: .defaultSetup))
        XCTAssertTrue(result.success, result.error ?? "")
        assertRemovesManagedShell(result)
        XCTAssertNil(result.claudeRollback)
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultFile.path))
    }

    func testOfficialRestoreRejectsNonObjectAndUnknownEnvironmentStructuresWithoutAnyWrite() async throws {
        let service = AgentConfigurationService(homeDirectory: home, environment: [:])
        for text in ["[1,2]", "null", "{invalid", "{\"env\":[\"opaque\"]}", "{\"env\":true}"] {
            let original = Data(text.utf8)
            try writeData(original, to: defaultFile)
            let result = try await generate(service, configuration: configuration(setup: .defaultSetup))
            XCTAssertFalse(result.success, "无法理解的文件必须拒绝清理：" + text)
            XCTAssertEqual(try Data(contentsOf: defaultFile), original)
            let backups = await service.listBackups(agent: .claudeCode)
            XCTAssertTrue(backups.isEmpty)
        }
    }

    func testAllClaudeAutomaticJSONCommitsReturnRollbackEvenOutsideManagedCatalog() async throws {
        let service = AgentConfigurationService(homeDirectory: home, environment: [:])
        let original = Data("{\"future-root\":{\"keep\":true}}\n".utf8)
        try writeData(original, to: defaultFile)
        let result = try await generate(service, configuration: configuration(managed: false))
        XCTAssertTrue(result.success, result.error ?? "")
        let receipt = try XCTUnwrap(result.claudeRollback)
        XCTAssertEqual(receipt.original, original)
        try await service.rollbackClaudeConfiguration(receipt)
        XCTAssertEqual(try Data(contentsOf: defaultFile), original)
    }

    func testTunnelRemoteAndLocalSourcesRemainProxyWhileOfficialEndpointStaysOfficial() async throws {
        let service = AgentConfigurationService(homeDirectory: home, environment: [:])
        for endpoint in ["https://fixture-tunnel.invalid/deployment", "http://192.168.1.2:8317", "http://127.0.0.1:8317", "http://localhost:8317", "legacy-invalid-address"] {
            try write(["env": ["ANTHROPIC_BASE_URL": endpoint]], to: defaultFile)
            let loaded = await service.readConfiguration(agent: .claudeCode)
            XCTAssertEqual(loaded?.isProxyConfigured, true, "连接来源不能通过 localhost 子串推断：" + endpoint)
        }
        for endpoint in ["https://api.anthropic.com", "https://API.ANTHROPIC.COM/v1"] {
            try write(["env": ["ANTHROPIC_BASE_URL": endpoint]], to: defaultFile)
            let loaded = await service.readConfiguration(agent: .claudeCode)
            XCTAssertEqual(loaded?.isProxyConfigured, false)
        }
        XCTAssertFalse(ClaudeConfigurationSource.isProxyEndpoint(nil))
        XCTAssertFalse(ClaudeConfigurationSource.isProxyEndpoint(""))
        XCTAssertEqual(ClaudeConfigurationSource.modelAPIBaseURL("https://fixture-tunnel.invalid/deployment/"), "https://fixture-tunnel.invalid/deployment/v1")
        XCTAssertEqual(ClaudeConfigurationSource.modelAPIBaseURL("https://fixture-tunnel.invalid/deployment/v1/"), "https://fixture-tunnel.invalid/deployment/v1")
    }
    /// CLI 从追加菜单保存的具体型号不一定出现在角色 env；官方恢复仍须撤下它，避免发向官方。
    /// 不相干的独立默认值保留；上下文后缀只改变选择器声明，不改变模型归属身份。
    func testOfficialRestoreRemovesOwnedLiteralMenuDefaultsAndPreservesUnrelatedDefaults() async throws {
        let service = AgentConfigurationService(homeDirectory: home, environment: [:])
        for (selected, shouldRemove) in [("menu-only-model", true), ("live-one[1m]", true), ("user-owned-official-model", false)] {
            try write(["model": selected,
                "env": ["ANTHROPIC_DEFAULT_OPUS_MODEL": "live-one", "ANTHROPIC_BASE_URL": "https://fixture.invalid"],
                "quotioClaudeCatalog": ["managed": true, "version": 1, "source": source()],
                "modelPicker": ["options": [["model": "menu-only-model"]], "replaceBuiltInOptions": true,
                                "future-menu": ["keep": true]]], to: defaultFile)
            let result = try await generate(service, configuration: configuration(setup: .defaultSetup))
            XCTAssertTrue(result.success, result.error ?? "")
            let restored = try read(defaultFile)
            XCTAssertEqual(restored["model"] as? String, shouldRemove ? nil : selected)
            let menu = try XCTUnwrap(restored["modelPicker"] as? [String: Any])
            XCTAssertEqual(menu["future-menu"] as? NSDictionary, ["keep": true])
            XCTAssertNil(menu["options"])
            XCTAssertNil(menu["replaceBuiltInOptions"])
        }
    }

    /// 通用 Shell 覆盖检查必须复用领域语义；inherit 与未设、布尔的等价旧写法无需强制改 JSON。
    func testShellOnlyPreservesEquivalentSubagentRules() async throws {
        let service = AgentConfigurationService(homeDirectory: home, environment: [:])
        for (oldModel, oldForce, newModel, newForce) in [
            ("inherit", "0", nil as String?, ""), ("live-two", " YES ", "live-two", "1")
        ] {
            try write(["env": ["CLAUDE_CODE_SUBAGENT_MODEL": oldModel,
                                 "CLAUDE_CODE_SUBAGENT_MODEL_FORCE": oldForce]], to: defaultFile)
            let original = try Data(contentsOf: defaultFile)
            var value = configuration(managed: false)
            value.claudeSubagentModel = newModel
            value.claudeSubagentModelForce = newForce
            let result = try await generate(service, configuration: value, storage: .shellOnly)
            XCTAssertTrue(result.success, result.error ?? "")
            XCTAssertEqual(try Data(contentsOf: defaultFile), original)
        }
    }

    /// 对真正支持的 POSIX Shell 执行生成脚本，验证凭据只作字面量而不会展开；fish 核对原生语法。
    /// 所有命令都在临时 cwd、最小环境中运行，不 source 用户 Profile，也不改写 HOME。
    func testTargetShellStatementsAreLiteralAndClearStaleOptionalOverrides() async throws {
        let service = AgentConfigurationService(homeDirectory: home, environment: [:])
        let sentinel = home.appendingPathComponent("must-not-be-created")
        var value = configuration(managed: false)
        value.apiKey = "fixture'$(touch " + sentinel.path + ")"
        for shell in ShellType.allCases {
            let result = try await service.generateConfiguration(agent: .claudeCode, config: value, mode: .manual,
                detectionService: AgentDetectionService(), availableModels: models, shell: shell)
            XCTAssertTrue(result.success, result.error ?? "")
            let output = try XCTUnwrap(result.rawConfigs.first { $0.format == .shellExport })
            XCTAssertEqual(output.targetPath, shell.profilePath)
            if shell == .fish {
                XCTAssertTrue(output.content.contains("set -gx ANTHROPIC_AUTH_TOKEN "))
                XCTAssertTrue(output.content.contains("set -e CLAUDE_CODE_MAX_CONTEXT_TOKENS"))
                XCTAssertFalse(output.content.contains("unset "))
                XCTAssertFalse(output.content.contains("export "))
                continue
            }
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: shell == .zsh ? "/bin/zsh" : "/bin/bash")
            process.arguments = ["-f", "-c", output.content + "\nprintf '%s' \"$ANTHROPIC_AUTH_TOKEN\""]
            process.environment = ["PATH": "/usr/bin:/bin", "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "200000"]
            process.currentDirectoryURL = home
            process.standardOutput = pipe; process.standardError = pipe
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), value.apiKey)
            XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        }
    }

}
