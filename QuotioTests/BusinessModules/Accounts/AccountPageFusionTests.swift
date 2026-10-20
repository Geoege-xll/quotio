import AppKit
import SwiftUI
import XCTest
@testable import QuotioPlus

/// 以离线账号／额度夹具验证融合页的身份、权限和来源规则，不创建或删除真实凭据。
@MainActor
final class AccountPageFusionTests: XCTestCase {
    private func proxyFile(_ name: String, provider: String = "claude", index: String = "a",
                           email: String = "same@example.com", status: String = "ready") throws -> AuthFile {
        let object: [String: Any] = ["id": name, "name": name, "provider": provider,
            "email": email, "auth_index": index, "status": status]
        return try JSONDecoder().decode(AuthFile.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func directFile(_ name: String, provider: AIProvider = .claude,
                            email: String = "same@example.com") -> DirectAuthFile {
        DirectAuthFile(id: name, provider: provider, email: email, login: nil, expired: nil,
            accountType: nil, filePath: "/isolated/\(name)", source: .cliProxyApi, filename: name)
    }

    private func quota(_ percent: Double = 40, name: String? = nil) -> ProviderQuotaData {
        ProviderQuotaData(models: [ModelQuota(name: "fixture", percentage: percent, resetTime: "")],
            accountDisplayName: name)
    }

    private func groups(mode: OperatingMode = .monitor, running: Bool = false,
                        proxy: [AuthFile] = [], direct: [DirectAuthFile] = [], monitor: [MonitorAccount] = [],
                        quotas: [AIProvider: [String: ProviderQuotaData]] = [:],
                        custom: [CustomProvider] = [], warp: [WarpService.WarpToken] = []) -> [AIProvider: [AccountRowData]] {
        AccountPageData.groupedAccounts(mode: mode, proxyRunning: running, authFiles: proxy,
            directAuthFiles: direct, monitorAccounts: monitor, quotas: quotas, customProviders: custom,
            warpTokens: warp, monitorStatus: { _ in ("outdated", "离线缓存过期") })
    }

    func testProxyAccountAndQuotaShareOneCardAndExactRefreshKey() throws {
        let file = try proxyFile("claude-work.json")
        let rows = try XCTUnwrap(groups(mode: .localProxy, running: true, proxy: [file],
            quotas: [.claude: [file.quotaLookupKey: quota()]])[.claude])
        XCTAssertEqual(rows.count, 1, "同一连接与额度只生成一张卡片")
        XCTAssertEqual(rows[0].id, file.id)
        XCTAssertEqual(rows[0].quotaAccountID.accountKey, file.quotaLookupKey)
        XCTAssertEqual(rows[0].quotaAccountKeys, [file.quotaLookupKey])
        XCTAssertTrue(rows[0].canDelete)
        XCTAssertTrue(rows[0].canDownloadAuthFile)
        XCTAssertTrue(rows[0].source.supportsDisable)
    }

    func testSameEmailProxyCredentialsRemainSeparate() throws {
        let a = try proxyFile("team-a.json", index: "a")
        let b = try proxyFile("team-b.json", index: "b")
        let rows = try XCTUnwrap(groups(mode: .localProxy, running: true, proxy: [a, b],
            quotas: [.claude: [a.quotaLookupKey: quota(20), b.quotaLookupKey: quota(80)]])[.claude])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.menuBarAccountKey)), [a.quotaLookupKey, b.quotaLookupKey])
    }

    func testAutomaticQuotaSourceDoesNotDuplicateRunningGrokConnection() throws {
        let file = try proxyFile("grok.json", provider: "grok")
        let rows = try XCTUnwrap(groups(mode: .localProxy, running: true, proxy: [file],
            quotas: [.grok: [file.quotaLookupKey: quota()]])[.grok])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].source, .proxy)
        XCTAssertEqual(rows[0].quotaAccountKeys, [file.quotaLookupKey])
        XCTAssertTrue(rows[0].canDelete)
    }

    func testCodexSameEmailPlusAndTeamKeepFilenameIdentity() throws {
        let a = directFile("codex-same-plus.json", provider: .codex)
        let b = directFile("codex-same-team.json", provider: .codex)
        let rows = try XCTUnwrap(groups(mode: .localProxy, direct: [a, b],
            quotas: [.codex: [a.menuBarAccountKey: quota(20), b.menuBarAccountKey: quota(80)]])[.codex])
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotEqual(rows[0].quotaAccountID, rows[1].quotaAccountID)
        XCTAssertEqual(Set(rows.map(\.menuBarAccountKey)), [a.menuBarAccountKey, b.menuBarAccountKey])
    }

    func testSameEmailDirectFilesDoNotBorrowOneAmbiguousQuota() throws {
        let a = directFile("team-a.json")
        let b = directFile("team-b.json")
        let rows = try XCTUnwrap(groups(mode: .localProxy, direct: [a, b],
            quotas: [.claude: [a.menuBarAccountKey: quota()]])[.claude])
        let connections = rows.filter { $0.source == .direct }
        let caches = rows.filter { $0.source == .quotaCache }
        XCTAssertEqual(connections.count, 2, "两份认证文件的管理操作都必须保留")
        XCTAssertTrue(connections.allSatisfy { $0.quotaAccountKeys.isEmpty }, "无法判定归属时不复制额度")
        XCTAssertEqual(caches.count, 1)
        XCTAssertEqual(caches[0].quotaAccountKeys, [a.menuBarAccountKey])
        XCTAssertFalse(caches[0].canDelete)
    }

    func testMultiKeyQuotaTitleHonorsPrivacyWithoutChangingUserPreferences() throws {
        let suite = "quotio-account-privacy-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let settings = MenuBarSettingsManager(defaults: preferences)
        let account = AccountQuotaPresentation(key: "key-a", email: "私密配置@example.com",
            status: "", statusColor: .secondary, authFile: nil, quotaData: nil, subscriptionInfo: nil)
        let content = AccountQuotaContent(settings: settings, provider: .glm, account: account,
            isLoading: false, showsIdentity: false, quotaLabel: "私密配置@example.com · 2")
        settings.hideSensitiveInfo = false
        XCTAssertEqual(content.displayQuotaLabel, "私密配置@example.com · 2")
        settings.hideSensitiveInfo = true
        XCTAssertEqual(content.displayQuotaLabel, "私密配置@example.com · 2".masked())
        XCTAssertFalse(try XCTUnwrap(content.displayQuotaLabel).contains("私密配置"))
        XCTAssertTrue(preferences.bool(forKey: "hideSensitiveInfo"))
    }

    func testStoppedProxyDoesNotLeakPreviousAuthErrorOrDeleteCapability() throws {
        let old = try proxyFile("claude.json", status: "error")
        let direct = directFile("claude.json")
        let rows = try XCTUnwrap(groups(mode: .localProxy, proxy: [old], direct: [direct],
            quotas: [.claude: [direct.menuBarAccountKey: quota()]])[.claude])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].source, .direct)
        XCTAssertNil(rows[0].status)
        XCTAssertFalse(rows[0].canDelete)
        XCTAssertFalse(rows[0].source.supportsDisable)
        XCTAssertTrue(rows[0].canDownloadAuthFile, "保留原直读认证文件导出入口")
    }

    func testMonitorAccountUsesMonitorIDAndRetainsErrorAndDisableState() throws {
        let account = MonitorAccount.make(provider: .claude, accountKey: "native-account",
            displayName: "same@example.com", source: .quotioKeychain, canDelete: true, isDisabled: true)
        let rows = try XCTUnwrap(groups(running: true, proxy: [try proxyFile("old.json")],
            direct: [directFile("old.json")], monitor: [account],
            quotas: [.claude: [account.accountKey: quota()]])[.claude])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, account.id)
        XCTAssertEqual(rows[0].source, .monitor(.quotioKeychain))
        XCTAssertEqual(rows[0].status, "outdated")
        XCTAssertEqual(rows[0].statusMessage, "离线缓存过期")
        XCTAssertTrue(rows[0].isDisabled)
        XCTAssertTrue(rows[0].canDelete)
        XCTAssertTrue(rows[0].source.supportsDisable)
    }

    func testMonitorAPIKeyEditingCapabilitiesArePreserved() throws {
        for provider in [AIProvider.factoryDroid, .openRouter, .amp] {
            let account = MonitorAccount.make(provider: provider, accountKey: "fixture-key",
                source: .quotioKeychain, canDelete: true)
            let row = try XCTUnwrap(groups(monitor: [account])[provider]?.first)
            XCTAssertTrue(row.canEdit)
            XCTAssertTrue(row.canDelete)
            XCTAssertFalse(row.canDownloadAuthFile)
        }
        let native = MonitorAccount.make(provider: .claude, accountKey: "native", source: .nativeCredential)
        XCTAssertFalse(try XCTUnwrap(groups(monitor: [native])[.claude]?.first).canEdit)
    }

    func testUnmatchedQuotaCacheRemainsVisibleWithoutCredentialPermissions() throws {
        let rows = try XCTUnwrap(groups(quotas: [.claude: ["cache-only": quota(name: "缓存账号")]])[.claude])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].displayName, "缓存账号")
        XCTAssertEqual(rows[0].source, .quotaCache)
        XCTAssertNil(rows[0].status, "缓存不能暗示认证仍然有效")
        XCTAssertFalse(rows[0].canDelete)
        XCTAssertFalse(rows[0].canEdit)
        XCTAssertFalse(rows[0].canDownloadAuthFile)
        XCTAssertFalse(rows[0].source.supportsDisable)
        XCTAssertEqual(rows[0].quotaAccountID.accountKey, "cache-only")
    }

    func testConnectedAccountWithoutQuotaIsNotDropped() throws {
        let file = try proxyFile("waiting.json")
        let row = try XCTUnwrap(groups(mode: .localProxy, running: true, proxy: [file])[.claude]?.first)
        XCTAssertEqual(row.id, file.id)
        XCTAssertTrue(row.canDelete)
    }

    func testImportedIDEAccountDeleteAndMonitorSourceArePreserved() throws {
        let local = try XCTUnwrap(groups(mode: .localProxy,
            quotas: [.cursor: ["ide-account": quota()]])[.cursor]?.first)
        XCTAssertEqual(local.source, .autoDetected)
        XCTAssertTrue(local.canDelete, "删除继续只移除 Quotio 导入记录")
        let monitor = MonitorAccount.make(provider: .cursor, accountKey: "ide-account", source: .localIDE,
            canDelete: true)
        let rows = try XCTUnwrap(groups(monitor: [monitor],
            quotas: [.cursor: ["ide-account": quota()]])[.cursor])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].source, .monitor(.localIDE))
    }

    func testGLMMultipleKeysHaveOneConnectionAndAllQuotaSections() throws {
        let provider = CustomProvider(name: "GLM 多密钥", type: .glmCompatibility,
            apiKeys: [CustomAPIKeyEntry(apiKey: "fixture-a"), CustomAPIKeyEntry(apiKey: "fixture-b")])
        let keys = provider.apiKeys.map { GLMQuotaFetcher.quotaAccountKey(providerID: provider.id, apiKeyID: $0.id) }
        let rows = try XCTUnwrap(groups(quotas: [.glm: [keys[0]: quota(20), keys[1]: quota(80)]],
            custom: [provider])[.glm])
        XCTAssertEqual(rows.count, 1, "多个密钥额度应嵌入同一连接，不额外生成只读缓存卡")
        XCTAssertEqual(rows[0].id, provider.id.uuidString, "编辑／删除仍指向原配置")
        XCTAssertEqual(rows[0].quotaAccountKeys, keys)
        XCTAssertTrue(rows[0].canEdit)
        XCTAssertTrue(rows[0].canDelete)
    }

    func testMultiKeyPlansRemainPerKeyWhenDifferentOrFirstQuotaIsMissing() {
        func content(_ plan: String?, sequence: Int) -> AccountQuotaContent {
            let data = plan.map { ProviderQuotaData(planType: $0) }
            let snapshot = AccountQuotaPresentation(key: "key-\(sequence)", email: "GLM 连接",
                status: "", statusColor: .secondary, authFile: nil, quotaData: data, subscriptionInfo: nil)
            return AccountQuotaContent(provider: .glm, account: snapshot, isLoading: false,
                showsIdentity: false, quotaLabel: "GLM 连接", quotaSequence: sequence)
        }
        let lite = content("lite", sequence: 1)
        let pro = content("pro", sequence: 2)
        XCTAssertTrue(lite.showsPlanBadge && pro.showsPlanBadge)
        XCTAssertNotEqual(lite.account.quotaData?.planDisplayName, pro.account.quotaData?.planDisplayName)
        XCTAssertNil(content(nil, sequence: 1).account.quotaData)
        XCTAssertTrue(pro.showsPlanBadge, "首 Key 尚无额度时，第二 Key 的套餐仍须显示")
        XCTAssertEqual(pro.quotaSequence, 2)
    }

    func testSpecialProviderStorageIdentityAndActionsRemainReachable() throws {
        let cline = CustomProvider(name: "Cline 连接", type: .clinePass)
        let warp = WarpService.WarpToken(name: "Warp 连接", token: "fixture-token")
        let deepseek = CustomProvider(name: "DeepSeek 主账号", type: .deepseekCompatibility, apiKeys: [CustomAPIKeyEntry(apiKey: "sk-ds-fixture")])
        let moonshot = CustomProvider(name: "Moonshot 生产", type: .moonshotCompatibility, apiKeys: [CustomAPIKeyEntry(apiKey: "sk-ms-fixture")])
        let minimax = CustomProvider(name: "MiniMax 测试", type: .minimaxCompatibility, apiKeys: [CustomAPIKeyEntry(apiKey: "sk-mm-fixture")])
        let result = groups(custom: [cline, deepseek, moonshot, minimax], warp: [warp])
        let clineRow = try XCTUnwrap(result[.clinePass]?.first)
        let warpRow = try XCTUnwrap(result[.warp]?.first)
        let dsRow = try XCTUnwrap(result[.deepseek]?.first)
        let msRow = try XCTUnwrap(result[.moonshot]?.first)
        let mmRow = try XCTUnwrap(result[.minimax]?.first)
        XCTAssertEqual(clineRow.id, cline.id.uuidString)
        XCTAssertEqual(warpRow.id, warp.id.uuidString)
        XCTAssertEqual(dsRow.id, deepseek.id.uuidString)
        XCTAssertEqual(msRow.id, moonshot.id.uuidString)
        XCTAssertEqual(mmRow.id, minimax.id.uuidString)
        XCTAssertEqual(dsRow.provider, .deepseek)
        XCTAssertEqual(msRow.provider, .moonshot)
        XCTAssertEqual(mmRow.provider, .minimax)
        XCTAssertTrue(clineRow.canEdit && clineRow.canDelete)
        XCTAssertTrue(warpRow.canEdit && warpRow.canDelete)
        XCTAssertTrue(dsRow.canEdit && dsRow.canDelete)
        XCTAssertTrue(msRow.canEdit && msRow.canDelete)
        XCTAssertTrue(mmRow.canEdit && mmRow.canDelete)
    }

    func testSidebarHasOneAccountEntryInBothOperatingModes() {
        for mode in OperatingMode.allCases {
            XCTAssertEqual(mode.visiblePages.filter { $0 == .providers }.count, 1)
            XCTAssertFalse(mode.visiblePages.contains(.quota))
        }
    }

    func testOldQuotaNavigationIsNormalizedToUnifiedAccountEntry() {
        let vm = QuotaViewModel(startsBackgroundServices: false)
        vm.currentPage = .quota
        XCTAssertEqual(vm.currentPage, .providers)
        vm.currentPage = .agents
        XCTAssertEqual(vm.currentPage, .agents)
    }

    func testTooltipsSupportDetachedViewsAndEmptyText() {
        // 验证 TooltipWindow show 和 hide 在各种视图状态下保持安全稳定
        let dummyView = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        TooltipWindow.shared.show(text: "测试提示气泡", near: dummyView)
        TooltipWindow.shared.hide(from: dummyView)
        TooltipWindow.shared.show(text: "", near: dummyView)
    }

    func testAdaptiveQuotaGridColumnsSingleVersusMultipleMetrics() {
        // 单条额度（如 Codex 仅有周限额）：单列满宽显示
        let singleColumns = AccountQuotaContent.quotaGridColumns(count: 1)
        XCTAssertEqual(singleColumns.count, 1, "单条额度指标应为一行一个")
        let zeroColumns = AccountQuotaContent.quotaGridColumns(count: 0)
        XCTAssertEqual(zeroColumns.count, 1, "空数据或边界也保证单列")

        // 大于等于2条额度（如 Codex 周+5小时限额、Claude 会话+周限额、Antigravity 模型组）：一行两个网格自适应
        let doubleColumns = AccountQuotaContent.quotaGridColumns(count: 2)
        XCTAssertEqual(doubleColumns.count, 2, "两条额度指标自适应为一行两个")
        XCTAssertEqual(doubleColumns[0].spacing, 10, "网格列间距保持 10pt")

        let quadColumns = AccountQuotaContent.quotaGridColumns(count: 4)
        XCTAssertEqual(quadColumns.count, 2, "四条额度指标保持双列网格自适应")
        XCTAssertEqual(quadColumns[0].spacing, 10)
    }
}

