import Foundation
import XCTest
@testable import QuotioPlus

/// 覆盖应用与真实 Claude Code 共同维护一份设置文件的完整生命周期。
/// 与单纯 --model 发请求的回归不同，此处必须真的执行交互式 /model 并观察 CLI 的 userSettings 重写。
/// 所有配置、全局状态、备份和凭据均位于临时目录；子进程网络只允许本地白名单假网关。
final class ClaudeConfigurationWorkflowTests: XCTestCase {
    /// 真正执行 /model 选择自动长窗口菜单项；CLI 改写后再模拟账号池与目录容量变化，核对最终请求。
    func testInteractiveMenuSaveKeepsGeneratedNamePoolAndContextAutomaticAcrossCatalogChanges() async throws {
        guard FileManager.default.isExecutableFile(atPath: ClaudeInteractiveWorkflowSession.executable),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw XCTSkip("缺少 CLI 或网络隔离工具，不能执行真实 /model 回归")
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ClaudeConfigurationWorkflow-" + UUID().uuidString)
        let directory = root.appendingPathComponent("isolated-claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = directory.appendingPathComponent("settings.json")
        let gateway = try ClaudeLoopbackGateway(acceptedModels: ["fixture-main", "fixture-extra"])
        defer { gateway.stop() }
        let service = AgentConfigurationService(homeDirectory: root, claudeConfigDirectory: directory, environment: [:])
        var config = AgentConfiguration(agent: .claudeCode, proxyURL: gateway.url + "/v1", apiKey: "fixture-only-key")
        config.claudeCatalogManaged = true
        config.modelSlots = [.opus: "fixture-main", .sonnet: "fixture-main", .haiku: "fixture-main"]
        func models(long: Bool) -> [AvailableModel] {
            [.init(id: "fixture-main", name: "Main", provider: "fixture", isDefault: false),
             .init(id: "fixture-extra", name: long ? "Pool Model" : "Updated Model", provider: "fixture", isDefault: false,
                   displaySource: .init(platforms: ["codex"], account: long ? nil : "one@test.invalid", isAccountPool: long),
                   contextWindow: long ? 1_048_576 : 128_000)]
        }
        func object() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        }
        func row(_ document: [String: Any]) throws -> [String: Any] {
            let rows = try XCTUnwrap((document["modelPicker"] as? [String: Any])?["options"] as? [[String: Any]])
            return try XCTUnwrap(rows.first { ($0["model"] as? String)?.hasPrefix("fixture-extra") == true })
        }
        let applied = try await service.generateConfiguration(agent: .claudeCode, config: config, mode: .automatic,
            detectionService: AgentDetectionService(), availableModels: models(long: true))
        XCTAssertTrue(applied.success, applied.error ?? "")
        let projection = try XCTUnwrap((object()["quotioClaudeCatalog"] as? [String: Any])?["projection"] as? NSDictionary)
        let cli = try ClaudeInteractiveWorkflowSession(root: root, directory: directory, gatewayURL: gateway.url)
        defer { cli.stop() }
        do { try cli.saveDefaultModel("fixture-extra[1m]") }
        catch { attach(cli.text, name: "追加菜单选择失败"); throw error }
        XCTAssertEqual(try object()["model"] as? String, "fixture-extra[1m]")
        XCTAssertEqual((try object()["quotioClaudeCatalog"] as? [String: Any])?["projection"] as? NSDictionary, projection)
        let read = await service.readConfiguration(agent: .claudeCode)
        XCTAssertEqual(read?.defaultModel, "fixture-extra")
        XCTAssertEqual(read?.claudeDefaultModel1M, false, "从自动菜单选入 Default 后不能被 CLI 写盘变成固定 1M")
        for long in [false, true] {
            let synchronized = await service.synchronizeManagedClaudeCatalog(
                sourceID: ClaudeConfigurationPlan.sourceID(url: config.proxyURL, key: config.apiKey),
                serviceBaseURLs: [gateway.url], models: models(long: long))
            XCTAssertEqual(synchronized?.success, true, synchronized?.error ?? "")
            let document = try object(), item = try row(document)
            XCTAssertEqual(item["label"] as? String, long ? "Pool Model[1m]" : "Updated Model")
            XCTAssertEqual(item["model"] as? String, long ? "fixture-extra[1m]" : "fixture-extra")
            XCTAssertEqual(item["description"] as? String,
                long ? "Codex · " + "agents.claudeMenu.accountPool".localizedStatic() : "Codex · one@test.invalid")
            XCTAssertEqual(document["model"] as? String, long ? "fixture-extra[1m]" : "fixture-extra")
            let before = gateway.requests.count
            let output = try ClaudeInteractiveWorkflowSession.runSavedDefault(root: root, directory: directory, gatewayURL: gateway.url)
            XCTAssertEqual(output.status, 0, String(output.text.suffix(1500)))
            let requests = Array(gateway.requests.dropFirst(before))
            XCTAssertFalse(requests.isEmpty)
            XCTAssertTrue(requests.allSatisfy { $0.model == "fixture-extra" && $0.usesFixtureKey
                && $0.beta.contains("context-1m") == long })
        }
        attach(cli.text, name: "追加菜单保存与自动上下文 CLI 回执")
    }

    func testApplicationInteractiveModelSaveAndAccountSyncPreserveOwnershipAndActualRequests() async throws {
        guard FileManager.default.isExecutableFile(atPath: ClaudeInteractiveWorkflowSession.executable) else {
            throw XCTSkip("本机未安装 Claude CLI，无法执行真实交互式 /model 回归")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw XCTSkip("当前宿主不提供 sandbox-exec，禁止在没有出站隔离的情况下启动交互式 CLI")
        }
        // macOS 的 /var 可能由 /private/var 映射；信任键使用实际 cwd，不能让符号链接别名重新触发向导。
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ClaudeConfigurationWorkflow-" + UUID().uuidString)
        let directory = root.appendingPathComponent("isolated-claude", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = directory.appendingPathComponent("settings.json")
        // 这两个集合是后端独立契约，不从 ClaudeConfigurationPlan 的解释结果生成。
        // 模型一／二保持可用，账号停用只移除未绑定角色的旧菜单项，随后新增另一账号的模型。
        let initialIDs: Set<String> = ["fixture-live-one", "fixture-live-two", "fixture-disabled-account"]
        let changedIDs: Set<String> = ["fixture-live-one", "fixture-live-two", "fixture-new-account"]
        let gateway = try ClaudeLoopbackGateway(acceptedModels: initialIDs)
        defer { gateway.stop() }
        // CLI 的连接成功必须证明应用写出的文件生效，不能由额外进程环境替它补上地址或认证。
        let cliEnvironment = ClaudeInteractiveWorkflowSession.environment(root: root, directory: directory, gatewayURL: gateway.url)
        XCTAssertNil(cliEnvironment["ANTHROPIC_API_KEY"])
        XCTAssertNil(cliEnvironment["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(cliEnvironment["ANTHROPIC_BASE_URL"])
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.connectionProxyDictionary = [:]
        let modelSession = URLSession(configuration: sessionConfiguration)
        defer { modelSession.invalidateAndCancel() }
        func catalog() async throws -> [AvailableModel] {
            try await AgentModelCatalogService.fetchAvailableModels(proxyURL: gateway.url + "/v1", apiKey: "fixture-only-key",
                session: modelSession, fetchCopilotModelIDs: { [] })
        }
        func object() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        }
        func options(_ document: [String: Any]) throws -> [[String: Any]] {
            try XCTUnwrap((document["modelPicker"] as? [String: Any])?["options"] as? [[String: Any]])
        }
        func menuIDs(_ document: [String: Any]) throws -> Set<String> {
            Set(try options(document).compactMap { $0["model"] as? String })
        }
        // 未知根字段与未知菜单字段均先交给生产生成器合并；不能把 CLI 自己剥离的字段归咎于应用保存。
        let original: [String: Any] = ["futureRoot": ["keep": "root-value"], "env": ["FIXTURE_UNKNOWN_ENV": "keep-env"],
            "modelPicker": ["futureNested": ["keep": "nested-value"], "options": []]]
        let originalData = try JSONSerialization.data(withJSONObject: original, options: [.prettyPrinted, .sortedKeys])
        try originalData.write(to: settings)
        let service = AgentConfigurationService(homeDirectory: root, claudeConfigDirectory: directory, environment: [:])
        var config = AgentConfiguration(agent: .claudeCode, proxyURL: gateway.url + "/v1", apiKey: "fixture-only-key")
        config.claudeCatalogManaged = true
        config.modelSlots = [.opus: "fixture-live-one", .sonnet: "fixture-live-two", .haiku: "fixture-live-one"]
        config.claudeDefaultModel = "opus"
        let initialCatalog = try await catalog()
        XCTAssertEqual(Set(initialCatalog.map(\.id)), initialIDs)
        let applied = try await service.generateConfiguration(agent: .claudeCode, config: config, mode: .automatic,
            detectionService: AgentDetectionService(), availableModels: initialCatalog)
        XCTAssertTrue(applied.success, applied.error ?? "生产配置应用失败")
        let firstDocument = try object()
        XCTAssertEqual(firstDocument["model"] as? String, "opus")
        XCTAssertEqual(firstDocument["futureRoot"] as? NSDictionary, ["keep": "root-value"])
        XCTAssertEqual((firstDocument["env"] as? [String: Any])?["FIXTURE_UNKNOWN_ENV"] as? String, "keep-env")
        // 新进程只从生产写出的用户文件取得连接；额外环境不能掩盖 endpoint／认证缺失或写错。
        let appliedEnvironment = try XCTUnwrap(firstDocument["env"] as? [String: Any])
        XCTAssertEqual(appliedEnvironment["ANTHROPIC_BASE_URL"] as? String, gateway.url)
        XCTAssertEqual(appliedEnvironment["ANTHROPIC_AUTH_TOKEN"] as? String, "fixture-only-key")
        XCTAssertNil(appliedEnvironment["ANTHROPIC_MODEL"], "/model 保存必须能成为新会话默认，不能被旧强制变量钉住")
        XCTAssertEqual((firstDocument["modelPicker"] as? [String: Any])?["futureNested"] as? NSDictionary,
                       ["keep": "nested-value"], "应用自身写入必须保留未知嵌套字段")
        let ownership = try XCTUnwrap(firstDocument["quotioClaudeCatalog"] as? [String: Any])
        XCTAssertEqual(ownership["managed"] as? Bool, true)
        XCTAssertEqual(ownership["version"] as? Int, 1)
        let source = ClaudeConfigurationPlan.sourceID(url: config.proxyURL, key: config.apiKey)
        XCTAssertEqual(ownership["source"] as? String, source)
        let backups = await service.listBackups(agent: .claudeCode)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(backups.first).path)), originalData)
        // 自定义 CLAUDE_CONFIG_DIR 是唯一设置位置，不能额外落一份默认 ~/.claude/settings.json。
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude/settings.json").path))

        // 第一次必须由真正的 /model 命令从 Opus 切换为 Sonnet，并收到“已保存为后续默认”的 CLI 回执。
        // 不通过 --model 参数、不手工删除 futureNested，也不伪造 CLI 重写后的 JSON。
        let firstCLI = try ClaudeInteractiveWorkflowSession(root: root, directory: directory, gatewayURL: gateway.url)
        defer { firstCLI.stop() }
        do { try firstCLI.saveDefaultModel("sonnet") }
        catch { attach(firstCLI.text, name: "首次交互式 CLI 失败输出"); throw error }
        XCTAssertTrue(firstCLI.savedByInteractiveCommand)
        let cliDocument = try object()
        XCTAssertEqual(cliDocument["model"] as? String, "sonnet")
        XCTAssertNil((cliDocument["modelPicker"] as? [String: Any])?["futureNested"],
                     "本机 CLI 的正常保存应实际覆盖 modelPicker 的 schema 外字段；否则没有复现本轮关键边界")
        XCTAssertEqual(cliDocument["futureRoot"] as? NSDictionary, ["keep": "root-value"])
        XCTAssertEqual(cliDocument["quotioClaudeCatalog"] as? NSDictionary, ownership as NSDictionary,
                       "归属信息必须位于 CLI 会保留的根扩展，不能依赖已被 CLI 删除的菜单扩展")
        let loaded = await service.readConfiguration(agent: .claudeCode)
        XCTAssertEqual(loaded?.defaultModel, "sonnet")
        XCTAssertEqual(loaded?.claudeModelPicker.isQuotioManaged, true)
        let managed = await service.managedClaudeConfiguration(serviceBaseURLs: [gateway.url])
        XCTAssertNotNil(managed, "真实 CLI 保存后仍必须识别为当前后端的受管配置")
        XCTAssertEqual(managed?.claudeDefaultModel, "sonnet")

        // 经过正常 CLI 写入后，账号目录变化仍走生产后台同步入口，不能因嵌套管理标记丢失而静默跳过。
        gateway.replaceAcceptedModels(changedIDs)
        let nextCatalog = try await catalog()
        XCTAssertEqual(Set(nextCatalog.map(\.id)), changedIDs)
        let synchronized = await service.synchronizeManagedClaudeCatalog(sourceID: source,
            serviceBaseURLs: [gateway.url], models: nextCatalog)
        XCTAssertEqual(synchronized?.success, true, synchronized?.error ?? "账号目录同步不应被跳过")
        let synchronizedDocument = try object(), synchronizedIDs = try menuIDs(synchronizedDocument)
        XCTAssertFalse(synchronizedIDs.contains("fixture-disabled-account"))
        XCTAssertTrue(synchronizedIDs.contains("fixture-new-account"))
        XCTAssertEqual(synchronizedDocument["model"] as? String, "sonnet", "同步不能覆盖 CLI 刚保存的启动选择")
        XCTAssertEqual(synchronizedDocument["futureRoot"] as? NSDictionary, ["keep": "root-value"])
        XCTAssertEqual((synchronizedDocument["env"] as? [String: Any])?["FIXTURE_UNKNOWN_ENV"] as? String, "keep-env")

        let beforeSavedDefault = gateway.requests.count
        let savedOutput = try ClaudeInteractiveWorkflowSession.runSavedDefault(root: root, directory: directory, gatewayURL: gateway.url)
        XCTAssertEqual(savedOutput.status, 0, String(savedOutput.text.suffix(2000)))
        let savedRequests = Array(gateway.requests.dropFirst(beforeSavedDefault))
        XCTAssertFalse(savedRequests.isEmpty, "必须实际向本地网关发送 Sonnet 保存后的默认请求")
        XCTAssertTrue(savedRequests.allSatisfy { $0.model == "fixture-live-two" && $0.usesFixtureKey },
                      "\(savedRequests.map(\.model))")

        // 新账号新增的具体菜单项还要经过第二次真实 /model 保存并在新 CLI 中请求成功。
        // 这覆盖自定义模型验证与 CLI 再次重写，避免只验证固定角色在第一页可用。
        let secondCLI = try ClaudeInteractiveWorkflowSession(root: root, directory: directory, gatewayURL: gateway.url)
        defer { secondCLI.stop() }
        do { try secondCLI.saveDefaultModel("fixture-new-account") }
        catch { attach(secondCLI.text, name: "账号同步后交互式 CLI 失败输出"); throw error }
        XCTAssertEqual(try object()["model"] as? String, "fixture-new-account")
        let beforeNewModel = gateway.requests.count
        let newOutput = try ClaudeInteractiveWorkflowSession.runSavedDefault(root: root, directory: directory, gatewayURL: gateway.url)
        XCTAssertEqual(newOutput.status, 0, String(newOutput.text.suffix(2000)))
        let newRequests = Array(gateway.requests.dropFirst(beforeNewModel))
        XCTAssertFalse(newRequests.isEmpty)
        XCTAssertTrue(newRequests.allSatisfy { $0.model == "fixture-new-account" && $0.usesFixtureKey })
        let lastManaged = await service.managedClaudeConfiguration(serviceBaseURLs: [gateway.url])
        XCTAssertNotNil(lastManaged, "第二次 CLI 保存后也不能再次丢失管理归属")
        XCTAssertEqual(lastManaged?.claudeDefaultModel, "fixture-new-account")
        attach(firstCLI.text + "\n--- 账号目录同步后 ---\n" + secondCLI.text, name: "两次真实交互式 model 保存回执")
        attach(gateway.requests.map { "model=\($0.model) fixtureKey=\($0.usesFixtureKey)" }.joined(separator: "\n"),
               name: "配置应用与账号同步完整流程实际请求")
    }

    private func attach(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
