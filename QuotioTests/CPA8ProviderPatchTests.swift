import Foundation
import CryptoKit
import XCTest
@testable import QuotioPlus

@MainActor
final class CPA8ProviderPatchTests: XCTestCase {
    func testAdoptingLegacyGroupKeepsUnknownSettingsAndOtherProviders() throws {
        let provider = CustomProvider(
            name: "Private Claude", type: .claudeCompatibility,
            apiKeys: [CustomAPIKeyEntry(apiKey: "fake-secret")],
            models: [ModelMapping(name: "model-a", alias: "new-alias")]
        )
        let yaml = """
        # 用户希望保留的注释
        config-version: 8
        server:
          port: 8317
        management:
          secret-key: "fake-management"
        access:
          api-keys: ["fake-client"]
        api-keys:
          claude:
            - name: Private Claude
              priority: 7
              keys:
                - api-key: fake-secret
                  weight: 5
              models:
                - name: model-a
                  alias: old-alias
                  display-name: My Model
                - name: manually-added
                  alias: manual-alias
            - name: Unmanaged Claude
              keys:
                - api-key: other-secret

        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cpa-v8-provider-\(UUID().uuidString).yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let patch = try XCTUnwrap(CustomProviderService.shared.makeV8ProviderPatch(
            configPath: file.path, managedProviders: [provider],
            legacyOwnedProviderIDs: [provider.id]
        ))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: patch) as? [String: Any])
        let families = try XCTUnwrap(root["api-keys"] as? [String: Any])
        let groups = try XCTUnwrap(families["claude"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 2)
        let adopted = groups[0]
        XCTAssertEqual(adopted["priority"] as? Int, 7)
        XCTAssertEqual((adopted["keys"] as? [[String: Any]])?.first?["weight"] as? Int, 5)
        let models = try XCTUnwrap(adopted["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0]["alias"] as? String, "new-alias")
        XCTAssertEqual(models[0]["display-name"] as? String, "My Model")
        XCTAssertEqual(models[1]["alias"] as? String, "manual-alias")
        XCTAssertEqual(groups[1]["name"] as? String, "Unmanaged Claude")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), yaml)
    }

    func testUnmarkedManualGroupIsNeverClaimedByNameAndKeyAlone() throws {
        let provider = CustomProvider(name: "Private Claude", type: .claudeCompatibility,
                                      apiKeys: [CustomAPIKeyEntry(apiKey: "fake-secret")])
        let yaml = """
        config-version: 8
        server: {port: 8317}
        management: {secret-key: test}
        api-keys:
          claude:
            - name: Private Claude
              priority: 9
              keys: [{api-key: fake-secret}]

        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cpa-v8-unowned-\(UUID().uuidString).yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let patch = try XCTUnwrap(CustomProviderService.shared.makeV8ProviderPatch(
            configPath: file.path, managedProviders: [provider]
        ))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: patch) as? [String: Any])
        let families = try XCTUnwrap(root["api-keys"] as? [String: Any])
        let groups = try XCTUnwrap(families["claude"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0]["name"] as? String, "Private Claude")
        XCTAssertEqual(groups[0]["priority"] as? Int, 9)
        XCTAssertTrue((groups[1]["name"] as? String ?? "").contains("Quotio \(provider.id.uuidString)"))
    }

    func testClearingManagedFieldsKeepsManualAliasesAndHeaders() throws {
        let modelID = UUID()
        let provider = CustomProvider(name: "Private Claude", type: .claudeCompatibility,
                                      prefix: nil, apiKeys: [CustomAPIKeyEntry(apiKey: "fake-secret")],
                                      models: [], headers: [])
        let snapshot = CustomProviderService.V8SyncedFields(
            id: provider.id,
            models: [.init(id: modelID, name: "same-upstream", alias: "managed-alias")],
            headerNames: ["X-Managed"]
        )
        let yaml = """
        config-version: 8
        server: {port: 8317}
        management: {secret-key: test}
        api-keys:
          claude:
            - name: Private Claude (Quotio \(provider.id.uuidString))
              prefix: old-prefix
              keys:
                - api-key: fake-secret
                  proxy-url: http://old-proxy
                  weight: 5
              models:
                - {name: same-upstream, alias: managed-alias}
                - {name: same-upstream, alias: manual-alias}
              headers: {X-Managed: old-value, X-Manual: keep-me}

        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cpa-v8-clear-\(UUID().uuidString).yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let patch = try XCTUnwrap(CustomProviderService.shared.makeV8ProviderPatch(
            configPath: file.path, managedProviders: [provider], previouslySynced: [provider.id: snapshot]
        ))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: patch) as? [String: Any])
        let families = try XCTUnwrap(root["api-keys"] as? [String: Any])
        let groups = try XCTUnwrap(families["claude"] as? [[String: Any]])
        let group = try XCTUnwrap(groups.first)
        XCTAssertNil(group["prefix"])
        let key = try XCTUnwrap((group["keys"] as? [[String: Any]])?.first)
        XCTAssertNil(key["proxy-url"])
        XCTAssertEqual(key["weight"] as? Int, 5)
        let models = try XCTUnwrap(group["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0]["alias"] as? String, "manual-alias")
        XCTAssertEqual(group["headers"] as? [String: String], ["X-Manual": "keep-me"])
    }

    func testLegacyOwnershipRequiresQuotioMarkerBlock() {
        let provider = CustomProvider(name: "Private OpenAI", type: .openaiCompatibility,
                                      baseURL: "https://example.invalid/v1",
                                      apiKeys: [CustomAPIKeyEntry(apiKey: "fake-secret")])
        let oldGroup = """
        openai-compatibility:
          - name: Private OpenAI
            base-url: https://example.invalid/v1
            api-key-entries:
              - api-key: fake-secret

        """
        let service = CustomProviderService.shared
        XCTAssertTrue(service.legacyOwnedProviderIDs(in: oldGroup, managedProviders: [provider]).isEmpty)
        let generated = "port: 8317\n# Custom Providers (managed by Quotio)\n" + oldGroup
        XCTAssertEqual(service.legacyOwnedProviderIDs(in: generated, managedProviders: [provider]), [provider.id])
    }

    func testUnknownMarkedGroupSurvivesLostLocalStorage() throws {
        let id = UUID()
        let yaml = """
        config-version: 8
        server: {port: 8317}
        management: {secret-key: test}
        api-keys:
          claude:
            - name: Old Account (Quotio \(id.uuidString))
              keys: [{api-key: fake-secret}]

        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cpa-v8-unknown-\(UUID().uuidString).yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let service = CustomProviderService.shared
        XCTAssertNil(try service.makeV8ProviderPatch(configPath: file.path, managedProviders: []))
        // 历史快照没有密钥摘要时，原样保留该组，但不能因此阻断整个代理启动。
        let legacySnapshot = CustomProviderService.V8SyncedFields(id: id, models: [], headerNames: [])
        XCTAssertNil(try service.makeV8ProviderPatch(
            configPath: file.path, managedProviders: [], previouslySynced: [id: legacySnapshot]
        ))
        let known = CustomProviderService.V8SyncedFields(
            id: id, models: [], headerNames: [], keyDigests: [digest("fake-secret")]
        )
        let deletion = try XCTUnwrap(service.makeV8ProviderPatch(
            configPath: file.path, managedProviders: [], previouslySynced: [id: known]
        ))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: deletion) as? [String: Any])
        let families = try XCTUnwrap(root["api-keys"] as? [String: Any])
        XCTAssertEqual((families["claude"] as? [Any])?.count, 0)
    }

    func testStoppedLegacyProviderDisabledBeforeMigrationRemovesItsKey() throws {
        let disabled = CustomProvider(name: "Old Claude", type: .claudeCompatibility,
                                      apiKeys: [CustomAPIKeyEntry(apiKey: "old-managed")], isEnabled: false)
        let legacy = """
        port: 8317
        # Custom Providers (managed by Quotio)
        claude-api-key:
          - api-key: old-managed
            proxy-url: http://old-proxy

        """
        let service = CustomProviderService.shared
        XCTAssertEqual(service.legacyOwnedProviderIDs(in: legacy, managedProviders: [disabled]), [disabled.id])
        let yaml = """
        config-version: 8
        server: {port: 8317}
        management: {secret-key: test}
        api-keys:
          claude:
            - proxy-url: http://old-proxy
              keys: [{api-key: old-managed}]

        """
        let file = try temporaryConfig(yaml)
        defer { try? FileManager.default.removeItem(at: file) }
        let patch = try XCTUnwrap(service.makeV8ProviderPatch(
            configPath: file.path, managedProviders: [disabled],
            legacyOwnedProviderIDs: [disabled.id], legacyOwnedKeys: service.legacyOwnedKeys(in: legacy)
        ))
        XCTAssertTrue(try groups(in: patch, family: "claude").isEmpty)
    }

    func testDeletedLegacyProviderIsRemovedButManualKeySurvivesMigration() throws {
        let legacy = """
        port: 8317
        # Custom Providers (managed by Quotio)
        claude-api-key:
          - api-key: old-managed

        """
        let yaml = """
        config-version: 8
        server: {port: 8317}
        management: {secret-key: test}
        api-keys:
          claude:
            - name: Old Claude
              keys:
                - {api-key: old-managed}
                - {api-key: manual-key, weight: 7}

        """
        let file = try temporaryConfig(yaml)
        defer { try? FileManager.default.removeItem(at: file) }
        let service = CustomProviderService.shared
        let patch = try XCTUnwrap(service.makeV8ProviderPatch(
            configPath: file.path, managedProviders: [], legacyOwnedKeys: service.legacyOwnedKeys(in: legacy)
        ))
        let remaining = try groups(in: patch, family: "claude")
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual((remaining[0]["keys"] as? [[String: Any]])?.first?["api-key"] as? String, "manual-key")
        XCTAssertEqual((remaining[0]["keys"] as? [[String: Any]])?.first?["weight"] as? Int, 7)
    }

    func testManualKeySurvivesManagedUpdateAndDeletion() throws {
        let provider = CustomProvider(name: "Private Claude", type: .claudeCompatibility,
                                      apiKeys: [CustomAPIKeyEntry(apiKey: "managed-key", proxyURL: "http://new-proxy")])
        let yaml = """
        config-version: 8
        server: {port: 8317}
        management: {secret-key: test}
        api-keys:
          claude:
            - name: Private Claude (Quotio \(provider.id.uuidString))
              keys:
                - {api-key: managed-key, weight: 4}
                - {api-key: manual-key, weight: 9}

        """
        let file = try temporaryConfig(yaml)
        defer { try? FileManager.default.removeItem(at: file) }
        let snapshot = CustomProviderService.V8SyncedFields(
            id: provider.id, models: [], headerNames: [], keyDigests: [digest("managed-key")]
        )
        let service = CustomProviderService.shared
        let updated = try XCTUnwrap(service.makeV8ProviderPatch(
            configPath: file.path, managedProviders: [provider], previouslySynced: [provider.id: snapshot]
        ))
        let updatedGroups = try groups(in: updated, family: "claude")
        XCTAssertEqual(updatedGroups.count, 1)
        let updatedKeys = try XCTUnwrap(updatedGroups[0]["keys"] as? [[String: Any]])
        XCTAssertEqual(Set(updatedKeys.compactMap { $0["api-key"] as? String }), ["managed-key", "manual-key"])
        XCTAssertEqual(updatedKeys.first { $0["api-key"] as? String == "manual-key" }?["weight"] as? Int, 9)
        XCTAssertEqual(updatedKeys.first { $0["api-key"] as? String == "managed-key" }?["proxy-url"] as? String,
                       "http://new-proxy")
        XCTAssertNil(updatedGroups[0]["disabled"], "CPA 8 的 Claude 分组不允许 disabled 字段")

        let deleted = try XCTUnwrap(service.makeV8ProviderPatch(
            configPath: file.path, managedProviders: [], previouslySynced: [provider.id: snapshot]
        ))
        let remaining = try groups(in: deleted, family: "claude")
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual((remaining[0]["keys"] as? [[String: Any]])?.first?["api-key"] as? String, "manual-key")
        XCTAssertFalse((remaining[0]["name"] as? String ?? "").contains("Quotio"))
    }

    func testDisabledProviderRemovesOnlyManagedKeyWithoutUnsupportedField() throws {
        let provider = CustomProvider(name: "Private Gemini", type: .geminiCompatibility,
                                      apiKeys: [CustomAPIKeyEntry(apiKey: "managed-key")], isEnabled: false)
        let yaml = """
        config-version: 8
        server: {port: 8317}
        management: {secret-key: test}
        api-keys:
          gemini:
            - name: Private Gemini (Quotio \(provider.id.uuidString))
              keys:
                - {api-key: managed-key}
                - {api-key: manual-key}

        """
        let file = try temporaryConfig(yaml)
        defer { try? FileManager.default.removeItem(at: file) }
        let snapshot = CustomProviderService.V8SyncedFields(
            id: provider.id, models: [], headerNames: [], keyDigests: [digest("managed-key")]
        )
        let patch = try XCTUnwrap(CustomProviderService.shared.makeV8ProviderPatch(
            configPath: file.path, managedProviders: [provider], previouslySynced: [provider.id: snapshot]
        ))
        let remaining = try groups(in: patch, family: "gemini")
        XCTAssertEqual((remaining[0]["keys"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((remaining[0]["keys"] as? [[String: Any]])?.first?["api-key"] as? String, "manual-key")
        XCTAssertNil(remaining[0]["disabled"])
        XCTAssertFalse((remaining[0]["name"] as? String ?? "").contains("Quotio"))
    }

    func testLegacyMultiKeyGroupsMergeAndClearPromotedProxy() throws {
        let provider = CustomProvider(name: "Private Claude", type: .claudeCompatibility,
                                      apiKeys: [CustomAPIKeyEntry(apiKey: "first-key"),
                                                CustomAPIKeyEntry(apiKey: "second-key", proxyURL: "http://new-proxy")])
        let yaml = """
        config-version: 8
        server: {port: 8317}
        management: {secret-key: test}
        api-keys:
          claude:
            - priority: 7
              proxy-url: http://old-proxy-one
              keys: [{api-key: first-key, weight: 3}]
            - priority: 7
              proxy-url: http://old-proxy-two
              keys: [{api-key: second-key, weight: 5}]

        """
        let file = try temporaryConfig(yaml)
        defer { try? FileManager.default.removeItem(at: file) }
        let patch = try XCTUnwrap(CustomProviderService.shared.makeV8ProviderPatch(
            configPath: file.path, managedProviders: [provider], legacyOwnedProviderIDs: [provider.id]
        ))
        let adopted = try XCTUnwrap(groups(in: patch, family: "claude").first)
        XCTAssertEqual(try groups(in: patch, family: "claude").count, 1)
        XCTAssertNil(adopted["proxy-url"])
        XCTAssertNil(adopted["disabled"])
        let keys = try XCTUnwrap(adopted["keys"] as? [[String: Any]])
        XCTAssertEqual(Set(keys.compactMap { $0["api-key"] as? String }), ["first-key", "second-key"])
        XCTAssertNil(keys.first { $0["api-key"] as? String == "first-key" }?["proxy-url"])
        XCTAssertEqual(keys.first { $0["api-key"] as? String == "second-key" }?["proxy-url"] as? String,
                       "http://new-proxy")
        XCTAssertEqual(keys.first { $0["api-key"] as? String == "second-key" }?["weight"] as? Int, 5)
    }

    /// 所有样本密钥均为无效占位值；测试只检验 PATCH 的归属与字段形状，不访问用户配置。
    private func temporaryConfig(_ yaml: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cpa-v8-provider-\(UUID().uuidString).yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func groups(in patch: Data, family: String) throws -> [[String: Any]] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: patch) as? [String: Any])
        let families = try XCTUnwrap(root["api-keys"] as? [String: Any])
        return try XCTUnwrap(families[family] as? [[String: Any]])
    }

    private func digest(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testOneLegacyGroupCannotBeClaimedByTwoProvidersSharingKey() throws {
        let first = CustomProvider(name: "First", type: .claudeCompatibility,
                                   apiKeys: [CustomAPIKeyEntry(apiKey: "fake-secret")])
        let second = CustomProvider(name: "Second", type: .claudeCompatibility,
                                    apiKeys: [CustomAPIKeyEntry(apiKey: "fake-secret")])
        let yaml = """
        config-version: 8
        server: {port: 8317}
        management: {secret-key: test}
        api-keys:
          claude:
            - priority: 9
              keys: [{api-key: fake-secret}]

        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cpa-v8-claim-\(UUID().uuidString).yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let patch = try XCTUnwrap(CustomProviderService.shared.makeV8ProviderPatch(
            configPath: file.path, managedProviders: [first, second],
            legacyOwnedProviderIDs: [first.id, second.id]
        ))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: patch) as? [String: Any])
        let families = try XCTUnwrap(root["api-keys"] as? [String: Any])
        let groups = try XCTUnwrap(families["claude"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0]["priority"] as? Int, 9)
        XCTAssertTrue((groups[0]["name"] as? String ?? "").contains(first.id.uuidString))
        XCTAssertTrue((groups[1]["name"] as? String ?? "").contains(second.id.uuidString))
    }
}
