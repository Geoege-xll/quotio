import AppKit
import SwiftUI
import XCTest
@testable import QuotioPlus

/// 用生产筛选、账号组和完整额度组件执行原生布局验证。所有账号、额度及连接
/// 都是内存夹具；关闭 ViewModel 后台服务，不发网络请求或写用户认证配置。
@MainActor
final class AccountPageRenderingTests: XCTestCase {
    @Observable final class Selection {
        var provider: AIProvider?
    }

    private struct Preview: View {
        @Bindable var selection: Selection
        let groups: [AIProvider: [AccountRowData]]
        let style: QuotaDisplayStyle
        let custom = CustomProvider(name: "自定义兼容连接", type: .openaiCompatibility)

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AccountProviderFilter(providers: groups.keys.sorted { $0.displayName < $1.displayName },
                        accountCounts: groups.mapValues(\.count), lowestPercentages: [.antigravity: 30, .codex: 42],
                        selection: $selection.provider)
                    AccountProviderGroups(groups: groups, selection: selection.provider, quotaDisplayStyle: style,
                        onDelete: { _ in }, onEdit: { _ in }, onSwitch: { _ in },
                        onToggleDisabled: { _ in }, onDownload: { _ in })
                    // 同页保留自定义提供商，筛选普通账号时此管理入口仍可见。
                    CustomProviderRow(provider: custom, onEdit: {}, onDelete: {}, onToggle: {})
                }
                .padding(20)
            }
            .quotioPage()
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let current = (view as? NSScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func capture(_ host: NSView) throws -> Data {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000, "必须实际渲染账号与额度内容")
        return png
    }

    func testNativeCPAStartShowsOneCredentialWithAttachedLegacyQuota() throws {
        // 对照官方混合响应：同一文件既有无索引磁盘描述，也有带索引的运行描述。
        let disk = try JSONDecoder().decode(AuthFile.self, from: Data(#"{"name":"claude-work.json","provider":"claude","email":"fixture@example.com","source":"file","path":"/isolated/claude-work.json"}"#.utf8))
        let runtime = try JSONDecoder().decode(AuthFile.self, from: Data(#"{"name":"claude-work.json","provider":"claude","auth_index":"runtime-a","source":"memory","status":"active"}"#.utf8))
        let direct = DirectAuthFile(id: "disk", provider: .claude, email: "fixture@example.com", login: nil,
            expired: nil, accountType: nil, filePath: "/isolated/claude-work.json", source: .cliProxyApi,
            filename: "claude-work.json")
        let vm = QuotaViewModel(startsBackgroundServices: false)
        vm.authFiles = AuthFileIdentity.deduplicated([disk, runtime])
        let aliases = AuthFileIdentity.quotaAliases(mode: .localProxy, proxyRunning: true,
            authFiles: vm.authFiles, directFiles: [direct])
        vm.providerQuotas = AuthFileIdentity.rekey([AIProvider.claude: ["fixture@example.com":
            ProviderQuotaData(models: [ModelQuota(name: "five-hour", percentage: 60, resetTime: "2h")],
                planType: "pro")]], aliases: aliases) { $0.lastUpdated > $1.lastUpdated }
        let groups = AccountPageData.groupedAccounts(mode: .localProxy, proxyRunning: true,
            authFiles: vm.authFiles, directAuthFiles: [direct], monitorAccounts: [], quotas: vm.providerQuotas,
            customProviders: [], warpTokens: [], monitorStatus: { _ in (nil, nil) })
        XCTAssertEqual(groups[.claude]?.count, 1)
        XCTAssertEqual(groups[.claude]?.first?.quotaAccountKeys, [runtime.quotaLookupKey])
        XCTAssertEqual(vm.providerQuotas[.claude]?.count, 1)
        let root = AccountProviderGroups(groups: groups, selection: nil, quotaDisplayStyle: .card,
            onDelete: { _ in }, onToggleDisabled: { _ in }, onDownload: { _ in })
            .padding(20).environment(vm).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 360),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        _ = try capture(host)
    }

    func testNativeMergedCardsFiltersThemesAndAllQuotaStyles() async throws {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        // 只设置测试进程的语言，不持久化用户语言偏好。
        defaults.setVolatileDomain(original.merging(["appLanguage": "zh-Hans"]) { _, new in new },
            forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }

        let vm = QuotaViewModel(startsBackgroundServices: false)
        vm.providerQuotas = [
            .antigravity: ["antigravity-fixture": ProviderQuotaData(models: [
                ModelQuota(name: "gemini-session", percentage: 76, resetTime: "1h 20m",
                    sourceDisplayName: "Gemini 本次会话", antigravityWindow: .session),
                ModelQuota(name: "gemini-weekly", percentage: 30, resetTime: "3d",
                    sourceDisplayName: "Gemini 每周额度", antigravityWindow: .weekly),
                ModelQuota(name: "claude-session", percentage: 65, resetTime: "2h",
                    sourceDisplayName: "Claude 本次会话", antigravityWindow: .session),
                ModelQuota(name: "claude-weekly", percentage: 40, resetTime: "4d",
                    sourceDisplayName: "Claude 每周额度", antigravityWindow: .weekly),
                ModelQuota(name: "unknown-model", percentage: -1, resetTime: "")
            ], planType: "pro", accountDisplayName: "工作账号@example.com")],
            .codex: ["codex-fixture": ProviderQuotaData(models: [
                ModelQuota(name: "codex-session", percentage: 42, resetTime: "3h"),
                ModelQuota(name: "codex-weekly", percentage: 80, resetTime: "5d")
            ], planType: "team", accountDisplayName: "团队账号@example.com")],
            .claude: ["claude-cache": ProviderQuotaData(models: [
                ModelQuota(name: "five-hour", percentage: 55, resetTime: "1h")
            ], accountDisplayName: "缓存账号@example.com")]
        ]
        let monitor = [
            MonitorAccount.make(provider: .antigravity, accountKey: "antigravity-fixture",
                displayName: "工作账号@example.com", source: .quotioKeychain, canDelete: true),
            MonitorAccount.make(provider: .codex, accountKey: "codex-fixture",
                displayName: "团队账号@example.com", source: .nativeCredential)
        ]
        // 多密钥连接的套餐可能不同；真实渲染同时覆盖主行不冒用首 Key 套餐、
        // 子段保留各自套餐和安全序号，以及同行的逐 Key 刷新菜单。
        let glm = CustomProvider(name: "GLM 多密钥连接", type: .glmCompatibility,
            apiKeys: [CustomAPIKeyEntry(apiKey: "fixture-a"), CustomAPIKeyEntry(apiKey: "fixture-b")])
        let glmKeys = glm.apiKeys.map { GLMQuotaFetcher.quotaAccountKey(providerID: glm.id, apiKeyID: $0.id) }
        vm.providerQuotas[.glm] = [
            glmKeys[0]: ProviderQuotaData(models: [ModelQuota(name: "fixture-a", percentage: 20, resetTime: "")],
                planType: "lite"),
            glmKeys[1]: ProviderQuotaData(models: [ModelQuota(name: "fixture-b", percentage: 70, resetTime: "")],
                planType: "pro")
        ]
        let groups = AccountPageData.groupedAccounts(mode: .monitor, proxyRunning: false,
            authFiles: [], directAuthFiles: [], monitorAccounts: monitor, quotas: vm.providerQuotas,
            customProviders: [glm], warpTokens: [], monitorStatus: { _ in ("ready", nil) })
        let selection = Selection()
        var stylePNGs: [Data] = []

        for scheme in [ColorScheme.light, .dark] {
            for style in QuotaDisplayStyle.allCases {
                let root = Preview(selection: selection, groups: groups, style: style)
                    .environment(vm).environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900),
                    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                window.contentView = host
                window.orderFront(nil)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(400))
                host.layoutSubtreeIfNeeded()
                let png = try capture(host)
                if scheme == .light { stylePNGs.append(png) }

                let vertical = scrollViews(in: host).filter { $0.hasVerticalScroller }
                XCTAssertEqual(vertical.count, 1, "融合页面只能有一份纵向滚动内容")
                let scroll = try XCTUnwrap(vertical.first)
                XCTAssertLessThanOrEqual(scroll.documentView?.bounds.width ?? 0, scroll.contentView.bounds.width + 1,
                    "账号操作和额度不能撑破页面宽度")

                // 改变真实生产列表的筛选输入后，仅当前服务商可见；没有独立 Tab 容器。
                selection.provider = .codex
                // 等待标准分段控件的滑块弹簧动画完成后再捕获，避免把中间帧当成最终布局。
                try await Task.sleep(for: .milliseconds(400))
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(AccountProviderGroups(groups: groups, selection: selection.provider,
                    quotaDisplayStyle: style).visibleProviders, [.codex])
                _ = try capture(host)
                selection.provider = .glm
                try await Task.sleep(for: .milliseconds(400))
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(AccountProviderGroups(groups: groups, selection: selection.provider,
                    quotaDisplayStyle: style).visibleProviders, [.glm])
                _ = try capture(host)
                selection.provider = nil

                // 使用应用 detail 区域的最小宽度核对布局，横向滚动只允许发生在服务商筛选条。
                window.setContentSize(NSSize(width: 660, height: 900))
                try await Task.sleep(for: .milliseconds(400))
                host.layoutSubtreeIfNeeded()
                _ = try capture(host)
                XCTAssertLessThanOrEqual(scroll.documentView?.bounds.width ?? 0, scroll.contentView.bounds.width + 1)
            }
        }
        XCTAssertEqual(stylePNGs.count, 3)
        XCTAssertNotEqual(stylePNGs[0], stylePNGs[1], "三种展示样式必须实际走到不同布局")
        XCTAssertNotEqual(stylePNGs[1], stylePNGs[2])
    }
}
