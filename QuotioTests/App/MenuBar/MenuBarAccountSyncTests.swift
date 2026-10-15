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

    private func fixture(_ mode: OperatingMode = .localProxy) throws -> Fixture {
        let suite = "quotio-menubar-sync-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(mode.rawValue, forKey: "operatingMode")
        let manager = OperatingModeManager(defaults: defaults)
        let settings = MenuBarSettingsManager(defaults: defaults)
        let refresh = RefreshSettingsManager(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vm = QuotaViewModel(directAuthService: DirectAuthFileService(authDirectory: directory),
            startsBackgroundServices: false, modeManager: manager, menuBarSettings: settings, refreshSettings: refresh)
        vm.customProvidersForTesting = []
        addTeardownBlock { @MainActor in
            vm.stopQuotaAutoRefresh()
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

    func testCPAStartDoesNotAutoAddOldDiskEmailAgain() throws {
        let runtime = try file(path: "/isolated/claude-work.json"), disk = direct()
        let quotas = [AIProvider.claude: [runtime.quotaLookupKey: quota(70), "work@example.com": quota(80)]]
        let items = MenuBarAccountCatalog.items(mode: .localProxy, proxyRunning: true, authFiles: [runtime],
            directFiles: [disk], monitorAccounts: [], quotas: quotas)
        XCTAssertEqual(items, [pin(runtime.quotaLookupKey)])
        let f = try fixture()
        f.settings.autoSelectNewAccounts(availableItems: items)
        f.settings.autoSelectNewAccounts(availableItems: items)
        XCTAssertEqual(f.settings.selectedItems, items, "持续刷新不能再固定旧邮箱或挤占上限")
    }

    func testCatalogUsesOnlyCurrentModeDirectoryAndPreservesIndependentCache() throws {
        let runtime = try file(), disk = direct("claude-other.json"), cache = pin("cache")
        let monitor = MonitorAccount.make(provider: .copilot, accountKey: "monitor", source: .nativeCredential)
        func items(_ mode: OperatingMode, _ running: Bool) -> Set<MenuBarQuotaItem> {
            Set(MenuBarAccountCatalog.items(mode: mode, proxyRunning: running, authFiles: [runtime],
                directFiles: [disk], monitorAccounts: [monitor], quotas: [.claude: ["cache": quota(20)]]))
        }
        XCTAssertEqual(items(.localProxy, true), [pin(runtime.quotaLookupKey), cache])
        XCTAssertEqual(items(.localProxy, false), [pin(disk.menuBarAccountKey), cache])
        XCTAssertEqual(items(.monitor, true), [pin("monitor", provider: .copilot), cache])
    }

    func testResolverRejectsSameEmailGuessEvenWithOnlyOneSuccessfulQuota() throws {
        let a = try file("team-a.json", index: "a"), b = try file("team-b.json", index: "b")
        let quotas = [AIProvider.claude: [a.quotaLookupKey: quota(70)]]
        XCTAssertNil(MenuBarAccountCatalog.resolve(pin("work@example.com"), mode: .localProxy,
            proxyRunning: true, authFiles: [a, b], directFiles: [], quotas: quotas))
        XCTAssertEqual(MenuBarAccountCatalog.resolve(pin(a.quotaLookupKey), mode: .localProxy,
            proxyRunning: true, authFiles: [a, b], directFiles: [], quotas: quotas)?.models.first?.percentage, 70)
    }

    func testResolverUsesConfirmedAliasButExactCPASnapshotWins() throws {
        let runtime = try file(path: "/isolated/claude-work.json")
        let quotas = [AIProvider.claude: [runtime.quotaLookupKey: quota(30), "work@example.com": quota(90, updated: 50)]]
        XCTAssertEqual(MenuBarAccountCatalog.resolve(pin("work@example.com"), mode: .localProxy,
            proxyRunning: true, authFiles: [runtime], directFiles: [direct()], quotas: quotas)?.models.first?.percentage, 30)
        let different = try file(path: "/remote/claude-work.json")
        XCTAssertNil(MenuBarAccountCatalog.resolve(pin("work@example.com"), mode: .localProxy,
            proxyRunning: true, authFiles: [different], directFiles: [direct()],
            quotas: [.claude: [different.quotaLookupKey: quota(60)]]))
    }

    func testCopilotMigrationCannotBypassDifferentDirectoryProtection() throws {
        let remote = try file("github-copilot-local.json", provider: "github-copilot",
            path: "/remote/github-copilot-local.json", account: "remote")
        let local = direct(remote.name, provider: .copilot, path: "/local/" + remote.name, login: "local")
        let aliases = MenuBarAccountCatalog.aliases(mode: .localProxy, proxyRunning: true,
            authFiles: [remote], directFiles: [local], monitorAccounts: [])
        XCTAssertNil(aliases[.copilot]?["local"])
        XCTAssertEqual(AuthFileIdentity.rekeyMenuBarItems([pin("local", provider: .copilot)], aliases: aliases),
            [pin("local", provider: .copilot)], "固定迁移也必须使用同一份安全映射")
    }

    func testMonitorPreservesOldProviderAndExplicitLoginPins() throws {
        let f = try fixture(.monitor)
        f.vm.monitorAccounts = [MonitorAccount.make(provider: .copilot, accountKey: "canonical", source: .legacyCLIProxy)]
        f.vm.directAuthFiles = [direct("github-copilot-canonical.json", provider: .copilot,
            login: "canonical", legacy: ["old-login"])]
        f.vm.providerQuotas = [.copilot: ["canonical": quota(65)]]
        f.settings.toggleItem(MenuBarQuotaItem(provider: "copilot", accountKey: "old-login"))
        f.vm.syncMenuBarSelection()
        XCTAssertEqual(f.settings.selectedItems, [pin("canonical", provider: .copilot)])
        XCTAssertTrue(f.settings.hasUserModifiedMenuBar, "兼容迁移不能恢复自动选择偏好")
        let unknown = direct("github-copilot-other.json", provider: .copilot, login: "other", legacy: ["old-login"])
        XCTAssertNil(MenuBarAccountCatalog.aliases(mode: .monitor, proxyRunning: false, authFiles: [],
            directFiles: [unknown], monitorAccounts: f.vm.monitorAccounts)[.copilot]?["old-login"])
    }

    func testLoadedOldCopilotProviderPinsDeduplicateWithoutChangingOrder() throws {
        let f = try fixture(.monitor)
        let canonical = pin("login", provider: .copilot)
        f.settings.selectedItems = [MenuBarQuotaItem(provider: "copilot", accountKey: "login"), canonical, pin("other")]
        let loaded = MenuBarSettingsManager(defaults: f.defaults)
        XCTAssertEqual(loaded.selectedItems, [canonical, pin("other")])
    }

    func testMonitorMigratesUniqueCodexEmailButRejectsSharedSubscriptionEmail() throws {
        let plus = direct("work-plus.json", provider: .codex)
        let team = direct("work-team.json", provider: .codex)
        let accounts = [plus, team].map { MonitorAccount.makeLegacy($0) }
        let unique = MenuBarAccountCatalog.aliases(mode: .monitor, proxyRunning: false,
            authFiles: [], directFiles: [plus], monitorAccounts: [accounts[0]])
        XCTAssertEqual(unique[.codex]?["work@example.com"], plus.menuBarAccountKey)
        let ambiguous = MenuBarAccountCatalog.aliases(mode: .monitor, proxyRunning: false,
            authFiles: [], directFiles: [plus, team], monitorAccounts: accounts)
        XCTAssertNil(ambiguous[.codex]?["work@example.com"], "同邮箱多套餐不能擅自指定固定归属")
    }

    func testAmbiguousDiskRowsCannotPinAnotherCredentialsCache() {
        let rows = AccountPageData.groupedAccounts(mode: .localProxy, proxyRunning: false, authFiles: [],
            directAuthFiles: [direct("a.json"), direct("b.json")], monitorAccounts: [],
            quotas: [.claude: ["work@example.com": quota(40)]], customProviders: [], warpTokens: [],
            monitorStatus: { _ in (nil, nil) })[.claude] ?? []
        XCTAssertEqual(rows.filter { $0.source == .direct }.count, 2)
        XCTAssertTrue(rows.filter { $0.source == .direct }.allSatisfy { $0.menuBarItems.isEmpty })
        XCTAssertEqual(rows.first { $0.source == .quotaCache }?.menuBarItems, [pin("work@example.com")])
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
        let rows = AccountPageData.groupedAccounts(mode: .localProxy, proxyRunning: false, authFiles: [],
            directAuthFiles: [], monitorAccounts: [], quotas: [:], customProviders: [provider], warpTokens: [],
            monitorStatus: { _ in (nil, nil) })[.glm] ?? []
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
        XCTAssertNil(MenuBarAccountCatalog.aliases(mode: .localProxy, proxyRunning: false,
            authFiles: [], directFiles: [], monitorAccounts: [], customProviders: [multi])[.glm]?[multi.name])
    }

    func testManualRefreshUsesSharedPlanAndCoalescesDuplicateClicks() async throws {
        let f = try fixture()
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
        XCTAssertEqual(steps, AccountRefreshStep.plan(mode: .localProxy, proxyRunning: f.vm.proxyManager.proxyStatus.running))
        XCTAssertEqual(AccountRefreshStep.plan(mode: .localProxy, proxyRunning: true),
            [.cpaDirectory, .cpaQuotas, .provider(.grok), .provider(.devin)])
        XCTAssertEqual(AccountRefreshStep.plan(mode: .monitor, proxyRunning: true), [.monitorQuotas])
    }

    func testModeChangeStopsRemainingManualRefreshSteps() async throws {
        let f = try fixture()
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
        let f = try fixture()
        var reads = 0, resume: CheckedContinuation<Void, Never>?
        f.vm.localQuotaFetchHookForTesting = { _ in
            reads += 1
            await withCheckedContinuation { resume = $0 }
            return ["old": self.quota(20)]
        }
        let background = Task { await f.vm.refreshQuota(for: .glm) }
        while resume == nil { await Task.yield() }
        let waiting = Task { await f.vm.refreshQuota(for: .glm, waitForAvailability: true) }
        // 先让等待者进入真实预约循环，再跨模式；不能让它在切换后才采样上下文。
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        f.mode.setMode(.monitor)
        resume?.resume()
        await background.value
        await waiting.value
        XCTAssertEqual(reads, 1)
        XCTAssertNil(f.vm.providerQuotas[.glm])
        XCTAssertTrue(f.vm.refreshingProviders.isEmpty, "拒绝旧来源之后也必须释放已预约槽位")
    }

    func testGLMDeletionRejectsLateResultAndPreservesOtherConnection() async throws {
        let f = try fixture(), provider = glm(), keys = keys(provider)
        f.vm.providerQuotas = [.glm: [keys[0]: quota(10), keys[1]: quota(20), "other": quota(90)]]
        f.settings.toggleItem(pin(keys[1], provider: .glm))
        f.settings.toggleItem(pin("other", provider: .glm))
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
        XCTAssertEqual(Set(f.vm.providerQuotas[.glm]?.keys ?? Dictionary<String, ProviderQuotaData>().keys), ["other"])
        XCTAssertEqual(f.settings.selectedItems, [pin("other", provider: .glm)])
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

    func testAccountDeletionRejectsLateQuotaEvenWhenSameKeyIsReadded() async throws {
        let f = try fixture(), deleted = try file(), key = deleted.quotaLookupKey
        try XCTSkipIf(f.vm.proxyManager.proxyStatus.running, "额度提交夹具不调用真实 CPA")
        f.vm.authFiles = [deleted]
        var resume: CheckedContinuation<Void, Never>?
        // 外部读取挂起，实际 Claude 提交路径仍执行世代校验；同名重新添加后，
        // 旧响应不能覆盖新额度。不会调用用户的 CLI 或 CPA。
        f.vm.localQuotaFetchHookForTesting = { _ in
            await withCheckedContinuation { resume = $0 }
            return [key: self.quota(5)]
        }
        let old = Task { await f.vm.refreshQuota(for: .claude) }
        while resume == nil { await Task.yield() }
        f.vm.commitAuthFileDeletion(deleted)
        f.vm.providerQuotas[.claude] = [key: quota(90)]
        resume?.resume()
        await old.value
        XCTAssertEqual(f.vm.providerQuotas[.claude]?[key]?.models.first?.percentage, 90)
    }

    func testStoppedModeSchedulesQuotaTimerAndManualCadenceCancelsIt() throws {
        let f = try fixture()
        f.refresh.refreshCadence = .fiveMinutes
        f.vm.restartAutoRefresh()
        XCTAssertTrue(f.vm.isQuotaAutoRefreshScheduledForTesting)
        f.refresh.refreshCadence = .manual
        f.vm.restartAutoRefresh()
        XCTAssertFalse(f.vm.isQuotaAutoRefreshScheduledForTesting)
    }

    func testNativeMultiKeyAndSingleKeyControlsRenderWithIsolatedSelection() throws {
        let f = try fixture(), provider = glm(), keys = keys(provider)
        f.vm.providerQuotas = [.glm: [keys[0]: quota(30), keys[1]: quota(70)]]
        f.settings.toggleItem(pin(keys[1], provider: .glm))
        let groups = AccountPageData.groupedAccounts(mode: .localProxy, proxyRunning: false, authFiles: [],
            directAuthFiles: [], monitorAccounts: [], quotas: f.vm.providerQuotas, customProviders: [provider],
            warpTokens: [], monitorStatus: { _ in (nil, nil) })
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
