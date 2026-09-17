import CryptoKit
import XCTest
@testable import QuotioPlus

/// 所有凭据均为人工样本。临时目录、内存后端及 URLProtocol 隔离真实钥匙串和网络。
final class MonitorUpstreamCompletionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func quota(_ percentage: Double = 75) -> ProviderQuotaData {
        ProviderQuotaData(models: [ModelQuota(name: "test", percentage: percentage, resetTime: "")],
                          lastUpdated: Date(timeIntervalSince1970: percentage))
    }

    private func source(_ id: String, key: String = "same@example.com", kind: CodexMonitorSource.Kind = .file("fixture")) -> CodexMonitorSource {
        CodexMonitorSource(account: .make(provider: .codex, accountKey: key, source: .nativeCredential,
                                          credentialReference: id), accountID: id, kind: kind)
    }

    private func jwt(id: String, email: String = "same@example.com") throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "email": email, "exp": 4_102_444_800,
            "https://api.openai.com/auth": ["chatgpt_account_id": id, "chatgpt_plan_type": "pro"]
        ])
        return "e30." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".fixture"
    }

    private func native(id: String) throws -> Data {
        let token = try jwt(id: id)
        return try JSONEncoder().encode(CodexCLIAuthFile(tokens: CodexCLITokens(
            idToken: token, accessToken: token, refreshToken: "refresh-" + id, accountId: id)))
    }

    private func fetcher(root: URL, paths: [String] = [], vault: any MonitorCredentialStore = CompletionEmptyVault(),
                         keychain: @escaping @Sendable (String?) -> (data: Data, account: String)? = { _ in nil }) -> CodexCLIQuotaFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompletionHTTPProtocol.self]
        return CodexCLIQuotaFetcher(authPaths: paths, legacyDirectory: root.path, vault: vault,
                                   metadata: MonitorMetadataStore(url: root.appendingPathComponent("metadata.json")),
                                   session: URLSession(configuration: configuration), keychainReader: keychain)
    }

    @MainActor
    private func isolatedViewModel() throws -> QuotaViewModel {
        let root = try directory()
        let originalMode = OperatingModeManager.shared.currentMode
        let originalIDE = UserDefaults.standard.data(forKey: "persisted.ideQuotas")
        addTeardownBlock {
            await MainActor.run {
                OperatingModeManager.shared.setMode(originalMode)
                if let originalIDE { UserDefaults.standard.set(originalIDE, forKey: "persisted.ideQuotas") }
                else { UserDefaults.standard.removeObject(forKey: "persisted.ideQuotas") }
            }
        }
        OperatingModeManager.shared.setMode(.monitor)
        let service = DirectAuthFileService(authDirectory: root)
        let metadata = MonitorMetadataStore(url: root.appendingPathComponent("metadata.json"))
        let coordinator = MonitorRefreshCoordinator(
            discovery: MonitorAccountDiscovery(vault: CompletionEmptyVault(), directAuthService: service,
                                               metadata: metadata, codexFetcher: fetcher(root: root)),
            snapshots: MonitorSnapshotStore(url: root.appendingPathComponent("snapshot.json")))
        let viewModel = QuotaViewModel(monitorCoordinator: coordinator, directAuthService: service)
        viewModel.monitorDiscoveryHookForTesting = { _ in [] }
        return viewModel
    }

    /// 删除后主动重加同键，旧数据库请求不能把刚添加的数据覆盖成之前的结果。
    @MainActor
    func testIDEDeletionAndReaddRejectsOldInFlightResult() async throws {
        let model = try isolatedViewModel()
        model.providerQuotas = [.cursor: ["A": quota(10)]]
        let gate = CompletionGate()
        let started = expectation(description: "IDE 请求挂起")
        model.ideQuotaFetchHookForTesting = { _ in started.fulfill(); await gate.wait(); return ["A": self.quota(50)] }
        let refresh = Task { await model.refreshImportedIDEQuotas() }
        await fulfillment(of: [started], timeout: 5)
        await model.deleteAutoDetectedAccount(provider: .cursor, accountKey: "A")
        model.providerQuotas[.cursor] = ["A": quota(90)]
        await gate.open()
        await refresh.value
        XCTAssertEqual(model.providerQuotas[.cursor]?["A"]?.models.first?.percentage, 90)
    }

    /// 离开 Monitor 再返回时枚举值虽相同，模式世代已变化，旧刷新仍不可提交。
    @MainActor
    func testModeRoundTripInvalidatesInFlightRefresh() async throws {
        let model = try isolatedViewModel()
        model.providerQuotas = [.cursor: ["A": quota(10)]]
        let gate = CompletionGate()
        let started = expectation(description: "切换前请求已挂起")
        model.ideQuotaFetchHookForTesting = { _ in started.fulfill(); await gate.wait(); return ["A": self.quota(80)] }
        let refresh = Task { await model.refreshImportedIDEQuotas() }
        await fulfillment(of: [started], timeout: 5)
        OperatingModeManager.shared.setMode(.localProxy)
        OperatingModeManager.shared.setMode(.monitor)
        await gate.open()
        await refresh.value
        XCTAssertEqual(model.providerQuotas[.cursor]?["A"]?.models.first?.percentage, 10)
    }

    /// 账号发现返回的旧列表也必须丢弃，不能只保护 quota 字典。
    @MainActor
    func testDiscoverySuspendedDuringDeletionCannotRestoreAccountList() async throws {
        let model = try isolatedViewModel()
        let account = MonitorAccount.make(provider: .cursor, accountKey: "A", source: .localIDE, canDelete: true)
        model.providerQuotas = [.cursor: ["A": quota()]]
        model.monitorAccounts = [account]
        let gate = CompletionGate()
        let started = expectation(description: "账号发现挂起")
        model.monitorDiscoveryHookForTesting = { _ in started.fulfill(); await gate.wait(); return [account] }
        let load = Task { await model.loadDirectAuthFiles() }
        await fulfillment(of: [started], timeout: 5)
        model.monitorDiscoveryHookForTesting = { _ in [] }
        await model.deleteAutoDetectedAccount(provider: .cursor, accountKey: "A")
        await gate.open()
        await load.value
        XCTAssertFalse(model.monitorAccounts.contains { $0.accountKey == "A" })
        XCTAssertNil(model.providerQuotas[.cursor]?["A"])
    }

    @MainActor
    func testDisableClearsOrphanSubscriptionAndIssueWithoutQuotaEntry() async throws {
        let model = try isolatedViewModel()
        let account = MonitorAccount.make(provider: .antigravity, accountKey: "A", source: .nativeCredential)
        model.monitorAccounts = [account]
        model.providerQuotas = [:]
        model.subscriptionInfos = [.antigravity: ["A": SubscriptionInfo(currentTier: nil, allowedTiers: nil,
            cloudaicompanionProject: nil, gcpManaged: nil, upgradeSubscriptionUri: nil, paidTier: nil)]]
        let key = QuotaAccountID(provider: .antigravity, accountKey: "A")
        model.monitorAccountIssues[key] = MonitorRefreshIssue(message: "fixture", occurredAt: Date())
        await model.setMonitorAccountDisabled(true, accountID: account.id)
        XCTAssertNil(model.subscriptionInfos[.antigravity]?["A"])
        XCTAssertNil(model.monitorAccountIssues[key])
    }

    func testSameIdentityAcrossSourcesUsesOneGroupAndPreservesOwnedPermissions() {
        let owned = MonitorAccount.make(provider: .codex, accountKey: "owned@example.com", source: .quotioKeychain,
                                         credentialReference: "vault", canDelete: true)
        let sources = [CodexMonitorSource(account: owned, accountID: "A", kind: .vault),
                       source("A"), source("A", key: "legacy-A", kind: .legacy("legacy"))]
        let groups = CodexMonitorGroup.resolve(sources, disabledIDs: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.account.id, owned.id)
        XCTAssertEqual(groups.first?.account.accountKey, "legacy-A")
        XCTAssertEqual(groups.first?.account.source, .quotioKeychain)
        XCTAssertEqual(groups.first?.account.credentialReference, "vault")
        XCTAssertEqual(groups.first?.account.canDelete, true)
        XCTAssertEqual(groups.first?.aliases, ["owned@example.com", "same@example.com", "legacy-A", "A"])
    }

    func testSameEmailDifferentIDsStaySeparateAndStableDisableSurvivesTopologyChange() {
        let original = CodexMonitorGroup.resolve([source("A")], disabledIDs: []).first!
        let disabled = Set([original.account.id, original.stableDisabledID])
        let groups = CodexMonitorGroup.resolve([source("A"), source("B")], disabledIDs: disabled)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first { $0.account.accountKey == "A" }?.account.isDisabled, true)
        XCTAssertEqual(groups.first { $0.account.accountKey == "B" }?.account.isDisabled, false)
        XCTAssertFalse(groups.contains { $0.aliases.contains("same@example.com") })
    }

    func testLastGoodCacheMigratesWhenEmailAmbiguityDisappears() {
        let current = CodexMonitorGroup.resolve([source("A")], disabledIDs: [])
        let old = quota()
        let reconciled = CodexMonitorGroup.reconcile(["A": old, "B": quota(20)], groups: current)
        XCTAssertEqual(Set(reconciled.keys), ["same@example.com"])
        XCTAssertEqual(reconciled["same@example.com"]?.lastUpdated, old.lastUpdated)
    }

    func testDisabledIdentityBlocksEverySourceAndScopedAliasBeforeHTTP() async throws {
        let root = try directory()
        let path = root.appendingPathComponent("native.json")
        let data = try native(id: "A")
        try data.write(to: path)
        let token = try jwt(id: "A")
        let legacy = root.appendingPathComponent("codex-legacy.json")
        try JSONSerialization.data(withJSONObject: ["access_token": token, "id_token": token,
                                                    "account_id": "A", "refresh_token": "legacy-refresh"])
            .write(to: legacy)
        let metadata = MonitorMetadataStore(url: root.appendingPathComponent("metadata.json"))
        let memory = CompletionCredentialMemory()
        let vault = MonitorCredentialVault(metadata: metadata, backend: memory.backend)
        let owned = MonitorAccount.make(provider: .codex, accountKey: "owned", source: .quotioKeychain,
                                        credentialReference: "vault", canDelete: true)
        try await vault.save(MonitorOAuthCredential(accessToken: token, refreshToken: "owned-refresh",
                                                    idToken: token, accountID: "A", expiresAt: .distantFuture, extra: [:]), metadata: owned)
        let reader = fetcher(root: root, paths: [path.path], vault: vault, keychain: { _ in (data, "fixture") })
        let initial = await reader.monitorCredentialGroups()
        let group = try XCTUnwrap(initial.first)
        CompletionHTTPProtocol.reset()
        try await metadata.setDisabled(true, accountID: group.stableDisabledID)
        let all = await reader.fetchMonitorQuotas()
        XCTAssertTrue(all.isEmpty)
        for alias in group.aliases {
            let scoped = await reader.fetchMonitorQuota(forAccountKey: alias)
            XCTAssertNil(scoped)
        }
        XCTAssertEqual(CompletionHTTPProtocol.requests.count, 0)
        XCTAssertEqual(try Data(contentsOf: path), data)
        // 启用从磁盘重读所有来源标记，随后可正常得到唯一额度行。
        let discovery = MonitorAccountDiscovery(vault: vault, metadata: metadata, codexFetcher: reader)
        await discovery.setDisabled(false, accountID: group.account.id)
        let refreshed = await reader.fetchMonitorQuotas()
        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(CompletionHTTPProtocol.requests.filter { $0.url?.path.hasSuffix("/usage") == true }.count, 1)
    }

    func testUnreadableOwnedCredentialKeepsMetadataPermissionsAndLastGoodCache() async throws {
        let root = try directory()
        let account = MonitorAccount.make(provider: .codex, accountKey: "locked", source: .quotioKeychain,
                                          credentialReference: "vault", canDelete: true)
        let reader = fetcher(root: root, vault: CompletionEmptyVault(metadata: [account]))
        let groups = await reader.monitorCredentialGroups()
        XCTAssertEqual(groups.first?.account, account)
        let reconciled = CodexMonitorGroup.reconcile(["locked": quota()], groups: groups)
        XCTAssertNotNil(reconciled["locked"])
        CompletionHTTPProtocol.reset()
        let fetched = await reader.fetchMonitorQuotas()
        XCTAssertTrue(fetched.isEmpty)
        XCTAssertTrue(CompletionHTTPProtocol.requests.isEmpty)
    }

    func testKeychainSwitchDuringUnauthorizedRetryNeverRequestsDisabledOtherAccount() async throws {
        let root = try directory()
        let record = CompletionDataBox(try native(id: "A"))
        let other = try native(id: "B")
        // A 的兼容来源让 A group 在 Keychain 换号后仍存在，以暴露错误借用 B 的路径。
        let token = try jwt(id: "A")
        try JSONSerialization.data(withJSONObject: ["access_token": token, "id_token": token, "account_id": "A"])
            .write(to: root.appendingPathComponent("codex-A.json"))
        let metadata = MonitorMetadataStore(url: root.appendingPathComponent("metadata.json"))
        try await metadata.setDisabled(true, accountID: CodexMonitorGroup.disabledID(for: "id:B"))
        CompletionHTTPProtocol.reset { request in
            if request.url?.path.hasSuffix("/usage") == true {
                record.write(other)
                return 401
            }
            return 404
        }
        let reader = fetcher(root: root, keychain: { _ in (record.read(), "fixture") })
        _ = await reader.fetchMonitorQuota(forAccountKey: "A")
        XCTAssertFalse(CompletionHTTPProtocol.requests.contains { $0.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "B" })
        XCTAssertFalse(CompletionHTTPProtocol.requests.contains { $0.url?.path.contains("token") == true })
    }

    func testKeychainReplacementBetweenValidationAndReadCannotBorrowOtherAccount() async throws {
        let root = try directory()
        let record = CompletionSwitchingRecord(first: try native(id: "A"), subsequent: try native(id: "B"))
        let token = try jwt(id: "A")
        try JSONSerialization.data(withJSONObject: ["access_token": token, "id_token": token, "account_id": "A"])
            .write(to: root.appendingPathComponent("codex-A.json"))
        let metadata = MonitorMetadataStore(url: root.appendingPathComponent("metadata.json"))
        try await metadata.setDisabled(true, accountID: CodexMonitorGroup.disabledID(for: "id:B"))
        CompletionHTTPProtocol.reset()
        let reader = fetcher(root: root, keychain: { _ in (record.read(), "fixture") })
        let result = await reader.fetchMonitorQuota(forAccountKey: "A")
        XCTAssertNotNil(result)
        XCTAssertFalse(CompletionHTTPProtocol.requests.contains { $0.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "B" })
    }

    func testIdentityBoundSnapshotRejectsReusedEmailAndMigratesRemovedLegacyAlias() throws {
        var old = quota()
        old.monitorAccountIdentity = "id:A"
        // 编解码后身份仍存在：跨重启也不能把 A 的旧邮箱额度移给 B。
        let snapshot = try JSONDecoder().decode(ProviderQuotaData.self, from: JSONEncoder().encode(old))
        let other = CodexMonitorGroup.resolve([source("B")], disabledIDs: [])
        XCTAssertTrue(CodexMonitorGroup.reconcile(["same@example.com": snapshot], groups: other).isEmpty)
        let locked = CodexMonitorSource(account: .make(provider: .codex, accountKey: "unrelated-locked", source: .quotioKeychain,
                                                       canDelete: true), accountID: nil, kind: .vault, isReadable: false)
        let partiallyReadable = CodexMonitorGroup.resolve([source("B"), locked], disabledIDs: [])
        XCTAssertTrue(CodexMonitorGroup.reconcile(["same@example.com": snapshot], groups: partiallyReadable).isEmpty)
        let same = CodexMonitorGroup.resolve([source("A")], disabledIDs: [])
        let migrated = CodexMonitorGroup.reconcile(["removed-legacy-file": snapshot], groups: same)
        XCTAssertEqual(migrated["same@example.com"]?.lastUpdated, old.lastUpdated)
    }

    func testSuccessfulResponseIsDiscardedWhenSameEmailChangesIdentity() async throws {
        let root = try directory()
        let a = try native(id: "A"), b = try native(id: "B")
        let record = CompletionDataBox(a)
        let reader = fetcher(root: root, keychain: { _ in (record.read(), "fixture") })
        CompletionHTTPProtocol.reset { request in
            if request.url?.path.hasSuffix("/usage") == true { record.write(b); return 200 }
            return 404
        }
        let scoped = await reader.fetchMonitorQuota(forAccountKey: "same@example.com")
        XCTAssertNil(scoped)
        record.write(a)
        let all = await reader.fetchMonitorQuotas()
        XCTAssertTrue(all.isEmpty)
    }

    func testEnableDuringEmailAmbiguityClearsLegacyDisableWhenSiblingDisappears() async throws {
        let root = try directory()
        let pathA = root.appendingPathComponent("A.json"), pathB = root.appendingPathComponent("B.json")
        try native(id: "A").write(to: pathA)
        let metadata = MonitorMetadataStore(url: root.appendingPathComponent("metadata.json"))
        let reader = fetcher(root: root, paths: [pathA.path, pathB.path])
        let discovery = MonitorAccountDiscovery(vault: CompletionEmptyVault(), metadata: metadata, codexFetcher: reader)
        let original = await reader.monitorCredentialGroups().first!
        await discovery.setDisabled(true, accountID: original.account.id)
        // 同时模拟旧版本留下的邮箱 ID，启用时也必须迁移清理。
        try await metadata.setDisabled(true, accountID: original.account.id)
        try native(id: "B").write(to: pathB)
        let groups = await reader.monitorCredentialGroups()
        let a = try XCTUnwrap(groups.first { $0.account.accountKey == "A" })
        XCTAssertTrue(a.account.isDisabled)
        await discovery.setDisabled(false, accountID: a.account.id)
        try FileManager.default.removeItem(at: pathB)
        let final = await reader.monitorCredentialGroups()
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final.first?.account.isDisabled, false)
    }

    /// 两个不同账号的用户命令都应完成，只有同账号后来的命令可以使先前命令失效。
    func testIndependentAccountMutationsBothPersistButSameAccountKeepsLatest() async throws {
        let root = try directory()
        let metadata = MonitorMetadataStore(url: root.appendingPathComponent("metadata.json"))
        let snapshots = MonitorSnapshotStore(url: root.appendingPathComponent("snapshot.json"))
        let state = MonitorStateRevision()
        await snapshots.store([.cursor: ["A": quota(), "B": quota()]])
        let a = state.advance(accountID: "A"), b = state.advance(accountID: "B")
        try await metadata.setDisabled(true, accountIDs: ["A"], revision: a, state: state, mutationAccountID: "A")
        try await metadata.setDisabled(true, accountIDs: ["B"], revision: b, state: state, mutationAccountID: "B")
        await snapshots.removeAccount(provider: .cursor, accountKey: "A", revision: a, state: state, mutationAccountID: "A")
        await snapshots.removeAccount(provider: .cursor, accountKey: "B", revision: b, state: state, mutationAccountID: "B")
        let disabled = await metadata.disabledAccountIDs()
        let removed = await snapshots.load()
        XCTAssertEqual(disabled, ["A", "B"])
        XCTAssertTrue(removed.isEmpty)
        let readd = state.advance(accountID: "A")
        try await metadata.setDisabled(false, accountIDs: ["A"], revision: readd, state: state, mutationAccountID: "A")
        await snapshots.store([.cursor: ["A": quota(90)]], revision: readd, state: state)
        try await metadata.setDisabled(true, accountIDs: ["A"], revision: a, state: state, mutationAccountID: "A")
        await snapshots.removeAccount(provider: .cursor, accountKey: "A", revision: a, state: state, mutationAccountID: "A")
        let enabled = await metadata.disabledAccountIDs(), current = await snapshots.load()
        XCTAssertEqual(enabled, ["B"])
        XCTAssertEqual(current[.cursor]?["A"]?.models.first?.percentage, 90)
    }

    func testNativeDisableCanBeClearedAfterAddingOwnedSource() async throws {
        let root = try directory()
        let path = root.appendingPathComponent("native.json")
        try native(id: "A").write(to: path)
        let metadata = MonitorMetadataStore(url: root.appendingPathComponent("metadata.json"))
        let memory = CompletionCredentialMemory()
        let vault = MonitorCredentialVault(metadata: metadata, backend: memory.backend)
        let reader = fetcher(root: root, paths: [path.path], vault: vault)
        let discovery = MonitorAccountDiscovery(vault: vault, metadata: metadata, codexFetcher: reader)
        let nativeGroup = await reader.monitorCredentialGroups().first!
        await discovery.setDisabled(true, accountID: nativeGroup.account.id)
        let token = try jwt(id: "A")
        let owned = MonitorAccount.make(provider: .codex, accountKey: "owned", source: .quotioKeychain, canDelete: true)
        try await vault.save(MonitorOAuthCredential(accessToken: token, refreshToken: "fixture", idToken: token,
                                                    accountID: "A", expiresAt: .distantFuture, extra: [:]), metadata: owned)
        let withOwned = await reader.monitorCredentialGroups().first!
        XCTAssertTrue(withOwned.account.isDisabled)
        await discovery.setDisabled(false, accountID: withOwned.account.id)
        let enabled = await reader.monitorCredentialGroups().first!
        XCTAssertFalse(enabled.account.isDisabled)
    }

    func testCoordinatorFiltersRemovedIdentityButKeepsFailedLiveAccount() async {
        let coordinator = MonitorRefreshCoordinator()
        let old = quota(20), fresh = quota(80)
        let result = await coordinator.refresh(provider: .codex, force: true,
                                               previous: ["removed": old, "failed": old, "success": old],
                                               credentialAccountKeys: ["failed", "success"]) { ["success": fresh] }
        XCTAssertNil(result["removed"])
        XCTAssertEqual(result["failed"]?.lastUpdated, old.lastUpdated)
        XCTAssertEqual(result["success"]?.lastUpdated, fresh.lastUpdated)
        let issues = await coordinator.currentIssues()
        XCTAssertNotNil(issues[.codex])
    }

    func testAllSharedWaitersRejectDeletedGenerationAndAllowNewRefresh() async {
        let coordinator = MonitorRefreshCoordinator()
        let gate = CompletionGate()
        let bothWaiting = expectation(description: "两个等待者均已进入")
        bothWaiting.expectedFulfillmentCount = 2
        await coordinator.setWaiterHookForTesting { bothWaiting.fulfill() }
        let fresh = quota()
        let first = Task { await coordinator.refresh(provider: .codex, force: true, previous: [:]) {
            await gate.wait(); return ["deleted": fresh]
        } }
        let second = Task { await coordinator.refresh(provider: .codex, force: true, previous: [:]) {
            await gate.wait(); return ["deleted": fresh]
        } }
        await fulfillment(of: [bothWaiting], timeout: 5)
        coordinator.revision.advance()
        await coordinator.setWaiterHookForTesting(nil)
        let readded = await coordinator.refresh(provider: .codex, force: true, previous: [:]) { ["readded": fresh] }
        await gate.open()
        let a = await first.value, b = await second.value
        XCTAssertTrue(a.isEmpty)
        XCTAssertTrue(b.isEmpty)
        XCTAssertNotNil(readded["readded"])
        let issues = await coordinator.currentIssues()
        XCTAssertTrue(issues.isEmpty)
    }

    func testOldSnapshotCannotOverwriteDeletionOrExplicitReadd() async throws {
        let root = try directory()
        let store = MonitorSnapshotStore(url: root.appendingPathComponent("snapshot.json"))
        let state = MonitorStateRevision()
        let oldRevision = state.current
        let old = quota(10), new = quota(90)
        await store.store([.codex: ["A": old]], revision: oldRevision, state: state)
        let deletion = state.advance()
        await store.removeAccount(provider: .codex, accountKey: "A", revision: deletion, state: state)
        await store.store([.codex: ["A": old]], revision: oldRevision, state: state)
        let deleted = await store.load()
        XCTAssertNil(deleted[.codex]?["A"])
        let readd = state.advance()
        await store.store([.codex: ["A": new]], revision: readd, state: state)
        await store.store([.codex: ["A": old]], revision: oldRevision, state: state)
        let final = await store.load()
        XCTAssertEqual(final[.codex]?["A"]?.lastUpdated, new.lastUpdated)
    }

    func testRefreshSaveCannotRecreateDeletedCredentialOrOverwriteReauthorization() async throws {
        let root = try directory()
        let metadata = MonitorMetadataStore(url: root.appendingPathComponent("metadata.json"))
        let memory = CompletionCredentialMemory()
        let vault = MonitorCredentialVault(metadata: metadata, backend: memory.backend)
        let account = MonitorAccount.make(provider: .codex, accountKey: "A", source: .quotioKeychain, canDelete: true)
        let original = MonitorOAuthCredential(accessToken: "old", refreshToken: "old-refresh", extra: [:])
        var refreshed = original; refreshed.accessToken = "refreshed"
        try await vault.save(original, metadata: account)
        _ = await vault.credential(for: account.id)
        await vault.delete(accountID: account.id)
        do { try await vault.saveRefreshed(refreshed, replacing: original, accountID: account.id); XCTFail("旧刷新不得创建条目") }
        catch { }
        let deleted = await vault.credential(for: account.id)
        let deletedMetadata = await metadata.accounts()
        XCTAssertNil(deleted)
        XCTAssertTrue(deletedMetadata.isEmpty)
        var readded = original; readded.accessToken = "user-readded"; readded.refreshToken = "new-refresh"
        try await vault.save(readded, metadata: account)
        do { try await vault.saveRefreshed(refreshed, replacing: original, accountID: account.id); XCTFail("旧刷新不得覆盖重授权") }
        catch { }
        let current = await vault.credential(for: account.id)
        XCTAssertEqual(current, readded)
        var next = readded; next.accessToken = "valid-refresh"
        try await vault.saveRefreshed(next, replacing: readded, accountID: account.id)
        let saved = await vault.credential(for: account.id)
        XCTAssertEqual(saved, next)
    }
}

private struct CompletionEmptyVault: MonitorCredentialStore {
    var metadata: [MonitorAccount] = []
    func accounts() async -> [MonitorAccount] { metadata }
    func credential(for accountID: String) async -> MonitorOAuthCredential? { nil }
    func reloadLatest(accountID: String) async -> MonitorOAuthCredential? { nil }
    func save(_ credential: MonitorOAuthCredential, metadata: MonitorAccount) async throws { }
    func delete(accountID: String) async { }
}

private actor CompletionGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !isOpen { await withCheckedContinuation { waiting.append($0) } } }
    func open() { isOpen = true; waiting.forEach { $0.resume() }; waiting.removeAll() }
}

/// 同步内存 CAS 精确模拟生产后端，不需要系统钥匙串权限。
private final class CompletionCredentialMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var backend: MonitorCredentialVault.Backend {
        .init(read: { key in self.lock.withLock { self.values[key] } },
              save: { data, key in self.lock.withLock { self.values[key] = data; return true } },
              compareAndSwap: { data, key, expected in self.lock.withLock {
                  guard let old = self.values[key], MonitorIdentity.fingerprint(old.base64EncodedString()) == expected else { return false }
                  self.values[key] = data; return true
              } }, delete: { key in self.lock.withLock { _ = self.values.removeValue(forKey: key) } })
    }
}

private final class CompletionDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data
    init(_ data: Data) { self.data = data }
    func read() -> Data { lock.withLock { data } }
    func write(_ value: Data) { lock.withLock { data = value } }
}

/// 第三次读取发生在来源校验后，由具体 Keychain helper 执行，精确模拟这个竞态窗口。
private final class CompletionSwitchingRecord: @unchecked Sendable {
    private let lock = NSLock()
    private let first: Data
    private let subsequent: Data
    private var reads = 0
    init(first: Data, subsequent: Data) { self.first = first; self.subsequent = subsequent }
    func read() -> Data { lock.withLock { reads += 1; return reads <= 2 ? first : subsequent } }
}

private final class CompletionHTTPProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var responder: (@Sendable (URLRequest) -> Int)?
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset(_ response: (@Sendable (URLRequest) -> Int)? = nil) {
        lock.withLock { recorded = []; responder = response }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.lock.withLock { Self.recorded.append(request); return Self.responder }
        let status = response?(request) ?? (request.url?.path.hasSuffix("/usage") == true ? 200 : 404)
        let body = Data(#"{"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_after_seconds":100,"reset_at":4102444800}}}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
