import Foundation
import CryptoKit
import Yams
import XCTest
@testable import QuotioPlus

/// 验证协议选择及同一 v8 PATCH 的迁移语义，不读取真实账号、偏好或密钥。
@MainActor
final class OpenAIProtocolRoutingTests: XCTestCase {
    private func provider(url: String = "https://api.openai.com/v1", mode: CustomProviderAPIProtocol = .automatic) -> CustomProvider {
        CustomProvider(name: "Official fixture", type: .openaiCompatibility, baseURL: url,
            apiKeys: [.init(apiKey: "fixture-upstream", weight: 3)],
            models: [.init(name: "gpt-6.1-sol", alias: "fixture-route")], apiProtocol: mode)
    }
    private func patch(_ yaml: String, provider: CustomProvider, legacy: Bool = false) throws -> [String: Any] {
        try XCTUnwrap(fullPatch(yaml, provider: provider, legacy: legacy)["api-keys"] as? [String: Any])
    }
    private func fullPatch(_ yaml: String, provider: CustomProvider, legacy: Bool = false,
                           previous: [UUID: CustomProviderService.V8SyncedFields] = [:]) throws -> [String: Any] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        // 业务错误先直接传播，供拒绝迁移的测试断言；不能交给 XCTUnwrap 的自动闭包记成意外失败。
        let optionalData = try CustomProviderService.shared.makeV8ProviderPatch(configPath: file.path,
            managedProviders: [provider], previouslySynced: previous, legacyOwnedProviderIDs: legacy ? [provider.id] : [])
        let data = try XCTUnwrap(optionalData)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), yaml)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private var empty: String { "config-version: 8\nserver: {port: 8317}\nmanagement: {secret-key: fixture}\napi-keys: {}\n" }

    func testOfficialEndpointIsExactAndLegacyChatCanBeSelectedExplicitly() throws {
        for url in ["https://api.openai.com", "https://API.OPENAI.COM:443/v1/"] {
            let p = provider(url: url)
            XCTAssertTrue(p.usesResponsesAPI)
            let result = try patch(empty, provider: p)
            let groups = try XCTUnwrap(result["codex"] as? [[String: Any]])
            XCTAssertEqual(groups.first?["base-url"] as? String, "https://api.openai.com/v1")
        }
        for url in ["https://api.openai.com.evil.invalid/v1", "http://api.openai.com/v1", "https://api.openai.com:8443/v1",
                    "https://api.openai.com/third-party/v1", "https://api.openai.com/v1?route=x", "https://user@api.openai.com/v1",
                    "https://third-party.invalid/v1"] { XCTAssertFalse(provider(url: url).usesResponsesAPI, url) }
        let chat = provider(mode: .chatCompletions)
        XCTAssertFalse(chat.usesResponsesAPI)
        XCTAssertNotNil(try patch(empty, provider: chat)["openai-compatibility"])
        XCTAssertTrue(provider(url: "http://127.0.0.1:1234/v1", mode: .responses).usesResponsesAPI)
    }

    func testProtocolRoundTripAndMissingOldFieldKeepIDsAndKeys() throws {
        let original = provider(mode: .chatCompletions)
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(CustomProvider.self, from: encoded), original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "api-protocol")
        let old = try JSONDecoder().decode(CustomProvider.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.apiProtocol, .automatic)
        XCTAssertEqual(old.id, original.id)
        XCTAssertEqual(old.apiKeys, original.apiKeys)
        object["api-protocol"] = "future-unknown"
        XCTAssertThrowsError(try JSONDecoder().decode(CustomProvider.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testReversePendingMigrationReadsDiskWeightAndRejectsAmbiguousOwners() throws {
        let p = provider(url: "https://third-party.invalid/v1", mode: .chatCompletions)
        let group = """
            - name: "Official fixture (Quotio \(p.id.uuidString))"
              keys: [{api-key: fixture-upstream, weight: 17}]
        """
        let yaml = empty.replacingOccurrences(of: "api-keys: {}", with: "api-keys:\n  codex:\n" + group)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".yaml")
        defer { try? FileManager.default.removeItem(at: file) }
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(CustomProviderService.shared.routingWeights(for: p, configPath: file.path)[p.apiKeys[0].id], 17)
        try (yaml + "\n  openai-compatibility:\n" + group).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(CustomProviderService.shared.routingWeights(for: p, configPath: file.path).isEmpty)
        XCTAssertEqual(p.apiKeys[0].weight, 3, "只读观察不能覆盖原本地草稿")
    }

    func testExplicitThirdPartyResponsesAndTypeSwitchKeepAdvancedFields() throws {
        var p = provider(url: "https://third-party.invalid/deployment/v1", mode: .responses)
        let yaml = empty.replacingOccurrences(of: "api-keys: {}", with: """
        api-keys:
          openai-compatibility:
            - name: "Official fixture (Quotio \(p.id.uuidString))"
              base-url: https://third-party.invalid/deployment/v1
              future-option: {keep: true}
              headers: {X-External: keep}
              models: [{name: gpt-6.1-sol, alias: fixture-route, display-name: Keep}]
              keys: [{api-key: fixture-upstream, priority: 9}]
        """)
        for type in [CustomProviderType.openaiCompatibility, .codexCompatibility] {
            p.type = type
            let groups = try XCTUnwrap(try patch(yaml, provider: p)["codex"] as? [[String: Any]])
            XCTAssertEqual(groups.first?["base-url"] as? String, p.baseURL)
            XCTAssertEqual(groups.first?["future-option"] as? NSDictionary, ["keep": true])
            XCTAssertEqual((groups.first?["models"] as? [[String: Any]])?.first?["display-name"] as? String, "Keep")
            XCTAssertEqual((groups.first?["keys"] as? [[String: Any]])?.first?["priority"] as? Int, 9)
        }
        p.type = .openaiCompatibility; p.apiProtocol = .automatic
        XCTAssertNil(try patch(yaml, provider: p)["codex"], "第三方自动模式不能转入 Responses")
    }

    /// 完整配置夹具故意混入共享规则与未知字段，验证同一 PATCH 仅追加目标协议投影。
    private func aliasConfig(_ p: CustomProvider, extra: String = "") -> String {
        """
        config-version: 8
        server: {port: 8317}
        management: {secret-key: fixture}
        api-keys:
          openai-compatibility:
            - name: "Official fixture (Quotio \(p.id.uuidString))"
              base-url: \(p.baseURL)
              models: [{name: gpt-6.1-sol, alias: fixture-route}]
              keys: [{api-key: fixture-upstream}, {api-key: manual-fixture}]
        \(extra)
        requests:
          future-option: keep
          payload:
            default: [{models: [{name: unrelated}], params: {future: keep}}]
            override:
              - models: [{name: fixture-route, protocol: openai}, {name: shared-other, protocol: openai}]
                params: {reasoning_effort: high}
              - models: [{name: fixture-route, protocol: openai}]
                params: {reasoning_effort: xhigh}
              - models: [{name: unrelated, protocol: codex}]
                params: {future-field: keep}
                future-rule: keep
        """
    }

    func testEffortRulesMigrateInSamePatchPreserveSourceAndReverseIdempotently() throws {
        var p = provider(url: "https://third-party.invalid/v1", mode: .responses)
        let yaml = aliasConfig(p)
        let generated = try fullPatch(yaml, provider: p)
        let requests = try XCTUnwrap(generated["requests"] as? [String: Any])
        let payload = try XCTUnwrap(requests["payload"] as? [String: Any])
        let rules = try XCTUnwrap(payload["override"] as? [[String: Any]])
        let old = try XCTUnwrap(try Yams.load(yaml: yaml) as? [String: Any])
        let oldRequests = old["requests"] as! [String: Any]
        let oldPayload = oldRequests["payload"] as! [String: Any]
        XCTAssertEqual(Array(rules.prefix(3)) as NSArray, oldPayload["override"] as? NSArray)
        XCTAssertEqual(rules.count, 4)
        XCTAssertEqual(rules.last?["params"] as? NSDictionary, ["reasoning.effort": "xhigh"])
        XCTAssertNil(requests["future-option"], "局部 PATCH 不重复写入其它设置")
        XCTAssertNil(payload["default"], "其它 payload 策略保留在 CPA 原配置中")
        // 将同一个 PATCH 递归合并成磁盘样本，再逆向迁移；等价源规则不重复追加。
        var next = old
        next["api-keys"] = generated["api-keys"]
        var nextPayload = oldPayload; nextPayload["override"] = rules
        var nextRequests = oldRequests; nextRequests["payload"] = nextPayload
        next["requests"] = nextRequests
        p.apiProtocol = .chatCompletions
        let reversed = try fullPatch(try Yams.dump(object: next), provider: p)
        XCTAssertNil(reversed["requests"])
        XCTAssertEqual(nextRequests["future-option"] as? String, "keep")
    }

    func testEffortMigrationRejectsSharedTargetAndConflictingOrConditionalPolicies() throws {
        let p = provider()
        let shared = """
          codex:
            - name: Manual
              keys: [{api-key: manual-target}]
              models: [{name: other-model, alias: fixture-route}]
        """
        XCTAssertThrowsError(try fullPatch(aliasConfig(p, extra: shared), provider: p))
        let yaml = aliasConfig(p)
        for rule in [
            "\n      - models: [{name: fixture-route, protocol: codex}]\n        params: {reasoning.effort: low}",
            "\n      - models: [{name: 'fixture-*', protocol: codex}]\n        params: {reasoning.effort: xhigh}",
            "\n      - models: [{name: fixture-route, protocol: ''}]\n        params: {reasoning.effort: low}",
            "\n      - models: [{name: ' fixture-route ', protocol: '  '}]\n        params: {reasoning.effort: low}",
            "\n      - models: [{name: fixture-route, protocol: codex, headers: {X-Tier: premium}}]\n        params: {reasoning.effort: xhigh}"
        ] { XCTAssertThrowsError(try fullPatch(yaml + rule + "\n", provider: p)) }
        let equivalent = yaml + "\n      - models: [{name: fixture-route, protocol: codex}]\n        params: {reasoning.effort: xhigh}\n"
        XCTAssertNil(try fullPatch(equivalent, provider: p)["requests"])
    }

    func testEffortMigrationChecksRawFilterAndParentObjectOnBothSides() throws {
        let p = provider()
        let equivalent = "\n      - models: [{name: fixture-route, protocol: codex}]\n        params: {reasoning.effort: xhigh}\n"
        for proto in ["openai", "codex"] {
            for complex in [
                "\n    filter:\n      - models: [{name: fixture-route, protocol: \(proto)}]\n        params: [reasoning]",
                "\n    override-raw:\n      - models: [{name: fixture-route, protocol: \(proto)}]\n        params: {reasoning: '{\"effort\":\"low\"}'}"
            ] { XCTAssertThrowsError(try fullPatch(aliasConfig(p) + equivalent + complex + "\n", provider: p)) }
        }
        let parent = "\n      - models: [{name: fixture-route, protocol: openai}]\n        params: {reasoning: {effort: low}}\n"
        XCTAssertThrowsError(try fullPatch(aliasConfig(p) + parent, provider: p))
    }

    func testEffortMigrationProtectsUpstreamNamesPerKeyOverridesAndSameProtocolFamilies() throws {
        let p = provider()
        let upstreamPolicy = "\n      - models: [{name: gpt-6.1-sol, protocol: openai}]\n        params: {reasoning_effort: low}\n"
        XCTAssertThrowsError(try fullPatch(aliasConfig(p) + upstreamPolicy, provider: p))
        for extra in [
            "  codex:\n    - name: Manual\n      keys: [{api-key: target}]\n      models: [{name: fixture-route, alias: manual-other}]",
            "  codex:\n    - name: Manual\n      keys: [{api-key: target, models: [{name: fixture-route, alias: manual-other}]}]",
            "  xai:\n    - name: Manual\n      keys: [{api-key: target}]\n      models: [{name: fixture-route, alias: manual-other}]"
        ] { XCTAssertThrowsError(try fullPatch(aliasConfig(p, extra: extra), provider: p)) }
    }

    func testProtocolSwitchDoesNotProjectRemovedOrRenamedAliases() throws {
        var p = provider()
        let oldModel = p.models[0]
        let previous = [p.id: CustomProviderService.V8SyncedFields(id: p.id,
            models: [.init(id: oldModel.id, name: oldModel.name, alias: oldModel.alias)], headerNames: [])]
        let yaml = aliasConfig(p)
        p.models = []
        XCTAssertNil(try fullPatch(yaml, provider: p, previous: previous)["requests"])
        p.models = [oldModel]; p.models[0].alias = "new-alias"
        XCTAssertNil(try fullPatch(yaml, provider: p, previous: previous)["requests"])
    }

    func testOwnedKeyModelOverrideKeepsAliasEffortAndUnknownFields() throws {
        let p = provider()
        let yaml = aliasConfig(p)
            .replacingOccurrences(of: "{api-key: fixture-upstream}", with:
                "{api-key: fixture-upstream, future-key: keep, models: [{name: per-key-model, alias: per-key-alias}]}")
            + "\n      - models: [{name: per-key-alias, protocol: openai}]\n        params: {reasoning_effort: high}\n"
        let generated = try fullPatch(yaml, provider: p)
        let requests = generated["requests"] as? [String: Any]
        let payload = requests?["payload"] as? [String: Any]
        let rules = try XCTUnwrap(payload?["override"] as? [[String: Any]])
        XCTAssertTrue(rules.contains { rule in
            (rule["params"] as? [String: String])?["reasoning.effort"] == "high"
                && ((rule["models"] as? [[String: String]])?.first?["name"] == "per-key-alias")
        })
        let families = generated["api-keys"] as? [String: Any]
        let group = (families?["codex"] as? [[String: Any]])?.first
        let key = (group?["keys"] as? [[String: Any]])?.first
        XCTAssertEqual(key?["future-key"] as? String, "keep")
        XCTAssertEqual((key?["models"] as? [[String: String]])?.first?["alias"], "per-key-alias")
    }

    func testFamilyRoundTripIsIdempotentAndDisableOrDeleteOnlyRemovesOwnedKey() throws {
        var p = provider()
        p.apiKeys[0].weight = nil
        p.apiKeys[0].proxyURL = "direct"
        let group: [String: Any] = ["name": "Official fixture (Quotio \(p.id.uuidString))",
            "base-url": "https://api.openai.com/v1", "priority": 9, "future-option": ["keep": true],
            "keys": [["api-key": "fixture-upstream", "weight": 7, "proxy-url": "direct"], ["api-key": "manual-fixture"]],
            "models": [["name": "gpt-6.1-sol", "alias": "fixture-route", "display-name": "Keep Name"]]]
        var root: [String: Any] = ["config-version": 8, "server": ["port": 8317], "management": ["secret-key": "fixture"],
            "api-keys": ["openai-compatibility": [group]]]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        func save() throws { try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: file) }
        for mode in [CustomProviderAPIProtocol.automatic, .chatCompletions, .responses] {
            p.apiProtocol = mode
            try save()
            let data = try XCTUnwrap(CustomProviderService.shared.makeV8ProviderPatch(configPath: file.path, managedProviders: [p]))
            let patch = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["api-keys"] as? [String: Any])
            var families = root["api-keys"] as! [String: Any]
            families.merge(patch) { _, new in new }; root["api-keys"] = families
            let target = mode == .chatCompletions ? "openai-compatibility" : "codex"
            let group = try XCTUnwrap((families[target] as? [[String: Any]])?.first { ($0["name"] as? String)?.contains(p.id.uuidString) == true })
            XCTAssertEqual(group["priority"] as? Int, 9)
            XCTAssertEqual(group["future-option"] as? NSDictionary, ["keep": true])
            XCTAssertEqual((group["keys"] as? [[String: Any]])?.first?["weight"] as? Int, 7)
            XCTAssertEqual((group["keys"] as? [[String: Any]])?.first?["proxy-url"] as? String, "direct")
            XCTAssertEqual((group["models"] as? [[String: Any]])?.first?["display-name"] as? String, "Keep Name")
            try save()
            XCTAssertNil(try CustomProviderService.shared.makeV8ProviderPatch(configPath: file.path, managedProviders: [p]))
        }
        let digest = SHA256.hash(data: Data("fixture-upstream".utf8)).map { String(format: "%02x", $0) }.joined()
        let previous = [p.id: CustomProviderService.V8SyncedFields(id: p.id, models: [], headerNames: [], keyDigests: [digest])]
        for deleting in [false, true] {
            p.isEnabled = false
            let data = try XCTUnwrap(CustomProviderService.shared.makeV8ProviderPatch(configPath: file.path,
                managedProviders: deleting ? [] : [p], previouslySynced: previous))
            let families = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["api-keys"] as? [String: Any])
            XCTAssertEqual((families["codex"] as? [[String: Any]])?.count, 0)
            XCTAssertNil(families["openai-compatibility"], "旧族中保留的手工 key 不应受停用或删除影响")
        }
    }

    func testAtomicMigrationKeepsModelAdvancedFieldsWeightsAndUnmanagedKeys() throws {
        let p = provider()
        let yaml = """
        config-version: 8
        server: {port: 8317}
        management: {secret-key: fixture}
        api-keys:
          openai-compatibility:
            - name: "Official fixture (Quotio \(p.id.uuidString))"
              base-url: https://api.openai.com/v1
              priority: 9
              headers: {X-External: keep}
              models: [{name: gpt-6.1-sol, alias: fixture-route, display-name: Keep Name}]
              keys:
                - {api-key: fixture-upstream, weight: 7, priority: 4, proxy-url: direct}
                - {api-key: unmanaged-fixture, weight: 6}
        """
        let result = try patch(yaml, provider: p)
        let source = try XCTUnwrap((result["openai-compatibility"] as? [[String: Any]])?.first)
        XCTAssertEqual((source["keys"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((source["keys"] as? [[String: Any]])?.first?["api-key"] as? String, "unmanaged-fixture")
        let target = try XCTUnwrap((result["codex"] as? [[String: Any]])?.first)
        XCTAssertEqual(target["priority"] as? Int, 9)
        XCTAssertEqual((target["headers"] as? [String: String])?["X-External"], "keep")
        XCTAssertEqual((target["models"] as? [[String: Any]])?.first?["display-name"] as? String, "Keep Name")
        let keys = try XCTUnwrap(target["keys"] as? [[String: Any]])
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0]["priority"] as? Int, 4)
        XCTAssertFalse(keys.contains { $0["api-key"] as? String == "unmanaged-fixture" })
    }

    func testExplicitLegacyOwnershipMovesOnceAndUnmarkedManualGroupIsUntouched() throws {
        let p = provider()
        let yaml = """
        config-version: 8
        server: {port: 8317}
        management: {secret-key: fixture}
        api-keys:
          openai-compatibility:
            - name: Official fixture
              keys: [{api-key: fixture-upstream}]
              base-url: https://api.openai.com/v1
        """
        let owned = try patch(yaml, provider: p, legacy: true)
        XCTAssertEqual((owned["openai-compatibility"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((owned["codex"] as? [[String: Any]])?.count, 1)
        let manual = try patch(yaml, provider: p)
        XCTAssertNil(manual["openai-compatibility"], "没有归属证明的原组不能被删除或改写")
        let withManualTarget = yaml + "\n  codex:\n    - name: Manual Target\n      priority: 99\n      keys: [{api-key: fixture-upstream}]\n"
        let moved = try patch(withManualTarget, provider: p, legacy: true)
        let targets = try XCTUnwrap(moved["codex"] as? [[String: Any]])
        XCTAssertEqual(targets.count, 2, "跨族旧归属证明不能用于认领目标族的手工同密钥组")
        XCTAssertEqual(targets[0]["name"] as? String, "Manual Target")
        XCTAssertEqual(targets[0]["priority"] as? Int, 99)
    }

    private func runtimeProbe(_ data: Data) throws -> [String: Any] {
        let binary = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Quotio/proxy/upstream/v8.0.47/CLIProxyAPI")
        guard FileManager.default.isExecutableFile(atPath: binary.path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw XCTSkip("需要本机 CPA 8.0.47 和 loopback 隔离工具才能验证真实转换")
        }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Support/CPA/openai_protocol_gateway.py")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try data.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let process = Process(), pipe = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [fixture.path, binary.path, path.path]
        process.standardOutput = pipe; process.standardError = errors
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let error = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, error)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
    }

    func testGeneratedProtocolReachesResponsesWithRealCPAForBothStreamingModes() throws {
        let p = provider()
        let yaml = aliasConfig(p).replacingOccurrences(of: ", {api-key: manual-fixture}", with: "")
        let data = try JSONSerialization.data(withJSONObject: fullPatch(yaml, provider: p))
        let object = try runtimeProbe(data)
        let results = try XCTUnwrap(object["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 6)
        XCTAssertTrue(results.allSatisfy { $0["status"] as? Int == 200 && $0["content_ok"] as? Bool == true })
        let requests = try XCTUnwrap(object["requests"] as? [[String: Any]])
        XCTAssertEqual(requests.count, 6)
        for request in requests {
            XCTAssertEqual(request["path"] as? String, "/v1/responses")
            XCTAssertEqual(request["model"] as? String, "gpt-6.1-sol")
            XCTAssertEqual(request["uses_fixture_key"] as? Bool, true)
            XCTAssertEqual(request["has_legacy_limit"] as? Bool, false)
            XCTAssertEqual((request["reasoning"] as? [String: String])?["effort"], "xhigh")
            XCTAssertTrue((request["tools"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == "fixture_tool" })
            XCTAssertEqual((request["tool_choice"] as? [String: String])?["name"], "fixture_tool")
            XCTAssertEqual(request["parallel_tool_calls"] as? Bool, false)
        }
        // 本轮明确等待官方修复内核。仅记录实测能力，不把固定默认值伪装成原样透传，
        // 也不写一个永远要求预算丢失的断言；未来官方修复后此夹具仍可验证其它转换契约。
        print("CPA output budget observations (messages/chat/responses):", requests.map { $0["max_output_tokens"] ?? NSNull() })
    }

    func testThirdPartyAutomaticChatKeepsDeploymentPrefixAndOutputBudgetsWithRealCPA() throws {
        let p = provider(url: "https://third-party.invalid/deployment/v1")
        let data = try JSONSerialization.data(withJSONObject: fullPatch(empty, provider: p))
        let object = try runtimeProbe(data)
        let results = try XCTUnwrap(object["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 4)
        XCTAssertTrue(results.allSatisfy { $0["status"] as? Int == 200 && $0["content_ok"] as? Bool == true })
        let requests = try XCTUnwrap(object["requests"] as? [[String: Any]])
        XCTAssertEqual(requests.count, 4)
        for (index, request) in requests.enumerated() {
            XCTAssertEqual(request["path"] as? String, "/deployment/v1/chat/completions")
            XCTAssertEqual(request["uses_fixture_key"] as? Bool, true)
            XCTAssertEqual(request["model"] as? String, "gpt-6.1-sol")
            let budget = (request["max_completion_tokens"] as? Int) ?? (request["max_tokens"] as? Int)
            XCTAssertEqual(budget, index < 2 ? 65536 : 1234)
        }
    }
}
