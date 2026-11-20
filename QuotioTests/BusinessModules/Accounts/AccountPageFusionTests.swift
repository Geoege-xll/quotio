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

    private func groups(current: Bool = false, cpa: [AuthFile] = [],
                        imported: [AIProvider: Set<String>] = [:],
                        custom: [CustomProvider] = [], warp: [WarpService.WarpToken] = []) -> [AIProvider: [AccountRowData]] {
        AccountPageData.groupedAccounts(hasCurrentCPAAccountDirectory: current, authFiles: cpa,
            importedIDEAccountKeys: imported, customProviders: custom, warpTokens: warp)
    }

    func testCPAAccountAndQuotaShareOneCardAndExactRefreshKey() throws {
        let file = try proxyFile("claude-work.json")
        let rows = try XCTUnwrap(groups(current: true, cpa: [file])[.claude])
        XCTAssertEqual(rows.count, 1, "同一连接与额度只生成一张卡片")
        XCTAssertEqual(rows[0].id, file.id)
        XCTAssertEqual(rows[0].quotaAccountID.accountKey, file.quotaLookupKey)
        XCTAssertEqual(rows[0].quotaAccountKeys, [file.quotaLookupKey])
        XCTAssertTrue(rows[0].canDelete)
        XCTAssertTrue(rows[0].canDownloadAuthFile)
        XCTAssertTrue(rows[0].canManageCPA)
    }

    func testSameEmailCPACredentialsRemainSeparate() throws {
        let a = try proxyFile("team-a.json", index: "a")
        let b = try proxyFile("team-b.json", index: "b")
        let rows = try XCTUnwrap(groups(current: true, cpa: [a, b])[.claude])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.menuBarAccountKey)), [a.quotaLookupKey, b.quotaLookupKey])
    }

    func testGrokUsesCPAIdentityEvenBeforeQuotaArrives() throws {
        let file = try proxyFile("grok.json", provider: "grok")
        let rows = try XCTUnwrap(groups(current: true, cpa: [file])[.grok])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].source, .proxy)
        XCTAssertEqual(rows[0].quotaAccountKeys, [file.quotaLookupKey])
        XCTAssertTrue(rows[0].canDelete)
    }

    func testCodexSameEmailPlusAndTeamKeepCPAIdentityAfterStop() throws {
        let a = try proxyFile("codex-same-plus.json", provider: "codex", index: "plus-a")
        let b = try proxyFile("codex-same-team.json", provider: "codex", index: "team-b")
        let rows = try XCTUnwrap(groups(cpa: [a, b])[.codex])
        XCTAssertEqual(rows.count, 2)
        XCTAssertNotEqual(rows[0].quotaAccountID, rows[1].quotaAccountID)
        XCTAssertEqual(Set(rows.map(\.menuBarAccountKey)), [a.menuBarAccountKey, b.menuBarAccountKey])
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

    func testLastConfirmedDirectoryKeepsErrorAndIdentityButLosesManagementPermissions() throws {
        let file = try proxyFile("claude.json", status: "error")
        let row = try XCTUnwrap(groups(cpa: [file])[.claude]?.first)
        XCTAssertEqual(row.source, .proxy)
        XCTAssertEqual(row.status, "error", "冻结目录保留代理最后确认的真实错误")
        XCTAssertEqual(row.quotaAccountKeys, [file.quotaLookupKey])
        XCTAssertFalse(row.canManageCPA)
        XCTAssertFalse(row.canDelete)
        XCTAssertFalse(row.canDownloadAuthFile)
        XCTAssertFalse(row.canEditRoutingWeight)
        XCTAssertFalse(row.canResetCooldown)
    }

    func testNoConfirmedDirectoryAndNoExplicitConnectionsProducesNoAccounts() {
        XCTAssertTrue(groups().isEmpty, "停机时不扫描本机认证文件或从未匹配的额度生成身份")
    }

    func testExplicitlyImportedIDEAccountsKeepLocalDeleteButCopilotNeedsCPAEntry() throws {
        let result = groups(imported: [.cursor: ["ide-account"], .trae: ["trae-account"], .copilot: ["gh-cli-only"]])
        let local = try XCTUnwrap(result[.cursor]?.first)
        XCTAssertEqual(local.source, .autoDetected)
        XCTAssertTrue(local.canDelete, "删除继续只移除 Quotio 导入记录")
        XCTAssertEqual(result[.trae]?.first?.quotaAccountKeys, ["trae-account"])
        XCTAssertNil(result[.copilot], "GitHub CLI 会话不能成为导入的 IDE 账号")
    }

    func testGLMMultipleKeysHaveOneConnectionAndAllQuotaSections() throws {
        let provider = CustomProvider(name: "GLM 多密钥", type: .glmCompatibility,
            apiKeys: [CustomAPIKeyEntry(apiKey: "fixture-a"), CustomAPIKeyEntry(apiKey: "fixture-b")])
        let keys = provider.apiKeys.map { GLMQuotaFetcher.quotaAccountKey(providerID: provider.id, apiKeyID: $0.id) }
        let rows = try XCTUnwrap(groups(custom: [provider])[.glm])
        XCTAssertEqual(rows.count, 1, "多个密钥额度应嵌入同一连接")
        XCTAssertEqual(rows[0].id, provider.id.uuidString, "编辑／删除仍指向原配置")
        XCTAssertEqual(rows[0].quotaAccountKeys, keys)
        XCTAssertTrue(rows[0].canEdit)
        XCTAssertTrue(rows[0].canDelete)
        XCTAssertEqual(Set(rows[0].menuBarItems), Set(MenuBarAccountCatalog.items(authFiles: [], customProviders: [provider])))
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

    func testSidebarHasOneAccountEntry() {
        XCTAssertEqual(NavigationPage.sidebarPages.filter { $0 == .providers }.count, 1)
        XCTAssertFalse(NavigationPage.sidebarPages.contains(.quota))
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

