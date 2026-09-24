import XCTest
@testable import QuotioPlus

final class QuotaAccountCountTests: XCTestCase {
    /// 两个真实账号的监控 ID 与额度缓存键不同，顶部仍必须显示两个，而不是四个。
    func testMonitorAccountsAreNotAddedToTheirQuotaCacheEntries() {
        let count = QuotaAccountCount.count(
            mode: .monitor,
            proxyRunning: false,
            proxyKeys: [],
            directKeys: [],
            monitorKeys: ["monitor-a", "monitor-b"],
            quotaKeys: ["quota-a", "quota-b"]
        )
        XCTAssertEqual(count, 2)

        let codexCount = QuotaAccountCount.count(
            mode: .monitor,
            proxyRunning: false,
            proxyKeys: [],
            directKeys: [],
            monitorKeys: ["codex-account"],
            quotaKeys: ["codex-quota-key"]
        )
        XCTAssertEqual(codexCount, 1)
    }

    /// 代理凭据与额度结果使用不同键时，账号数以当前代理凭据目录为准。
    func testRunningProxyUsesAuthFilesOnly() {
        let count = QuotaAccountCount.count(
            mode: .localProxy,
            proxyRunning: true,
            proxyKeys: ["cpa:account-a", "cpa:account-b"],
            directKeys: ["account-a.json", "account-b.json"],
            monitorKeys: [],
            quotaKeys: ["quota-a", "quota-b"]
        )
        XCTAssertEqual(count, 2)
    }

    /// 账号目录尚未加载时，已取得的额度仍可为顶部徽标提供真实数量。
    func testQuotaCacheIsFallbackOnly() {
        let count = QuotaAccountCount.count(
            mode: .monitor,
            proxyRunning: false,
            proxyKeys: [],
            directKeys: [],
            monitorKeys: [],
            quotaKeys: ["account-a", "account-b", "account-c"]
        )
        XCTAssertEqual(count, 3)
    }

    /// 本地代理停止后同时保留直读文件和上次额度数据，也不能把它们算成两批账号。
    func testStoppedProxyUsesDirectFilesWithoutDoublingCachedQuota() {
        let count = QuotaAccountCount.count(
            mode: .localProxy,
            proxyRunning: false,
            proxyKeys: [],
            directKeys: ["antigravity-a.json", "antigravity-b.json"],
            monitorKeys: [],
            quotaKeys: ["antigravity-a", "antigravity-b"]
        )
        XCTAssertEqual(count, 2)
    }
}
