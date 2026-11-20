import AppKit
import SwiftUI
import XCTest
@testable import QuotioPlus

/// 菜单栏和融合账号页的定向回归：所有目录、额度、密钥均是离线夹具。
/// 偏好注入独立 suite，后台服务关闭；不读取用户凭据、不启停真实 CPA。
@MainActor
final class MenuBarAccountSyncTests: XCTestCase {
    private struct Fixture {
        let defaults: UserDefaults
        let mode: OperatingModeManager
        let settings: MenuBarSettingsManager
        let refresh: RefreshSettingsManager
        let vm: QuotaViewModel
    }

    private func fixture(running: Bool = false, directory: [AuthFile] = []) throws -> Fixture {
        let suite = "quotio-menubar-sync-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let manager = OperatingModeManager(defaults: defaults)
        let settings = MenuBarSettingsManager(defaults: defaults)
        let refresh = RefreshSettingsManager(defaults: defaults)
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vm = QuotaViewModel(directAuthService: DirectAuthFileService(authDirectory: sandbox),
            startsBackgroundServices: false, modeManager: manager, menuBarSettings: settings, refreshSettings: refresh,
            accountSnapshotDefaults: defaults)
        vm.customProvidersForTesting = []
        let proxy = vm.proxyManager, originalRunning = proxy.proxyStatus.running, originalSession = proxy.runtimeSessionID
        proxy.setRuntimeStateForTesting(running: running, sessionID: UUID())
        if running {
            let body = String(decoding: try JSONEncoder().encode(AuthFilesResponse(files: directory)), as: UTF8.self)
            let state = LifecycleHTTPState { request, _ in
                if request.url?.path.hasSuffix("/credentials") == true { return .reply(body) }
                if request.url?.path.hasSuffix("/api-keys") == true { return .reply("[]") }
                return .fail(.unsupportedURL)
            }
            let host = UUID().uuidString.lowercased() + ".invalid"
            LifecycleHTTPProtocol.register(state, host: host)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LifecycleHTTPProtocol.self]
            let client = ManagementAPIClient(baseURL: "https://" + host + ManagementAPIClient.managementPath,
                                             authKey: "fixture", configuration: configuration)
            vm.setAuthImportClientForTesting(client)
            addTeardownBlock {
                await client.invalidate()
                LifecycleHTTPProtocol.remove(host: host)
            }
        }
        addTeardownBlock { @MainActor in
            vm.stopQuotaAutoRefresh()
            proxy.setRuntimeStateForTesting(running: originalRunning, sessionID: originalSession)
            defaults.removePersistentDomain(forName: suite)
        }
        return Fixture(defaults: defaults, mode: manager, settings: settings, refresh: refresh, vm: vm)
    }

    private func file(_ name: String = "claude-work.json", index: String = "a", provider: String = "claude",
                      path: String? = nil, account: String? = nil) throws -> AuthFile {
        var json: [String: Any] = ["id": index, "name": name, "provider": provider,
            "auth_index": index, "email": "work@example.com", "status": "ready"]
        if let path { json["path"] = path }
        if let account { json["account"] = account }
        return try JSONDecoder().decode(AuthFile.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func direct(_ name: String = "claude-work.json", provider: AIProvider = .claude,
                        path: String? = nil, login: String? = nil, legacy: [String] = []) -> DirectAuthFile {
        let path = path ?? "/isolated/" + name
        return DirectAuthFile(id: path, provider: provider, email: "work@example.com", login: login,
            expired: nil, accountType: nil, filePath: path, source: .cliProxyApi, filename: name,
            legacyIdentityKeys: legacy)
    }

    private func quota(_ value: Double, updated: TimeInterval = Date().timeIntervalSince1970) -> ProviderQuotaData {
        ProviderQuotaData(models: [ModelQuota(name: "fixture", percentage: value, resetTime: "")],
            lastUpdated: Date(timeIntervalSince1970: updated), accountDisplayName: "work@example.com")
    }

    private func pin(_ key: String, provider: AIProvider = .claude) -> MenuBarQuotaItem {
        MenuBarQuotaItem(provider: provider.rawValue, accountKey: key)
    }

    func testMenuCatalogOnlyUsesCPAOrExplicitIdentities() throws {
        let runtime = try file(path: "/isolated/claude-work.json")
        let f = try fixture()
        f.vm.authFiles = [runtime]
        f.vm.directAuthFiles = [direct()]
        f.vm.providerQuotas = [.claude: ["cached-only": quota(80)], .cursor: ["explicit-ide": quota(55)]]
        f.vm.syncMenuBarSelection()
        XCTAssertEqual(Set(f.settings.selectedItems), [pin(runtime.quotaLookupKey), pin("explicit-ide", provider: .cursor)])
    }

    func testResolverRejectsSameEmailGuessEvenWithOnlyOneSuccessfulQuota() throws {
        let a = try file("team-a.json", index: "a"), b = try file("team-b.json", index: "b")
        let quotas = [AIProvider.claude: [a.quotaLookupKey: quota(70)]]
        XCTAssertNil(MenuBarAccountCatalog.resolve(pin("work@example.com"), authFiles: [a, b], quotas: quotas))
        XCTAssertEqual(MenuBarAccountCatalog.resolve(pin(a.quotaLookupKey), authFiles: [a, b], quotas: quotas)?.models.first?.percentage, 70)
    }

    func testResolverUsesConfirmedAliasButExactCPASnapshotWins() throws {
        let runtime = try file(path: "/isolated/claude-work.json")
        let quotas = [AIProvider.claude: [runtime.quotaLookupKey: quota(30), "work@example.com": quota(90, updated: 50)]]
        XCTAssertEqual(MenuBarAccountCatalog.resolve(pin("work@example.com"), authFiles: [runtime], quotas: quotas)?.models.first?.percentage, 30)
    }

    func testStoppedProxyKeepsVerifiedCPAIdentityAndIgnoresUnverifiedCopilotLogin() throws {
        let f = try fixture()
        let file = try file("github-copilot-canonical.json", provider: "github-copilot", account: "canonical")
        f.vm.authFiles = [file]
        f.vm.directAuthFiles = [direct("github-copilot-unrelated.json", provider: .copilot, login: "unrelated")]
        f.vm.providerQuotas = [.copilot: [file.quotaLookupKey: quota(65)]]
        f.settings.toggleItem(MenuBarQuotaItem(provider: "copilot", accountKey: "canonical"))
        f.vm.syncMenuBarSelection()
        XCTAssertEqual(f.settings.selectedItems, [pin(file.quotaLookupKey, provider: .copilot)])
        XCTAssertTrue(f.settings.hasUserModifiedMenuBar)
        XCTAssertNil(MenuBarAccountCatalog.aliases(authFiles: [file])[.copilot]?["unrelated"])
    }

    func testLoadedOldCopilotProviderPinsDeduplicateWithoutChangingOrder() throws {
        let f = try fixture()
        let canonical = pin("login", provider: .copilot)
        f.settings.selectedItems = [MenuBarQuotaItem(provider: "copilot", accountKey: "login"), canonical, pin("other")]
        let loaded = MenuBarSettingsManager(defaults: f.defaults)
        XCTAssertEqual(loaded.selectedItems, [canonical, pin("other")])
    }

    func testStoppedProxyMigratesUniqueCodexEmailButRejectsSharedSubscriptionEmail() throws {
        let plus = try file("codex-work-plus.json", index: "plus", provider: "codex")
        let team = try file("codex-work-team.json", index: "team", provider: "codex")
        let unique = MenuBarAccountCatalog.aliases(authFiles: [plus])
        XCTAssertEqual(unique[.codex]?["work@example.com"], plus.quotaLookupKey)
        let ambiguous = MenuBarAccountCatalog.aliases(authFiles: [plus, team])
        XCTAssertNil(ambiguous[.codex]?["work@example.com"], "同邮箱多套餐不能擅自指定固定归属")
    }

    private func glm() -> CustomProvider {
        CustomProvider(name: "离线多密钥", type: .glmCompatibility,
            apiKeys: [CustomAPIKeyEntry(apiKey: "fixture-a"), CustomAPIKeyEntry(apiKey: "fixture-b")])
    }

    private func keys(_ provider: CustomProvider) -> [String] {
        provider.apiKeys.map { GLMQuotaFetcher.quotaAccountKey(providerID: provider.id, apiKeyID: $0.id) }
    }

    func testGLMSecondKeyCanBePinnedAndRemovedAtLimit() throws {
        let f = try fixture(), provider = glm(), keys = keys(provider)
        let rows = AccountPageData.groupedAccounts(hasCurrentCPAAccountDirectory: false, authFiles: [],
            importedIDEAccountKeys: [:], customProviders: [provider], warpTokens: [])[.glm] ?? []
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.menuBarItems, keys.map { pin($0, provider: .glm) })
        f.settings.menuBarMaxItems = 1
        f.settings.toggleItem(row.menuBarItems[1])
        f.vm.customProvidersForTesting = [provider]
        f.vm.syncMenuBarSelection()
        XCTAssertTrue(f.settings.isSelected(row.menuBarItems[1]))
        XCTAssertFalse(f.settings.isSelected(row.menuBarItems[0]))
        XCTAssertTrue(f.settings.isAtMaxItems)
        f.settings.toggleItem(row.menuBarItems[1])
        XCTAssertTrue(f.settings.selectedItems.isEmpty, "达到上限后取消任何 Key 仍应可用")
    }

    func testLegacyGLMNameMigratesOnlyForUniqueSingleKeyConnection() throws {
        let f = try fixture()
        var provider = glm()
        provider.apiKeys.removeLast()
        let key = keys(provider)[0]
        f.vm.customProvidersForTesting = [provider]
        f.vm.providerQuotas = [.glm: [provider.name: quota(60)]]
        f.settings.toggleItem(pin(provider.name, provider: .glm))
        f.vm.syncMenuBarSelection()
        XCTAssertEqual(f.settings.selectedItems, [pin(key, provider: .glm)])
        XCTAssertEqual(f.vm.providerQuotas[.glm]?[key]?.models.first?.percentage, 60)
        XCTAssertNil(f.vm.providerQuotas[.glm]?[provider.name])
        let multi = glm()
        XCTAssertNil(MenuBarAccountCatalog.aliases(authFiles: [], customProviders: [multi])[.glm]?[multi.name])
    }

    func testManualRefreshUsesSharedPlanAndCoalescesDuplicateClicks() async throws {
        let f = try fixture(running: true)
        var steps: [AccountRefreshStep] = [], resume: CheckedContinuation<Void, Never>?
        f.vm.accountRefreshStepHookForTesting = { step in
            steps.append(step)
            if steps.count == 1 { await withCheckedContinuation { resume = $0 } }
        }
        let first = Task { await f.vm.manualRefresh() }
        while resume == nil { await Task.yield() }
        XCTAssertTrue(f.vm.manualAccountRefreshState.isRefreshing)
        await f.vm.manualRefresh()
        XCTAssertEqual(steps.count, 1, "菜单与账号页重复点击不能发两批请求")
        resume?.resume()
        await first.value
        XCTAssertFalse(f.vm.manualAccountRefreshState.isRefreshing)
        XCTAssertEqual(steps, AccountRefreshStep.plan(proxyRunning: f.vm.proxyManager.proxyStatus.running))
        XCTAssertEqual(AccountRefreshStep.plan(proxyRunning: true), [.cpaDirectory, .cpaQuotas])
        XCTAssertEqual(AccountRefreshStep.plan(proxyRunning: false), [])
    }

    func testModeChangeStopsRemainingManualRefreshSteps() async throws {
        let f = try fixture(running: true)
        var steps: [AccountRefreshStep] = [], resume: CheckedContinuation<Void, Never>?
        f.vm.accountRefreshStepHookForTesting = { step in
            steps.append(step)
            await withCheckedContinuation { resume = $0 }
        }
        let first = Task { await f.vm.manualRefresh() }
        while resume == nil { await Task.yield() }
        f.mode.setMode(.monitor)
        resume?.resume()
        await first.value
        XCTAssertEqual(steps.count, 1)
        XCTAssertFalse(f.vm.manualAccountRefreshState.isRefreshing)
    }

    func testScopedWaitCannotRefreshNewModeAfterOldSlotReleases() async throws {
        let f = try fixture(running: true)
        var reads = 0
        f.vm.localQuotaFetchHookForTesting = { _ in reads += 1; return [:] }
        f.vm.customProvidersForTesting = [glm()]
        XCTAssertTrue(f.vm.beginScopedRefresh(provider: .glm))
        let waiting = Task { await f.vm.refreshQuota(for: .glm, waitForAvailability: true) }
        // 先让等待者进入真实预约循环，再跨模式；不能让它在切换后才采样上下文。
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        f.mode.setMode(.monitor)
        await waiting.value
        XCTAssertEqual(f.vm.refreshingProviders, [.glm])
        f.vm.endScopedRefresh(provider: .glm)
        XCTAssertEqual(reads, 0)
        XCTAssertNil(f.vm.providerQuotas[.glm])
        XCTAssertTrue(f.vm.refreshingProviders.isEmpty, "拒绝旧来源之后也必须释放已预约槽位")
    }

    func testGLMDeletionRejectsLateResultAndPreservesOtherConnection() async throws {
        let f = try fixture(running: true), provider = glm(), keys = keys(provider)
        let retained = glm(), retainedKey = self.keys(retained)[0]
        f.vm.customProvidersForTesting = [provider, retained]
        f.vm.providerQuotas = [.glm: [keys[0]: quota(10), keys[1]: quota(20), retainedKey: quota(90)]]
        f.settings.toggleItem(pin(keys[1], provider: .glm))
        f.settings.toggleItem(pin(retainedKey, provider: .glm))
        var resume: CheckedContinuation<Void, Never>?
        f.vm.localQuotaFetchHookForTesting = { _ in
            await withCheckedContinuation { resume = $0 }
            return [keys[0]: self.quota(5), keys[1]: self.quota(5)]
        }
        let old = Task { await f.vm.refreshQuota(for: .glm) }
        while resume == nil { await Task.yield() }
        f.vm.prepareCustomProviderQuotaMutation(previous: provider, replacement: nil, legacyNameIsUnique: true)
        resume?.resume()
        await old.value
        XCTAssertEqual(Set(f.vm.providerQuotas[.glm]?.keys ?? Dictionary<String, ProviderQuotaData>().keys), [retainedKey])
        XCTAssertEqual(f.settings.selectedItems, [pin(retainedKey, provider: .glm)])
        XCTAssertTrue(f.settings.hasUserModifiedMenuBar)
    }

    func testReplacingOneGLMKeyKeepsUnchangedKeyQuotaAndSelection() throws {
        let f = try fixture(), provider = glm(), keys = keys(provider)
        f.vm.providerQuotas = [.glm: [keys[0]: quota(10), keys[1]: quota(80)]]
        f.settings.toggleItem(pin(keys[0], provider: .glm))
        f.settings.toggleItem(pin(keys[1], provider: .glm))
        var edited = provider
        edited.apiKeys[0].apiKey = "replacement-fixture"
        f.vm.prepareCustomProviderQuotaMutation(previous: provider, replacement: edited)
        XCTAssertNil(f.vm.providerQuotas[.glm]?[keys[0]])
        XCTAssertEqual(f.vm.providerQuotas[.glm]?[keys[1]]?.models.first?.percentage, 80)
        XCTAssertEqual(f.settings.selectedItems, keys.map { pin($0, provider: .glm) }, "原槽位换密钥保留用户选择，旧额度需清理")
        XCTAssertEqual(edited.apiKeys.map(\.id), provider.apiKeys.map(\.id))
    }

    func testClinePassCredentialEditClearsOldQuotaButKeepsConfiguredPin() throws {
        let f = try fixture()
        let previous = CustomProvider(name: "离线 ClinePass", type: .clinePass,
            apiKeys: [CustomAPIKeyEntry(apiKey: "fixture-old")])
        var edited = previous
        edited.apiKeys[0].apiKey = "fixture-new"
        f.vm.providerQuotas = [.clinePass: [previous.name: quota(70)]]
        f.settings.toggleItem(pin(previous.name, provider: .clinePass))
        f.vm.prepareCustomProviderQuotaMutation(previous: previous, replacement: edited, legacyNameIsUnique: true)
        f.vm.customProvidersForTesting = [edited]
        f.vm.syncMenuBarSelection()
        XCTAssertNil(f.vm.providerQuotas[.clinePass])
        XCTAssertEqual(f.settings.selectedItems, [pin(previous.name, provider: .clinePass)])
    }

    func testCPAFileDeletionClearsAllIndexesAndOnlyMatchingDiskSnapshot() throws {
        let f = try fixture()
        let a = try file(index: "a", path: "/local/claude-work.json")
        let b = try file(index: "b", path: "/local/claude-work.json")
        f.vm.authFiles = [a, b]
        f.vm.directAuthFiles = [direct(path: "/local/claude-work.json"), direct(path: "/other/claude-work.json")]
        f.vm.providerQuotas = [.claude: [a.quotaLookupKey: quota(10), b.quotaLookupKey: quota(20)]]
        f.settings.toggleItem(pin(a.quotaLookupKey))
        f.settings.toggleItem(pin(b.quotaLookupKey))
        f.vm.commitAuthFileDeletion(a)
        XCTAssertTrue(f.vm.authFiles.isEmpty)
        XCTAssertEqual(f.vm.directAuthFiles.map(\.filePath), ["/other/claude-work.json"])
        XCTAssertNil(f.vm.providerQuotas[.claude])
        XCTAssertTrue(f.settings.selectedItems.isEmpty)
    }

    func testDeletedCPAAccountCannotBeReintroducedByLateDirectoryRead() async throws {
        let f = try fixture(), deleted = try file()
        f.vm.authFiles = [deleted]
        var resume: CheckedContinuation<Void, Never>?
        let old = Task {
            try await f.vm.refreshAuthDirectoryForTesting {
                await withCheckedContinuation { resume = $0 }
                return [deleted]
            }
        }
        while resume == nil { await Task.yield() }
        f.vm.commitAuthFileDeletion(deleted)
        let published = try await f.vm.refreshAuthDirectoryForTesting { [] }
        XCTAssertTrue(published)
        resume?.resume()
        let latePublished = try await old.value
        XCTAssertFalse(latePublished)
        XCTAssertTrue(f.vm.authFiles.isEmpty)
    }

    func testSnapshotSurvivesRestartWithoutSensitiveFieldsAndPersistsDeletion() async throws {
        let f = try fixture()
        let originalTime = Date(timeIntervalSince1970: 1_000)
        let file = AuthFile(id: "fixture", name: "claude-fixture.json", provider: "claude",
            statusMessage: "secret-response-body", path: "/fixture/private/path", email: "fixture@example.invalid",
            authIndex: "fixture-opaque-index", quotaMetadata: AuthFileQuotaMetadata(projectID: "secret-project"))
        let published = try await f.vm.refreshAuthDirectoryForTesting { [file] }
        XCTAssertTrue(published)
        f.vm.providerQuotas[.claude] = [file.quotaLookupKey: quota(70, updated: originalTime.timeIntervalSince1970),
                                       "orphan": quota(30)]
        f.vm.recordAccountQuotaSuccess(at: originalTime)

        let json = try XCTUnwrap(f.defaults.data(forKey: CPAAccountQuotaSnapshot.preferenceKey))
        let text = String(decoding: json, as: UTF8.self)
        for excluded in ["secret-response-body", "/fixture/private/path", "secret-project", "orphan"] {
            XCTAssertFalse(text.contains(excluded))
        }
        func restore() -> QuotaViewModel {
            QuotaViewModel(startsBackgroundServices: false, modeManager: f.mode, menuBarSettings: f.settings,
                           refreshSettings: f.refresh, accountSnapshotDefaults: f.defaults)
        }
        let restored = restore()
        XCTAssertEqual(restored.authFiles.map(\.quotaLookupKey), [file.quotaLookupKey])
        XCTAssertEqual(restored.providerQuotas[.claude]?[file.quotaLookupKey]?.lastUpdated, originalTime)
        XCTAssertEqual(restored.lastQuotaRefreshTime, originalTime)
        XCTAssertFalse(restored.hasCurrentCPAAccountDirectory)
        restored.commitAuthFileDeletion(file)
        XCTAssertTrue(restore().authFiles.isEmpty)
        XCTAssertNil(restore().providerQuotas[.claude])
    }

    func testStoppedModeDoesNotScheduleQuotaTimerAtAnyCadence() throws {
        let f = try fixture()
        for cadence in [RefreshCadence.fiveMinutes, .manual] {
            f.refresh.refreshCadence = cadence
            f.vm.restartAutoRefresh()
            XCTAssertFalse(f.vm.isQuotaAutoRefreshScheduledForTesting)
        }
    }

    func testNativeMultiKeyAndSingleKeyControlsRenderWithIsolatedSelection() throws {
        let f = try fixture(), provider = glm(), keys = keys(provider)
        f.vm.providerQuotas = [.glm: [keys[0]: quota(30), keys[1]: quota(70)]]
        f.settings.toggleItem(pin(keys[1], provider: .glm))
        let groups = AccountPageData.groupedAccounts(hasCurrentCPAAccountDirectory: false, authFiles: [],
            importedIDEAccountKeys: [:], customProviders: [provider],
            warpTokens: [])
        var renderedGroups = groups
        renderedGroups[.claude] = [AccountRowData.from(provider: .claude, accountKey: "single-fixture")]
        let root = VStack {
            AccountRefreshMenu(providers: [.glm, .claude], unavailableProviders: [],
                refreshAll: { await f.vm.manualRefresh() }, refreshProvider: { _ in },
                sharedRefresh: f.vm.manualAccountRefreshState)
            AccountProviderGroups(groups: renderedGroups, selection: nil, quotaDisplayStyle: .card,
                onDelete: { _ in }, onEdit: { _ in })
        }.padding(20).environment(f.vm)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(f.settings.selectedItems, [pin(keys[1], provider: .glm)], "原生渲染不能改用户固定状态")
    }
}
