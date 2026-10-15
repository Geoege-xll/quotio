import Foundation
import XCTest
@testable import QuotioPlus

/// 覆盖配置读取、精确 PATCH 与权重身份，验证兼容行为而非仅检查字段拼写。
@MainActor
final class CPARequestSettingsTests: XCTestCase {
    private func decode(_ json: String) throws -> ProxyConfig {
        try JSONDecoder().decode(ProxyConfig.self, from: Data(json.utf8))
    }

    private func root(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    func testNestedV8ValuesKeepExplicitFalseAndZero() throws {
        let config = try decode(#"{"config-version":8,"routing":{"strategy":"weighted-round-robin","session-affinity":false,"session-affinity-ttl":"45m","session-affinity-subagents":false,"retry":{"request-retry":0,"max-retry-interval":0,"max-retry-credentials":0}},"requests":{"streaming":{"keepalive-seconds":0,"bootstrap-retries":0}},"observability":{"logs":{"logs-max-total-size-mb":0,"error-logs-max-files":0}},"request-retry":9}"#)
        XCTAssertEqual(config.routingStrategy, "weighted-round-robin")
        XCTAssertEqual(config.requestRetry, 0)
        XCTAssertEqual(config.sessionAffinity, false)
        let draft = CPAAdvancedSettingsDraft(config: config)
        XCTAssertEqual(draft.sessionTTL, "45m")
        XCTAssertFalse(draft.sessionSubagents)
        XCTAssertEqual(draft.maxRetryCredentials, "0")
        XCTAssertEqual(draft.keepaliveSeconds, "0")
        XCTAssertEqual(draft.bootstrapRetries, "0")
        XCTAssertEqual(draft.logsMaxSizeMB, "0")
        XCTAssertEqual(draft.errorLogsMaxFiles, "0")
    }

    func testMissingAndNullNodesUseRuntimeDefaultsWithoutGeneratingWrites() throws {
        let config = try decode(#"{"config-version":8,"routing":{"session-affinity":null,"retry":null},"requests":{"streaming":null},"observability":{"logs":null}}"#)
        let draft = CPAAdvancedSettingsDraft(config: config)
        XCTAssertEqual(draft.sessionTTL, "1h")
        XCTAssertTrue(draft.sessionSubagents)
        XCTAssertEqual(draft.maxRetryCredentials, "0")
        XCTAssertEqual(draft.errorLogsMaxFiles, "10")
        XCTAssertNil(try draft.patch(comparedTo: draft, scope: .requests))
        XCTAssertNil(try draft.patch(comparedTo: draft, scope: .logging))
    }

    func testChangingRetryLimitOnlyPatchesThatFieldAndKeepsZero() throws {
        var saved = CPAAdvancedSettingsDraft()
        saved.maxRetryCredentials = "4"; saved.sessionTTL = "37m15s"; saved.sessionSubagents = false
        var draft = saved
        draft.maxRetryCredentials = "0"
        let value = try root(draft.patch(comparedTo: saved, scope: .requests))
        XCTAssertEqual(Set(value.keys), ["routing"])
        let routing = try XCTUnwrap(value["routing"] as? [String: Any])
        XCTAssertEqual(Set(routing.keys), ["retry"])
        XCTAssertEqual((routing["retry"] as? [String: Int])?["max-retry-credentials"], 0)
    }

    func testUneditedNegativeKeepaliveDoesNotBlockAnotherChange() throws {
        var saved = CPAAdvancedSettingsDraft()
        saved.keepaliveSeconds = "-1"
        var draft = saved
        draft.bootstrapRetries = "2"
        let value = try root(draft.patch(comparedTo: saved, scope: .requests))
        let streaming = try XCTUnwrap((value["requests"] as? [String: Any])?["streaming"] as? [String: Int])
        XCTAssertEqual(streaming, ["bootstrap-retries": 2])
        draft.keepaliveSeconds = "-3"
        XCTAssertEqual(((try root(draft.patch(comparedTo: saved, scope: .requests)))["requests"] as? [String: Any])?["streaming"] as? [String: Int],
            ["bootstrap-retries": 2, "keepalive-seconds": -3])
    }

    func testLoggingPatchExcludesPendingRequestDraftAndZeroIsPreserved() throws {
        let saved = CPAAdvancedSettingsDraft()
        var draft = saved
        draft.sessionTTL = "2h"; draft.maxRetryCredentials = "3"
        draft.logsMaxSizeMB = "256"; draft.errorLogsMaxFiles = "0"
        let value = try root(draft.patch(comparedTo: saved, scope: .logging))
        XCTAssertEqual(Set(value.keys), ["observability"])
        XCTAssertEqual((value["observability"] as? [String: Any])?["logs"] as? [String: Int],
            ["logs-max-total-size-mb": 256, "error-logs-max-files": 0])
        var baseline = saved
        baseline.accept(draft, scope: .logging)
        XCTAssertNil(try draft.patch(comparedTo: baseline, scope: .logging))
        XCTAssertNotNil(try draft.patch(comparedTo: baseline, scope: .requests))
    }

    func testInvalidNumericDraftCannotBecomeAnAccidentalZero() throws {
        for input in ["abc", "1.5", "-2", "999999999999999999999999999", ""] {
            var draft = CPAAdvancedSettingsDraft()
            draft.maxRetryCredentials = input
            XCTAssertThrowsError(try draft.patch(comparedTo: .init(), scope: .requests))
        }
        var draft = CPAAdvancedSettingsDraft()
        draft.sessionTTL = "  "
        XCTAssertThrowsError(try draft.patch(comparedTo: .init(), scope: .requests))
    }

    func testSessionTTLRejectsValuesCoreWouldSilentlyAcceptAndKeepsGoDurations() throws {
        for value in ["not-duration", "1d", "1e4s", "", "2h-invalid", "999999999999h", "9223372036854775808ns"] {
            XCTAssertFalse(CPAAdvancedSettingsDraft.isValidSessionTTL(value), value)
            var draft = CPAAdvancedSettingsDraft()
            draft.sessionTTL = value
            XCTAssertThrowsError(try draft.patch(comparedTo: .init(), scope: .requests))
        }
        for value in ["1h30m", ".5h", "1.5s", "20ms", "10µs", "10μs", "0", "-1s", "+30m", "9223372036854775807ns", "-9223372036854775808ns"] {
            XCTAssertTrue(CPAAdvancedSettingsDraft.isValidSessionTTL(value), value)
        }
    }

    func testStrategyAliasesAndUnknownValuesAreNotMislabeled() {
        for alias in ["weighted-round-robin", "weightedroundrobin", "wrr", " WRR "] {
            XCTAssertEqual(CPARoutingStrategy.canonicalValue(alias), "weighted-round-robin")
            XCTAssertEqual(CPARoutingStrategy.displayName(for: alias), "settings.weightedRoundRobin".localized())
        }
        XCTAssertEqual(CPARoutingStrategy.canonicalValue("ff"), "fill-first")
        XCTAssertEqual(CPARoutingStrategy.displayName(for: "future-strategy"), "future-strategy")
        XCTAssertEqual(CPARoutingStrategy.allCases.count, 3)
    }

    func testOldKeyJSONWithoutWeightRemainsReadableAndDoesNotInventOne() throws {
        let id = UUID()
        let key = try JSONDecoder().decode(CustomAPIKeyEntry.self,
            from: Data("{\"id\":\"\(id.uuidString)\",\"api-key\":\"fake-key\",\"proxy-url\":\"direct\"}".utf8))
        XCTAssertEqual(key.id, id); XCTAssertNil(key.weight)
        XCTAssertEqual(key.proxyURL, "direct")
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(key)) as? [String: Any])
        XCTAssertNil(saved["weight"])
    }

    func testWeightEditsUseKeyIdentityAndObservedValuesDoNotBecomeWriteIntent() throws {
        let first = CustomAPIKeyEntry(apiKey: "first")
        let second = CustomAPIKeyEntry(apiKey: "second", proxyURL: "direct", weight: 2)
        let keys = try CustomAPIKeyEntry.applyingRoutingWeights([second, first], drafts: [first.id: "0", UUID(): "99"])
        XCTAssertEqual(keys[0], second)
        XCTAssertEqual(keys[1].weight, 0)
        let observed = try CustomAPIKeyEntry.applyingRoutingWeights([first], drafts: [first.id: "5"], observed: [first.id: 5])
        XCTAssertNil(observed[0].weight, "显示或焦点回写已有权重不能接管该字段")
        let untouched = try CustomAPIKeyEntry.applyingRoutingWeights([first], drafts: [:], observed: [first.id: 5])
        XCTAssertNil(untouched[0].weight)
        XCTAssertEqual(try CPAAccountWeight.parse("-1"), -1)
        XCTAssertEqual(try CPAAccountWeight.parse("1000000"), 1_000_000)
        XCTAssertThrowsError(try CPAAccountWeight.parse("1000001"))
        XCTAssertThrowsError(try CPAAccountWeight.parse("2.5"))
    }

    func testWeightEditorOnlyAppearsForPersistentCPAJSONAccounts() throws {
        for (attributes, expected) in [
            (#""source":"file""#, true), (#""source":"memory""#, true),
            (#""runtime_only":true,"source":"memory""#, false),
            (#""source":"api-key""#, false), (#""source":"plugin""#, false)
        ] {
            let account = try JSONDecoder().decode(AuthFile.self,
                from: Data("{\"name\":\"fixture.json\",\"provider\":\"claude\",\(attributes)}".utf8))
            XCTAssertEqual(AccountRowData.from(authFile: account, provider: .claude).canEditRoutingWeight, expected)
        }
    }

    func testMenuBarCategoryIsMergedIntoGeneralAndAppearance() {
        XCTAssertFalse(SettingsCategory.allCases.map(\.rawValue).contains("menuBar"), "菜单栏与 Dock 不应作为独立顶层分类存在")
        XCTAssertTrue(SettingsCategory.general.topics.contains(.menuBar), "通用与外观分类中必须包含菜单栏与 Dock 主题")
        XCTAssertEqual(SettingsTopic.menuBar.category, .general, "菜单栏主题必须归属于通用与外观分类")
        XCTAssertTrue(SettingsTopic.menuBar.matches("菜单栏"), "搜索菜单栏应命中通用与外观下的菜单栏主题")
        XCTAssertTrue(SettingsTopic.menuBar.matches("Dock"), "搜索 Dock 应命中通用与外观下的菜单栏主题")
    }
}
