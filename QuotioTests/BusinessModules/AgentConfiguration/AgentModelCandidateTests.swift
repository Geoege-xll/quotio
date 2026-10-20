import XCTest
@testable import QuotioPlus

/// 只验证客户端候选的业务边界：目录证据、别名公开 ID、旧值及原生角色相互独立。
/// 通过原 VM 的加载入口与显式屏障验证账号变更竞态，不读取本机账号、不启动 CPA。
@MainActor
final class AgentModelCandidateTests: XCTestCase {
    private func model(_ id: String, name: String? = nil) -> AvailableModel {
        AvailableModel(id: id, name: name ?? id, provider: "fixture", isDefault: false)
    }
    private func alias(_ id: String, target: String = "live-model") -> CPAModelAlias {
        CPAModelAlias(id: id, model: target, alias: id, provider: "fixture", protocolName: "openai",
            effort: nil, channel: nil, section: nil, providerIndex: 0, modelIndex: 0)
    }
    private func policy(_ models: [AvailableModel], aliases: [CPAModelAlias] = [], selected: String = "",
                        agent: CLIAgent = .claudeCode, allowsRoles: Bool = true) -> AgentModelCandidatePolicy {
        AgentModelCandidatePolicy(agent: agent, models: models, aliases: aliases,
                                  selectedModel: selected, allowsRoleSelection: allowsRoles)
    }
    private func configure(_ vm: AgentSetupViewModel, key: String = "fixture-key") {
        vm.selectedAgent = .codexCLI
        var config = AgentConfiguration(agent: .codexCLI, proxyURL: "https://fixture.invalid/v1", apiKey: key)
        config.codexModel = "legacy/selected"
        vm.currentConfiguration = config
    }

    func testOnlyPublishedRequestIDsBecomeCandidatesAndOldSelectionStaysSeparate() {
        let result = policy([model("live-model", name: "Human Display Name"), model("legal/model"), model("live-model")], selected: "legacy/selected")
        XCTAssertEqual(Set(result.modelIDs), ["live-model", "legal/model"])
        XCTAssertFalse(result.modelIDs.contains("Human Display Name"))
        XCTAssertFalse(result.modelIDs.contains("legacy/selected"))
        XCTAssertTrue(result.hasUnconfirmedSelection)
        XCTAssertEqual(result.selectedModel, "legacy/selected")
    }

    func testAliasesRequireTheirOwnPublicIDAndKeepAliasOnlyDirectories() {
        let aliases = [alias("published-alias", target: "not-exposed-target"), alias("ghost-alias"), alias("Case-Alias")]
        let result = policy([model("live-model"), model("published-alias"), model("case-alias")], aliases: aliases)
        XCTAssertEqual(result.confirmedAliases.map(\.alias), ["published-alias"])
        XCTAssertEqual(Set(result.modelIDs), ["live-model", "case-alias"])
        XCTAssertTrue(policy([model("live-model")], aliases: aliases, selected: "ghost-alias").hasUnconfirmedSelection)
        XCTAssertFalse(policy([model("published-alias")], aliases: aliases, selected: "published-alias").hasUnconfirmedSelection)
    }

    func testClaudeRolesAndOneMillionStayNativeWithoutInventingCatalogModels() {
        for slot in ModelSlot.allCases {
            for suffix in ["", "[1m]"] {
                let result = policy([], selected: slot.rawValue + suffix)
                XCTAssertEqual(result.selectedRole, slot)
                XCTAssertFalse(result.hasUnconfirmedSelection)
                XCTAssertTrue(result.modelIDs.isEmpty)
            }
            let mapping = policy([], selected: slot.rawValue, allowsRoles: false)
            XCTAssertNil(mapping.selectedRole)
            XCTAssertTrue(mapping.hasUnconfirmedSelection, "已有角色值保留回显，但实际模型槽不能把它当作已确认的具体型号")
        }
        XCTAssertFalse(policy([model("legal/model")], selected: "legal/model[1M]").hasUnconfirmedSelection)
        XCTAssertTrue(policy([model("legal/model")], selected: "legal/model[1m]", agent: .codexCLI).hasUnconfirmedSelection)
        XCTAssertFalse(policy([model("legal/model[1m]")], selected: "legal/model[1m]", agent: .codexCLI).hasUnconfirmedSelection)
    }

    func testActualSlotsRejectEveryRoleVariantAndSpecialManualInput() {
        for role in ModelSlot.allCases {
            for suffix in ["", "[1m]", "[1M]"] {
                let selector = role.rawValue + suffix
                let actual = policy([model(selector)], selected: selector, allowsRoles: false)
                XCTAssertFalse(actual.isConfirmed(selector))
                XCTAssertTrue(actual.hasUnconfirmedSelection)
                XCTAssertFalse(actual.canAddCustomModel(selector), "实际槽手填不能绕过角色禁止规则")
                XCTAssertTrue(actual.modelIDs.isEmpty)
            }
            XCTAssertTrue(policy([], allowsRoles: true).canAddCustomModel(role.rawValue + "[1m]"), "Default／子代理仍可显式跟随 1M 角色")
        }
        for special in ClaudeModelReference.Special.allCases {
            for suffix in ["", "[1m]"] {
                let selector = special.rawValue + suffix
                let value = policy([model(selector)], aliases: [alias(selector)], selected: selector)
                XCTAssertFalse(value.isConfirmed(selector))
                XCTAssertFalse(value.canAddCustomModel(selector))
                XCTAssertTrue(value.modelIDs.isEmpty)
                XCTAssertTrue(value.confirmedAliases.isEmpty)
            }
        }
        XCTAssertTrue(policy([]).canAddCustomModel("legal/Unknown-Model[1m]"), "保留手填未知 ID，最终是否可写由严格目录计划决定")
    }

    func testOnlyLongContextCatalogRowCannotConfirmWireIdentityOrAlias() {
        let value = policy([model("live[1m]")], aliases: [alias("live[1m]")], selected: "live[1m]")
        XCTAssertTrue(value.hasUnconfirmedSelection)
        XCTAssertFalse(value.isConfirmed("live"))
        XCTAssertFalse(value.isConfirmed("live[1m]"))
        XCTAssertTrue(value.modelIDs.isEmpty)
        XCTAssertTrue(value.confirmedAliases.isEmpty)
        XCTAssertEqual(value.selectedModel, "live[1m]", "旧值保留但不能冒充当前可发送的模型")
        let confirmed = policy([model("live"), model("live[1m]")], selected: "live[1m]")
        XCTAssertFalse(confirmed.hasUnconfirmedSelection)
    }

    func testRoleTargetEvidenceFollowsWholeChainAndDetectsCycles() {
        var value = AgentModelCandidatePolicy(agent: .claudeCode, models: [model("live")], aliases: [],
            selectedModel: "opus", slotModels: [.opus: "sonnet", .sonnet: "live[1m]"])
        XCTAssertFalse(value.hasUnconfirmedSelection)
        XCTAssertEqual(value.resolvedTarget(for: .opus)?.selector, "live[1m]")
        value.slotModels[.sonnet] = "opus"
        XCTAssertTrue(value.hasUnconfirmedSelection)
        XCTAssertNil(value.resolvedTarget(for: .opus))
        value.slotModels[.sonnet] = "inherit"
        XCTAssertTrue(value.hasUnconfirmedSelection)
    }

    func testCaseAndProviderNamesDoNotGuessRequestIdentity() {
        let result = policy([model("Codex/actual-model")], selected: "codex/actual-model")
        XCTAssertEqual(result.modelIDs, ["Codex/actual-model"])
        XCTAssertTrue(result.hasUnconfirmedSelection)
        XCTAssertFalse(result.isConfirmed("actual-model"))
        XCTAssertFalse(policy([model("actual-model")], selected: "codex/actual-model").isConfirmed("codex/actual-model"))
    }

    func testNativeRoleRemainsSelectableWhenItsConfiguredTargetIsUnconfirmed() {
        let value = AgentModelCandidatePolicy(agent: .claudeCode, models: [model("live")], aliases: [],
            selectedModel: "sonnet[1m]", slotModels: [.sonnet: "legacy/target"])
        XCTAssertEqual(value.selectedRole, .sonnet)
        XCTAssertTrue(value.hasUnconfirmedSelection)
        XCTAssertTrue(value.isUnconfirmedTarget(for: .sonnet))
        XCTAssertFalse(value.isUnconfirmedTarget(for: .fable))
    }

    func testCurrentCandidateEvidenceExpiresImmediatelyWhenConnectionChanges() async {
        let vm = AgentSetupViewModel(fetchModels: { _, _ in [selfContainedModel("live-model")] })
        configure(vm)
        let loaded = await vm.loadModels()
        XCTAssertTrue(loaded)
        XCTAssertEqual(vm.currentModelCandidates.map(\.id), ["live-model"])
        XCTAssertNotNil(vm.currentModelCatalogRevision)
        vm.currentConfiguration?.apiKey = "new-key"
        XCTAssertTrue(vm.currentModelCandidates.isEmpty)
        XCTAssertNil(vm.currentModelCatalogRevision)
        vm.currentConfiguration?.apiKey = "fixture-key"
        vm.currentConfiguration?.proxyURL = "https://other.invalid/v1"
        XCTAssertTrue(vm.currentModelCandidates.isEmpty)
        XCTAssertEqual(vm.currentConfiguration?.codexModel, "legacy/selected")
    }

    private actor Gate {
        let started: XCTestExpectation
        private var continuation: CheckedContinuation<[AvailableModel], Never>?
        init(_ started: XCTestExpectation) { self.started = started }
        func fetch() async -> [AvailableModel] {
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        }
        func release(_ values: [AvailableModel]) { continuation?.resume(returning: values); continuation = nil }
    }
    private actor Sequence {
        let first: Gate
        private var count = 0
        init(_ first: Gate) { self.first = first }
        func fetch() async -> [AvailableModel] {
            count += 1
            if count == 1 { return await first.fetch() }
            return [selfContainedModel("shared-model")]
        }
    }

    func testAccountChangeInvalidatesLateResponseAndReloadKeepsOldDraft() async throws {
        let started = expectation(description: "账号变更前的目录挂起")
        let gate = Gate(started), sequence = Sequence(gate)
        let vm = AgentSetupViewModel(fetchModels: { _, _ in await sequence.fetch() })
        configure(vm)
        let old = Task { await vm.loadModels() }
        await fulfillment(of: [started], timeout: 2)
        let reload = try XCTUnwrap(vm.invalidateModelsForAccountChange(serviceBaseURLs: ["https://fixture.invalid"]))
        XCTAssertTrue(vm.currentModelCandidates.isEmpty)
        XCTAssertFalse(vm.isFetchingModels)
        await gate.release([model("disabled-exclusive")])
        let oldCommitted = await old.value
        XCTAssertFalse(oldCommitted)
        XCTAssertTrue(vm.currentModelCandidates.isEmpty)
        let reloaded = await vm.reloadModelsAfterAccountChange(reload)
        XCTAssertTrue(reloaded)
        XCTAssertEqual(vm.currentModelCandidates.map(\.id), ["shared-model"])
        XCTAssertEqual(vm.currentConfiguration?.codexModel, "legacy/selected")
    }

    func testNewManualRefreshSupersedesPendingAccountReloadAndExternalServiceIsUntouched() async throws {
        let vm = AgentSetupViewModel(fetchModels: { _, _ in [selfContainedModel("new-catalog")] })
        configure(vm)
        XCTAssertNil(vm.invalidateModelsForAccountChange(serviceBaseURLs: ["https://another.invalid"]))
        XCTAssertNil(vm.modelLoadMessage)
        let reload = try XCTUnwrap(vm.invalidateModelsForAccountChange(serviceBaseURLs: ["https://fixture.invalid/"]))
        let manual = await vm.loadModels(forceRefresh: true)
        XCTAssertTrue(manual)
        let redundant = await vm.reloadModelsAfterAccountChange(reload)
        XCTAssertFalse(redundant)
        XCTAssertEqual(vm.currentModelCandidates.map(\.id), ["new-catalog"])
    }

    func testClosedReopenedAndChangedServiceRejectOldAccountReload() async throws {
        for next in ["close", "service", "key"] {
            let vm = AgentSetupViewModel(fetchModels: { _, _ in XCTFail("旧账号回调不能触发新来源读取"); return [] })
            configure(vm)
            let reload = try XCTUnwrap(vm.invalidateModelsForAccountChange(serviceBaseURLs: ["https://fixture.invalid"]))
            switch next {
            case "close": vm.dismissConfiguration(); configure(vm)
            case "service": vm.currentConfiguration?.proxyURL = "https://elsewhere.invalid/v1"
            default: vm.currentConfiguration?.apiKey = "changed-key"
            }
            let accepted = await vm.reloadModelsAfterAccountChange(reload)
            XCTAssertFalse(accepted)
        }
    }

    func testFailedAccountReloadKeepsSelectionAndSupportsManualRetry() async throws {
        let vm = AgentSetupViewModel(fetchModels: { _, key in
            if key == "fixture-key" { throw URLError(.notConnectedToInternet) }
            return [selfContainedModel("recovered")]
        })
        configure(vm)
        let reload = try XCTUnwrap(vm.invalidateModelsForAccountChange(serviceBaseURLs: ["https://fixture.invalid"]))
        let result = await vm.reloadModelsAfterAccountChange(reload)
        XCTAssertFalse(result)
        XCTAssertTrue(vm.currentModelCandidates.isEmpty)
        XCTAssertNotNil(vm.modelLoadMessage)
        XCTAssertEqual(vm.currentConfiguration?.codexModel, "legacy/selected")
        vm.currentConfiguration?.apiKey = "working-key"
        let retry = await vm.loadModels(forceRefresh: true)
        XCTAssertTrue(retry)
        XCTAssertEqual(vm.currentModelCandidates.map(\.id), ["recovered"])
    }
}

/// 非隔离的夹具构造可从发送闭包／actor 中调用，不捕获 XCTestCase 或真实账号状态。
private nonisolated func selfContainedModel(_ id: String) -> AvailableModel {
    AvailableModel(id: id, name: id, provider: "fixture", isDefault: false)
}
