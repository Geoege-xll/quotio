import XCTest
@testable import QuotioPlus

/// 从真实请求构造到 v8 注册补丁的离线契约回归，禁止连接真实账号或修改本机 CPA 配置。
@MainActor
final class MainstreamProviderCatalogTests: XCTestCase {
    private func fixture(_ body: String, status: Int = 200) -> (URLSession, String, LifecycleHTTPState) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let state = LifecycleHTTPState { _, _ in .replyStatus(body, status) }
        LifecycleHTTPProtocol.register(state, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleHTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel(); LifecycleHTTPProtocol.remove(host: host) }
        return (session, "https://" + host + "/v1", state)
    }

    func testLiveCatalogProducesRegisterableModelsForAllThreeProvidersAndKeepsOldMappings() async throws {
        let (session, base, state) = fixture(#"{"data":[{"id":"live-model","owned_by":"fixture"},{"id":"old-model"}]}"#)
        let yaml = "config-version: 8\nserver: {port: 8317}\nmanagement: {secret-key: fixture}\napi-keys: {}\n"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        for type in [CustomProviderType.deepseekCompatibility, .moonshotCompatibility, .minimaxCompatibility] {
            let catalog = try await CustomProviderService.fetchProviderModels(providerType: type, baseURL: base,
                apiKey: "fixture-client", session: session)
            let old = ModelMapping(name: "old-model", alias: "my-old-alias", thinkingBudget: "4096")
            let mappings = CustomProviderService.mergingProviderModels([old], catalog: catalog)
            XCTAssertEqual(mappings.count, 2)
            XCTAssertEqual(mappings.first, old, "刷新不能重建已有 UUID、别名或预算")
            let provider = CustomProvider(name: "Fixture", type: type, baseURL: base,
                apiKeys: [CustomAPIKeyEntry(apiKey: "fixture-client")], models: mappings)
            let patch = try XCTUnwrap(CustomProviderService.shared.makeV8ProviderPatch(configPath: file.path,
                managedProviders: [provider], previouslySynced: [:]))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: patch) as? [String: Any])
            let families = try XCTUnwrap(root["api-keys"] as? [String: Any])
            let groups = try XCTUnwrap(families["openai-compatibility"] as? [[String: Any]])
            let registered = try XCTUnwrap(groups.first?["models"] as? [[String: Any]])
            XCTAssertEqual(Set(registered.compactMap { $0["name"] as? String }), ["old-model", "live-model"])
            XCTAssertTrue(registered.contains { $0["alias"] as? String == "my-old-alias(4096)" })
        }
        XCTAssertEqual(state.requestCount, 3)
        XCTAssertTrue(state.requests.allSatisfy { $0.url.path == "/v1/models" && $0.authorization == "Bearer fixture-client" })
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), yaml)
    }

    func testFailedOrEmptyDirectoryNeverErasesExistingModelsOrAddsDefaults() async throws {
        let existing = [ModelMapping(name: "manual/model", alias: "my-alias")]
        let (empty, base, _) = fixture(#"{"data":[]}"#)
        let catalog = try await CustomProviderService.fetchProviderModels(providerType: .deepseekCompatibility,
            baseURL: base, apiKey: "fixture", session: empty)
        XCTAssertTrue(catalog.isEmpty)
        XCTAssertEqual(CustomProviderService.mergingProviderModels(existing, catalog: catalog), existing)
        for (body, status) in [("not a catalog", 200), (#"{"error":"invalid key"}"#, 401)] {
            let (session, base, _) = fixture(body, status: status)
            do {
                _ = try await CustomProviderService.fetchProviderModels(providerType: .moonshotCompatibility,
                    baseURL: base, apiKey: "fixture", session: session)
                XCTFail("目录失败不能被当成成功或静态候选")
            } catch { }
            XCTAssertEqual(existing[0].alias, "my-alias")
        }
    }
}
