import Foundation
import XCTest
@testable import QuotioPlus

/// 使用生产配置生成器和本机 Claude CLI 做真实 HTTP 回归，而非自行构造期望请求。
/// 临时配置、假密钥与仅监听 loopback 的网关相互隔离；不读取用户凭据，也不调用真实模型。
final class ClaudeCLIRequestCompatibilityTests: XCTestCase {
    /// 用生产生成器修正过期的角色说明，再由真实 CLI 选择 Opus 请求本地假网关。
    /// 同时断言菜单说明与 HTTP model，避免只修展示却继续把请求发给旧角色目标。
    func testChangedOpusGeminiMappingUpdatesMenuAndActualRequestTogether() async throws {
        let executable = "/opt/homebrew/bin/claude"
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("未安装 Claude CLI") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeRoleMenu-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try ClaudeLoopbackGateway(); defer { gateway.stop() }
        let service = AgentConfigurationService(homeDirectory: root)
        let gemini = "gemini-3.8-flash-high", gpt = "gpt-6.1-sol"
        let settings = root.appendingPathComponent(".claude/settings.json")
        let menu: [String: Any] = ["options": [["model": "opus", "label": "Opus", "description": "codex/" + gpt]]]
        try JSONSerialization.data(withJSONObject: ["modelPicker": menu]).write(to: settings)
        var value = AgentConfiguration(agent: .claudeCode, proxyURL: gateway.url + "/v1", apiKey: "fixture-only-key")
        value.claudeCatalogManaged = true
        value.modelSlots = [.opus: gemini, .sonnet: gpt, .haiku: gemini]
        value.claudeModel1M = [.opus: true]
        let directory = [AvailableModel(id: gemini, name: gemini, provider: "fixture", isDefault: false, displayPlatform: "antigravity"),
                         AvailableModel(id: gpt, name: gpt, provider: "fixture", isDefault: false, displayPlatform: "codex")]
        let generated = try await service.generateConfiguration(agent: .claudeCode, config: value, mode: .automatic,
            detectionService: AgentDetectionService(), availableModels: directory)
        XCTAssertTrue(generated.success, generated.error ?? "")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let rows = try XCTUnwrap((object["modelPicker"] as? [String: Any])?["options"] as? [[String: Any]])
        XCTAssertEqual(rows.first { $0["model"] as? String == "opus" }?["description"] as? String, "antigravity/" + gemini + "[1m]")
        let output = try runCLI(executable: executable, settings: settings, root: root, model: "opus", gatewayURL: gateway.url, index: 50)
        XCTAssertEqual(output.status, 0, String(output.text.prefix(1200)))
        XCTAssertFalse(gateway.requests.isEmpty)
        XCTAssertTrue(gateway.requests.allSatisfy { $0.model == gemini }, "\(gateway.requests.map(\.model))")
        XCTAssertTrue(gateway.requests.contains { $0.beta.contains("context-1m") })
        XCTAssertTrue(gateway.requests.allSatisfy(\.usesFixtureKey))
    }

    /// 同一后端型号可以分别绑定 Sonnet／Haiku；1M 是各角色的请求声明，不能按裸 ID 共用。
    /// 反转两个角色的开关后再次启动真实 CLI，避免只验证恰好与遍历顺序一致的一种组合。
    func testSameModelSonnetAndHaikuKeepIndependentOneMillionRequests() async throws {
        let executable = "/opt/homebrew/bin/claude"
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("未安装 Claude CLI") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeSameModel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try ClaudeLoopbackGateway(); defer { gateway.stop() }
        let model = "gemini-3.8-flash-high"
        let directory = [AvailableModel(id: model, name: model, provider: "fixture", isDefault: false, displayPlatform: "antigravity")]
        let service = AgentConfigurationService(homeDirectory: root)
        var value = AgentConfiguration(agent: .claudeCode, proxyURL: gateway.url + "/v1", apiKey: "fixture-only-key")
        value.claudeCatalogManaged = true
        value.modelSlots = [.opus: model, .sonnet: model, .haiku: model]
        let settings = root.appendingPathComponent(".claude/settings.json")
        for (round, longRole) in [ModelSlot.haiku, .sonnet].enumerated() {
            value.claudeModel1M = [.opus: false, .sonnet: longRole == .sonnet, .haiku: longRole == .haiku]
            let generated = try await service.generateConfiguration(agent: .claudeCode, config: value, mode: .automatic,
                detectionService: AgentDetectionService(), availableModels: directory)
            XCTAssertTrue(generated.success, generated.error ?? "")
            for (index, role) in [ModelSlot.sonnet, .haiku].enumerated() {
                let before = gateway.requests.count
                let output = try runCLI(executable: executable, settings: settings, root: root, model: role.rawValue,
                    gatewayURL: gateway.url, index: 60 + round * 2 + index)
                XCTAssertEqual(output.status, 0, String(output.text.prefix(1200)))
                let requests = Array(gateway.requests.dropFirst(before))
                XCTAssertFalse(requests.isEmpty)
                XCTAssertTrue(requests.allSatisfy { $0.model == model && $0.usesFixtureKey })
                XCTAssertTrue(requests.allSatisfy { $0.beta.contains("context-1m") == (role == longRole) },
                    "同型号的 \(role.rawValue) 不应继承另一角色的 1M：\(requests.map(\.beta))")
                let evidence = XCTAttachment(string: "role=\(role.rawValue) longRole=\(longRole.rawValue)\n" + requests.map {
                    "model=\($0.model) context1m=\($0.beta.contains("context-1m"))"
                }.joined(separator: "\n"))
                evidence.name = "同型号角色独立 1M 请求"; evidence.lifetime = .keepAlways; add(evidence)
            }
        }
    }

    func testGeneratedDefaultRoleMenuQualifiedIDAndOneMillionReachActualGateway() async throws {
        let executable = "/opt/homebrew/bin/claude"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw XCTSkip("本机未安装 Claude CLI；纯配置契约仍由其他定向用例验证")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeWire-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try ClaudeLoopbackGateway()
        defer { gateway.stop() }
        let service = AgentConfigurationService(homeDirectory: root)
        let directory = ["gpt-6.1-sol", "gpt-6-astra", "glm/glm-5.3"].map {
            AvailableModel(id: $0, name: $0, provider: "fixture", isDefault: false)
        }
        var config = AgentConfiguration(agent: .claudeCode, proxyURL: gateway.url + "/v1", apiKey: "fixture-only-key")
        config.modelSlots = [.opus: "codex/gpt-6.1-sol", .sonnet: "codex/gpt-6-astra", .haiku: "glm/glm-5.3"]
        // 同时覆盖名称碰撞元数据：CLI 必须能正常读取带保留标记的真实生成配置。
        config.claudeModelDisplayNames = [.opus: "gpt-6.1-sol"]
        config.claudeDefaultModel = "codex/gpt-6.1-sol"
        config.claudeModelPicker = .read(["options": [
            ["model": "codex/gpt-6-astra", "label": "菜单模型", "description": "测试账号"],
            ["model": "glm/glm-5.3", "label": "合法前缀"],
            ["model": "codex/gpt-6.1-sol[1m]", "label": "长上下文"]]])
        let generated = try await service.generateConfiguration(agent: .claudeCode, config: config, mode: .automatic,
            detectionService: AgentDetectionService(), availableModels: directory)
        XCTAssertTrue(generated.success, generated.error ?? "")
        let settings = root.appendingPathComponent(".claude/settings.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertNotNil(json["quotioModelNameBindings"])
        XCTAssertEqual((json["env"] as? [String: String])?["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"], "gpt-6.1-sol")
        let rows = try XCTUnwrap((json["modelPicker"] as? [String: Any])?["options"] as? [[String: Any]])

        // 默认配置、原生角色和菜单行都由同一份生成结果驱动；每次以独立 CLI 进程选择。
        let selections: [(String?, String)] = [
            (nil, "gpt-6.1-sol"), ("sonnet", "gpt-6-astra"),
            (try XCTUnwrap(rows[0]["model"] as? String), "gpt-6-astra"),
            (try XCTUnwrap(rows[1]["model"] as? String), "glm/glm-5.3"),
            (try XCTUnwrap(rows[2]["model"] as? String), "gpt-6.1-sol")]
        for (index, selection) in selections.enumerated() {
            let before = gateway.requests.count
            let output = try runCLI(executable: executable, settings: settings, root: root,
                                    model: selection.0, gatewayURL: gateway.url, index: index)
            XCTAssertEqual(output.status, 0, "CLI 场景 \(index) 未完成：\(output.text.prefix(1200))")
            let requests = Array(gateway.requests.dropFirst(before))
            let evidence = XCTAttachment(string: "selection=\(selection.0 ?? "settings default")\n" + requests.map {
                "POST /v1/messages model=\($0.model) beta=\($0.beta) fixtureKey=\($0.usesFixtureKey)"
            }.joined(separator: "\n"))
            evidence.name = "Claude CLI 实际请求场景 \(index)"
            evidence.lifetime = .keepAlways
            add(evidence)
            XCTAssertFalse(requests.isEmpty, "场景 \(index) 必须真的请求本地网关")
            XCTAssertTrue(requests.allSatisfy { $0.model == selection.1 }, "场景 \(index)：\(requests.map(\.model))")
            XCTAssertTrue(requests.allSatisfy(\.usesFixtureKey))
            if index == selections.count - 1 {
                XCTAssertEqual(selection.0, "gpt-6.1-sol[1m]", "配置中不能丢失长上下文声明")
                XCTAssertTrue(requests.contains { $0.beta.contains("context-1m") }, "CLI 应把 [1m] 转为长上下文 beta header")
            }
        }
    }

    func testGeneratedSubagentDefaultsForceInheritAndShellReachActualGateway() async throws {
        let executable = "/opt/homebrew/bin/claude"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw XCTSkip("本机未安装 Claude CLI；配置事务仍由定向单元回归覆盖")
        }
        // 每个场景使用新进程和新监听端口，捕获真实的 Agent 子请求，而非只验证导出的字符串。
        let cases: [(name: String, child: String?, force: String?, definition: String?, expected: String,
                     oneMillion: Bool, storage: ConfigStorageOption, inherited: Bool)] = [
            ("default-respects-frontmatter", "codex/gpt-6-astra", nil, "haiku", "glm/glm-5.3", false, .jsonOnly, false),
            ("forced-role-one-million", "sonnet", "1", "haiku", "gpt-6-astra", true, .both, false),
            ("inherit-overrides-old-shell", "inherit", "", nil, "gpt-6.1-sol", false, .jsonOnly, true),
            ("off-respects-frontmatter", "inherit", "", "haiku", "glm/glm-5.3", false, .jsonOnly, true),
            ("legacy-zero-force-disabled", "inherit", "0", "haiku", "glm/glm-5.3", false, .jsonOnly, false),
            ("legacy-false-force-disabled", "inherit", " false ", "haiku", "glm/glm-5.3", false, .jsonOnly, false),
            ("legacy-yes-force-enabled", "inherit", " YES ", "haiku", "gpt-6.1-sol", false, .jsonOnly, false),
            ("new-shell-only", "codex/gpt-6-astra", "1", "haiku", "gpt-6-astra", false, .shellOnly, false),
            ("json-repairs-shell-conflict", "codex/gpt-6-astra", "1", "haiku", "gpt-6-astra", false, .both, false),
            ("custom-context-prefix", "codex/gpt-6-astra[1M]", nil, nil, "gpt-6-astra", true, .jsonOnly, false),
            ("force-only-main", nil, "1", "haiku", "gpt-6.1-sol", false, .jsonOnly, false)
        ]
        for (index, scenario) in cases.enumerated() {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeSubagentWire-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let gateway = try ClaudeLoopbackGateway(subagentType: "audit-child")
            defer { gateway.stop() }
            let service = AgentConfigurationService(homeDirectory: root)
            let directory = ["gpt-6.1-sol", "gpt-6-astra", "glm/glm-5.3"].map {
                AvailableModel(id: $0, name: $0, provider: "fixture", isDefault: false)
            }
            var config = AgentConfiguration(agent: .claudeCode, proxyURL: gateway.url + "/v1", apiKey: "fixture-only-key")
            config.modelSlots = [.opus: "gpt-6.1-sol", .sonnet: "codex/gpt-6-astra", .haiku: "glm/glm-5.3"]
            config.claudeModel1M[.sonnet] = true
            config.claudeDefaultModel = "gpt-6.1-sol"
            config.claudeSubagentModel = scenario.child
            config.claudeSubagentModelForce = scenario.force
            let settings = root.appendingPathComponent(".claude/settings.json")
            if scenario.name == "json-repairs-shell-conflict" {
                try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
                let old: [String: Any] = ["env": ["CLAUDE_CODE_SUBAGENT_MODEL": "fixture/obsolete", "CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "1"]]
                let data = try JSONSerialization.data(withJSONObject: old)
                try data.write(to: settings)
                let denied = try await service.generateConfiguration(agent: .claudeCode, config: config, mode: .automatic,
                    storageOption: .shellOnly, detectionService: AgentDetectionService(), availableModels: directory)
                XCTAssertFalse(denied.success)
                XCTAssertEqual(try Data(contentsOf: settings), data)
            }
            let generated = try await service.generateConfiguration(agent: .claudeCode, config: config, mode: .automatic,
                storageOption: scenario.storage, detectionService: AgentDetectionService(), availableModels: directory)
            XCTAssertTrue(generated.success, generated.error ?? scenario.name)
            if scenario.storage == .shellOnly {
                // 仅 Shell 不应偷写 JSON；CLI 显式加载空夹具，随后由生成的临时 Shell 脚本提供全部设置。
                XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
                try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("{}".utf8).write(to: settings)
            }
            let inherited = scenario.inherited
                ? ["CLAUDE_CODE_SUBAGENT_MODEL": "fixture/old-shell", "CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "1"] : [:]
            let output = try runCLI(executable: executable, settings: settings, root: root, model: nil,
                gatewayURL: gateway.url, index: index, spawnsSubagent: true, childModel: scenario.definition,
                extraEnvironment: inherited, shellExports: scenario.storage == .shellOnly ? generated.shellConfig : nil)
            XCTAssertEqual(output.status, 0, "\(scenario.name)：\(output.text.suffix(1500))")
            let result = output.text.split(separator: "\n").compactMap { line -> [String: Any]? in
                guard let data = line.data(using: .utf8) else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }.first { $0["type"] as? String == "result" }
            let stats = try XCTUnwrap(result?["subagent_stats"] as? [String: Any], scenario.name)
            XCTAssertEqual(stats["spawned"] as? Int, 1, "必须真的启动子代理")
            XCTAssertEqual(stats["completed"] as? Int, 1)
            XCTAssertEqual(stats["failed"] as? Int, 0)
            let requests = gateway.requests
            XCTAssertGreaterThanOrEqual(requests.count, 3, "必须捕获主会话→子代理→主会话收尾")
            XCTAssertTrue(requests.allSatisfy(\.usesFixtureKey))
            XCTAssertTrue(requests.allSatisfy { $0.model == "gpt-6.1-sol" || $0.model == scenario.expected }, scenario.name)
            XCTAssertTrue(requests.contains { $0.model == scenario.expected && (!scenario.oneMillion || $0.beta.contains("context-1m")) }, scenario.name)
            let attachment = XCTAttachment(string: scenario.name + "\n" + requests.map {
                "model=\($0.model) context1m=\($0.beta.contains("context-1m")) fixtureKey=\($0.usesFixtureKey)"
            }.joined(separator: "\n"))
            attachment.name = "子代理实际请求 \(scenario.name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// 遍历生产生成的目录菜单逐项调用真实 CLI，包含原生 Default 与角色；不使用自行拼装的菜单。
    /// 旧型号必须先退出磁盘菜单，随后每个可选项只能向本地网关发送当前目录确认的 ID。
    func testCatalogManagedMenuRowsAndDefaultReachConfirmedGatewayModels() async throws {
        let executable = "/opt/homebrew/bin/claude"
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("未安装 Claude CLI") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCatalogWire-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gateway = try ClaudeLoopbackGateway(); defer { gateway.stop() }
        let directory = ["gpt-6.1-sol", "gpt-6-astra", "legal/custom-model"].map {
            AvailableModel(id: $0, name: $0, provider: "fixture", isDefault: false)
        }
        let settings = root.appendingPathComponent(".claude/settings.json")
        try JSONSerialization.data(withJSONObject: ["modelPicker": ["options": [
            ["model": "codex/gpt-6.1-sol[1m]", "label": "Catalog Long Context"],
            ["model": "retired-catalog-model", "label": "Retired Catalog Model"]]]]).write(to: settings)
        var config = AgentConfiguration(agent: .claudeCode, proxyURL: gateway.url + "/v1", apiKey: "fixture-only-key")
        config.claudeCatalogManaged = true
        config.modelSlots = [.opus: "codex/gpt-6.1-sol", .sonnet: "gpt-6-astra", .haiku: "gpt-6.1-sol"]
        config.claudeDefaultModel = "sonnet"
        let service = AgentConfigurationService(homeDirectory: root)
        let result = try await service.generateConfiguration(agent: .claudeCode, config: config, mode: .automatic,
            detectionService: AgentDetectionService(), availableModels: directory)
        XCTAssertTrue(result.success, result.error ?? "")
        let data = try Data(contentsOf: settings)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let menu = try XCTUnwrap(document["modelPicker"] as? [String: Any])
        XCTAssertEqual(menu["replaceBuiltInOptions"] as? Bool, true)
        let rows = try XCTUnwrap(menu["options"] as? [[String: Any]])
        XCTAssertFalse(rows.contains { $0["model"] as? String == "retired-catalog-model" })
        let generated = XCTAttachment(string: String(decoding: data, as: UTF8.self))
        generated.name = "catalog-generated-settings"; generated.lifetime = .keepAlways; add(generated)
        let plan = ClaudeConfigurationPlan(configuration: config, availableModels: directory)
        let selections: [(String?, String)] = [(nil, "gpt-6-astra"), ("default", "gpt-6-astra")]
            + (try rows.map { row in
                let selector = try XCTUnwrap(row["model"] as? String)
                return (selector, try XCTUnwrap(plan.confirmedRequest(selector)))
            })
        for (index, item) in selections.enumerated() {
            let before = gateway.requests.count
            let output = try runCLI(executable: executable, settings: settings, root: root, model: item.0, gatewayURL: gateway.url, index: index)
            XCTAssertEqual(output.status, 0, String(output.text.prefix(1200)))
            let requests = Array(gateway.requests.dropFirst(before))
            XCTAssertFalse(requests.isEmpty)
            XCTAssertTrue(requests.allSatisfy { $0.model == AgentConfiguration.normalizedClaudeModelID(item.1).base })
            XCTAssertTrue(requests.allSatisfy(\.usesFixtureKey))
            if item.1.hasSuffix("[1m]") { XCTAssertTrue(requests.contains { $0.beta.contains("context-1m") }) }
            let evidence = XCTAttachment(string: "selector=\(item.0 ?? "Default") models=" + requests.map(\.model).joined(separator: ","))
            evidence.name = "受管菜单实际请求 \(index)"; evidence.lifetime = .keepAlways; add(evidence)
        }
    }

    /// 专项复现本轮审计发现：角色链不能向 CPA 发送中间角色名，128K 的旧 false 不能变为 1M beta。
    func testRoleChainAndExplicitlyDisabledOneMillionReachActualGateway() async throws {
        let executable = "/opt/homebrew/bin/claude"
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("未安装 Claude CLI") }
        for usesChain in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeAuditWire-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let gateway = try ClaudeLoopbackGateway(); defer { gateway.stop() }
            let model = usesChain ? "fixture-live-model" : "moonshot-v1-128k"
            let directory = [AvailableModel(id: model, name: model, provider: "fixture", isDefault: false)]
            var config = AgentConfiguration(agent: .claudeCode, proxyURL: gateway.url + "/v1", apiKey: "fixture-only-key")
            config.claudeCatalogManaged = true
            config.modelSlots = usesChain ? [.opus: "sonnet", .sonnet: "haiku", .haiku: model]
                : [.opus: model, .sonnet: model, .haiku: model]
            config.claudeModel1M = [.opus: false, .sonnet: false, .haiku: usesChain]
            config.claudeDefaultModel = "opus"
            let service = AgentConfigurationService(homeDirectory: root)
            let result = try await service.generateConfiguration(agent: .claudeCode, config: config, mode: .automatic,
                detectionService: AgentDetectionService(), availableModels: directory)
            XCTAssertTrue(result.success, result.error ?? "")
            let settings = root.appendingPathComponent(".claude/settings.json")
            let selections: [String?] = usesChain ? [nil, "default", "opus"] : [nil]
            for (index, selector) in selections.enumerated() {
                let before = gateway.requests.count
                let output = try runCLI(executable: executable, settings: settings, root: root, model: selector,
                                        gatewayURL: gateway.url, index: index)
                XCTAssertEqual(output.status, 0, String(output.text.prefix(1000)))
                let requests = Array(gateway.requests.dropFirst(before))
                XCTAssertFalse(requests.isEmpty)
                XCTAssertTrue(requests.allSatisfy { $0.model == model && $0.usesFixtureKey })
                XCTAssertTrue(requests.allSatisfy { $0.beta.contains("context-1m") == usesChain })
                let evidence = XCTAttachment(string: "chain=\(usesChain) selector=\(selector ?? "startup")\n" + requests.map {
                    "model=\($0.model) beta=\($0.beta)"
                }.joined(separator: "\n"))
                evidence.name = "审计修复真实 CLI 请求"; evidence.lifetime = .keepAlways; add(evidence)
            }
        }
    }

    /// 子代理请求必须真的执行 Agent 工具；--bare 会开启 SIMPLE 模式并移除 Agent，不能拿主会话请求代替。
    /// 两类用例仍共用独立目录、假凭据、来源禁用与进程超时；Shell 分支只 source 临时脚本，不写用户 profile。
    private func runCLI(executable: String, settings: URL, root: URL, model: String?, gatewayURL: String,
                        index: Int, spawnsSubagent: Bool = false, childModel: String? = nil,
                        extraEnvironment: [String: String] = [:], shellExports: String? = nil) throws -> (status: Int32, text: String) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = root
        process.arguments = (spawnsSubagent ? [] : ["--bare"]) + ["--setting-sources", "", "--settings", settings.path,
                             "--no-session-persistence", "--tools", spawnsSubagent ? "Agent" : "", "--print", "--output-format", "json",
                             "--max-turns", spawnsSubagent ? "3" : "1", "--system-prompt", "Local fixture only."]
        if spawnsSubagent {
            var definition: [String: Any] = ["description": "Local deterministic audit", "prompt": "Reply fixture only.", "tools": []]
            if let childModel { definition["model"] = childModel }
            let agents = String(decoding: try JSONSerialization.data(withJSONObject: ["audit-child": definition]), as: UTF8.self)
            // 此进程只开放 Agent，网关只返回一次预置调用；关闭分类器以免把辅助请求误当成子代理请求。
            process.arguments! += ["--allowedTools", "Agent", "--permission-mode", "bypassPermissions", "--agents", agents]
        }
        if let model { process.arguments! += ["--model", model] }
        process.arguments!.append("Reply fixture.")
        // 不继承父进程的 OAuth、代理、项目 hook 或遥测配置；不覆盖 HOME／CODEX_HOME。
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "TMPDIR": root.path,
            "CLAUDE_CONFIG_DIR": root.appendingPathComponent("cli-\(index)").path,
            "ANTHROPIC_API_KEY": "fixture-only-key", "ANTHROPIC_BASE_URL": gatewayURL,
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1",
            "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"]
        process.environment!.merge(extraEnvironment) { _, new in new }
        if let shellExports {
            let script = root.appendingPathComponent("shell-\(index).sh")
            try shellExports.write(to: script, atomically: true, encoding: .utf8)
            process.arguments = ["-f", "-c", "source \"$1\"; shift; exec \"$@\"", "isolated-subagent", script.path, executable] + process.arguments!
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // 超时只终止本测试创建的进程；网关运行于独立队列，CLI 等待期间仍正常处理请求。
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
