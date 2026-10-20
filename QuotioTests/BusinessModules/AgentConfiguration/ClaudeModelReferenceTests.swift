import XCTest
@testable import QuotioPlus

/// 选择器语法与最终请求 ID 的纯契约回归：不读取本机目录、不访问网络、不依赖 CLI 的展示文字。
final class ClaudeModelReferenceTests: XCTestCase {
    func testClassificationSeparatesNativeRolesSpecialInstructionsAndLiteralIDs() {
        for role in ModelSlot.allCases {
            let reference = ClaudeModelReference(" " + role.rawValue + "[1M] ")
            XCTAssertEqual(reference.kind, .role(role))
            XCTAssertEqual(reference.selector, role.rawValue + "[1m]")
            XCTAssertNil(reference.wireModelID)
        }
        for special in ClaudeModelReference.Special.allCases {
            XCTAssertEqual(ClaudeModelReference(special.rawValue + "[1m]").kind, .special(special))
        }
        let literal = ClaudeModelReference("  LegalPrefix/Exact-Model[1M]  ")
        XCTAssertEqual(literal.kind, .literal)
        XCTAssertEqual(literal.wireModelID, "LegalPrefix/Exact-Model")
        XCTAssertEqual(literal.selector, "LegalPrefix/Exact-Model[1m]")
        XCTAssertEqual(ClaudeModelReference("LegalPrefix/opus").kind, .literal)
        XCTAssertEqual(ClaudeModelReference(" ").kind, .empty)
        XCTAssertEqual(ClaudeModelReference("[1m]").kind, .empty)
    }

    func testCatalogConfirmationRequiresExactWireIDAndNeverGuessesCaseOrPrefix() {
        let long = ClaudeModelReference("LegalPrefix/Exact-Model[1m]")
        XCTAssertTrue(long.isConfirmed(in: ["LegalPrefix/Exact-Model"]))
        XCTAssertFalse(long.isConfirmed(in: ["LegalPrefix/Exact-Model[1m]"]))
        XCTAssertFalse(long.isConfirmed(in: ["legalprefix/exact-model"]))
        XCTAssertFalse(long.isConfirmed(in: ["Exact-Model"]))
        XCTAssertFalse(ClaudeModelReference("opus").isConfirmed(in: ["opus"]))
        XCTAssertFalse(ClaudeModelReference("default[1m]").isConfirmed(in: ["default"]))
    }

    func testRoleChainCarriesInnerAndExplicitOuterContextWithoutChangingStoredRoles() {
        let roles: [ModelSlot: String] = [.opus: "sonnet", .sonnet: "haiku", .haiku: "legal/model"]
        let plain = ClaudeModelReference("opus").resolvingRoles(in: roles)
        XCTAssertEqual(plain?.selector, "legal/model")
        XCTAssertEqual(ClaudeModelReference("opus").resolvingRoles(in: roles, oneMillion: [.haiku: true])?.selector, "legal/model[1m]")
        XCTAssertEqual(ClaudeModelReference("opus[1m]").resolvingRoles(in: roles, oneMillion: [.opus: false, .sonnet: false, .haiku: false])?.selector, "legal/model[1m]")
        XCTAssertEqual(roles[.opus], "sonnet", "纯解析不能将旧角色继承关系回写为固定模型")
    }

    func testExplicitSlotChoiceOverridesItsLegacySuffixAndRemainsIndependent() {
        let roles: [ModelSlot: String] = [.sonnet: "same-model[1m]", .haiku: "same-model"]
        let choices: [ModelSlot: Bool] = [.sonnet: false, .haiku: true]
        XCTAssertEqual(ClaudeModelReference("sonnet").resolvingRoles(in: roles, oneMillion: choices)?.selector, "same-model")
        XCTAssertEqual(ClaudeModelReference("haiku").resolvingRoles(in: roles, oneMillion: choices)?.selector, "same-model[1m]")
        XCTAssertEqual(ClaudeModelReference("sonnet[1m]").resolvingRoles(in: roles, oneMillion: choices)?.selector, "same-model[1m]")
    }

    func testCycleMissingAndSpecialRoleTargetsAreRejectedWithoutFallback() {
        for roles: [ModelSlot: String] in [[.opus: "sonnet", .sonnet: "opus"], [.opus: "sonnet"], [.opus: "inherit"], [.opus: ""], [.opus: "default[1m]"]] {
            XCTAssertNil(ClaudeModelReference("opus").resolvingRoles(in: roles))
        }
        XCTAssertNil(ClaudeModelReference("best").resolvingRoles(in: [:]))
    }

    func testConfigurationDefaultAndPureResolverShareChainAndContextSemantics() {
        var configuration = AgentConfiguration(agent: .claudeCode, proxyURL: "https://fixture.invalid", apiKey: "fixture")
        configuration.modelSlots = [.opus: "sonnet", .sonnet: "same-model", .haiku: "same-model"]
        configuration.claudeModel1M = [.sonnet: false, .haiku: true]
        configuration.claudeDefaultModel = "opus[1m]"
        XCTAssertEqual(configuration.claudeDefaultModelSelector, "opus[1m]")
        XCTAssertEqual(configuration.claudeDefaultRequestModel, "same-model[1m]")
        XCTAssertEqual(configuration.resolvedClaudeReference("haiku")?.selector, "same-model[1m]")
        XCTAssertEqual(configuration.resolvedClaudeReference("sonnet")?.selector, "same-model")
        configuration.claudeDefaultModel = "opus"
        configuration.claudeModel1M[.sonnet] = true
        XCTAssertTrue(configuration.claudeDefaultUses1MContext, "跟随角色时的上下文回显也必须反映整条角色链")
        XCTAssertEqual(configuration.claudeModelDescription(for: .opus), "same-model[1m]")
        configuration.claudeModel1M[.sonnet] = false
        let original = configuration
        XCTAssertEqual(configuration, original)
        configuration.claudeModel1M[.sonnet] = true
        XCTAssertNotEqual(configuration, original, "完整草稿等价性必须覆盖角色上下文声明，供现有预览输入变化判断")
    }
}
