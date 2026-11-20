import XCTest
@testable import QuotioPlus

/// Covers the quota refresh applied to IDE-derived providers (Cursor, Trae) by the
/// global refresh actions — the path the menu bar "Refresh" uses (issues #163, #257).
final class IDEQuotaRefreshTests: XCTestCase {
    private func quota(_ percentage: Double, lastUpdated: Date) -> ProviderQuotaData {
        ProviderQuotaData(
            models: [ModelQuota(name: "cursor-fast", percentage: percentage, resetTime: "")],
            lastUpdated: lastUpdated
        )
    }

    /// The global refresh must actually update an imported Cursor account, instead of
    /// leaving the stale snapshot the menu bar was showing (issue #163).
    func testMergeImportedIDEQuotasUpdatesImportedAccount() {
        let stale = quota(10, lastUpdated: Date(timeIntervalSince1970: 1_000))
        let fresh = quota(75, lastUpdated: Date(timeIntervalSince1970: 2_000))

        let merged = QuotaViewModel.mergeImportedIDEQuotas(
            fetched: ["user@example.com": fresh],
            into: ["user@example.com": stale]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged["user@example.com"]?.models.first?.percentage, 75)
        XCTAssertEqual(merged["user@example.com"]?.lastUpdated, Date(timeIntervalSince1970: 2_000))
    }

    /// Guards the invariant introduced by the "delete imported Cursor/Trae account"
    /// fix (issue #213): a global refresh reads the IDE database, but it must never
    /// re-import an account key the user removed, or the account resurrects.
    func testMergeImportedIDEQuotasDoesNotResurrectDeletedAccount() {
        let kept = quota(10, lastUpdated: Date(timeIntervalSince1970: 1_000))
        let fresh = quota(80, lastUpdated: Date(timeIntervalSince1970: 2_000))
        let resurrected = quota(42, lastUpdated: Date(timeIntervalSince1970: 2_000))

        let merged = QuotaViewModel.mergeImportedIDEQuotas(
            fetched: ["kept@example.com": fresh, "deleted@example.com": resurrected],
            into: ["kept@example.com": kept]
        )

        XCTAssertNil(merged["deleted@example.com"], "Deleted IDE account must not be re-imported by a refresh")
        XCTAssertEqual(merged["kept@example.com"]?.models.first?.percentage, 80)
    }

    /// With nothing imported, a refresh must not pull accounts in: Cursor/Trae are
    /// import-on-explicit-scan only (issue #29).
    func testMergeImportedIDEQuotasImportsNothingWhenProviderNotScanned() {
        let merged = QuotaViewModel.mergeImportedIDEQuotas(
            fetched: ["user@example.com": quota(50, lastUpdated: Date())],
            into: [:]
        )

        XCTAssertTrue(merged.isEmpty, "A refresh must not import IDE accounts without an explicit scan")
    }

    /// A transiently unreadable IDE database must not wipe the imported account from
    /// the menu bar; the previous value stays until a scan removes it.
    func testMergeImportedIDEQuotasKeepsAccountMissingFromFetch() {
        let stale = quota(10, lastUpdated: Date(timeIntervalSince1970: 1_000))

        let merged = QuotaViewModel.mergeImportedIDEQuotas(fetched: [:], into: ["user@example.com": stale])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged["user@example.com"]?.models.first?.percentage, 10)
    }

    /// The refresh path covers exactly the IDE-derived providers, which are also the
    /// ones excluded from the generic auto-detected re-import.
    func testIDEQuotaRefreshCoversBrowserAuthProviders() {
        XCTAssertEqual(QuotaViewModel.ideProvidersToSave, [.cursor, .trae])

        for provider in QuotaViewModel.ideProvidersToSave {
            XCTAssertTrue(provider.usesBrowserAuth, "\(provider.rawValue) is an IDE-derived provider")
            XCTAssertFalse(provider.supportsManualAuth, "\(provider.rawValue) cannot be added manually")
        }
    }

    func testCursorSwitchedLoginIsRejectedBeforeNetworkAndMatchingLoginCanRefresh() async {
        let host = "api2.cursor.sh"
        let state = LifecycleHTTPState { _, _ in
            .reply(#"{"individualUsage":{"plan":{"enabled":true,"used":20,"limit":100}}}"#)
        }
        LifecycleHTTPProtocol.register(state, host: host)
        defer { LifecycleHTTPProtocol.remove(host: host) }

        let currentAccount = "new-login@example.invalid"
        let current = CursorAuthData(accessToken: "cursor-fixture", refreshToken: nil, email: currentAccount,
                                     membershipType: "pro", subscriptionStatus: nil, signUpType: nil)
        let fetcher = CursorQuotaFetcher(configuration: offlineConfiguration(), readAuth: { current })
        let noReadFetcher = CursorQuotaFetcher(configuration: offlineConfiguration(), readAuth: {
            XCTFail("安装探测后会话失效，不能读取本机凭据")
            return nil
        })
        let stoppedBeforeRead = IDEQuotaPermissionFixture(allowedChecks: 1)
        let blockedRead = await noReadFetcher.fetchAsProviderQuota(matchingAccountKeys: [currentAccount],
            isCurrent: { await stoppedBeforeRead.isCurrent() })
        XCTAssertTrue(blockedRead.isEmpty)

        let stoppedBeforeRequest = IDEQuotaPermissionFixture(allowedChecks: 2)
        let blockedSend = await fetcher.fetchAsProviderQuota(matchingAccountKeys: [currentAccount],
            isCurrent: { await stoppedBeforeRequest.isCurrent() })
        XCTAssertTrue(blockedSend.isEmpty)

        let rejected = await fetcher.fetchAsProviderQuota(matchingAccountKeys: ["imported-login@example.invalid"])
        XCTAssertTrue(rejected.isEmpty)
        XCTAssertEqual(state.requestCount, 0, "IDE 切换到另一账号后，应在网络层之前阻止请求")

        let fresh = await fetcher.fetchAsProviderQuota(matchingAccountKeys: [currentAccount])
        XCTAssertEqual(fresh[currentAccount]?.models.first?.percentage, 80)
        XCTAssertEqual(state.requests.map(\.authorization), ["Bearer cursor-fixture"])
    }

    func testCursorFailedOnlineRefreshKeepsOldQuotaAndExplicitImportCanShowLocalPlan() async {
        let host = "api2.cursor.sh"
        let state = LifecycleHTTPState { _, count in
            switch count {
            case 1, 4: return .replyStatus("fixture unauthorized", 401)
            case 2: return .fail(.timedOut)
            default: return .reply(#"{"individualUsage":{"plan":{"enabled":true}}}"#)
            }
        }
        LifecycleHTTPProtocol.register(state, host: host)
        defer { LifecycleHTTPProtocol.remove(host: host) }

        let key = "imported-login@example.invalid"
        let previous = Date(timeIntervalSince1970: 1_000)
        let existing = [key: quota(65, lastUpdated: previous)]
        let auth = CursorAuthData(accessToken: "cursor-fixture", refreshToken: nil, email: key,
                                  membershipType: "pro", subscriptionStatus: nil, signUpType: nil)
        let fetcher = CursorQuotaFetcher(configuration: offlineConfiguration(), readAuth: { auth })
        for _ in 0..<3 {
            let refreshed = await fetcher.fetchAsProviderQuota(matchingAccountKeys: [key])
            XCTAssertTrue(refreshed.isEmpty)
            let merged = QuotaViewModel.mergeImportedIDEQuotas(fetched: refreshed, into: existing)
            XCTAssertEqual(merged[key]?.lastUpdated, previous)
            XCTAssertEqual(merged[key]?.models.first?.percentage, 65)
        }

        let imported = await fetcher.fetchAsProviderQuota()
        XCTAssertEqual(imported[key]?.planType, "Pro", "用户明确导入时原本地套餐仍可显示")
        XCTAssertEqual(state.requestCount, 4)
    }

    func testTraeRefreshRejectsOtherIdentityAndAnonymousPlaceholderBeforeNetwork() async {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let state = LifecycleHTTPState { _, count in
            if count == 2 { return .reply(#"{"user_entitlement_pack_list":[{"status":1}]}"#) }
            return .reply(#"{"user_entitlement_pack_list":[{"status":1,"entitlement_base_info":{"quota":{"premium_model_fast_request_limit":100}},"usage":{"premium_model_fast_amount":20}}]}"#)
        }
        LifecycleHTTPProtocol.register(state, host: host)
        defer { LifecycleHTTPProtocol.remove(host: host) }

        let apiHost = "https://" + host
        let newAccount = TraeAuthData(accessToken: "new-token-fixture", refreshToken: nil, email: nil,
                                      userId: "new-id", apiHost: apiHost, username: "new-name")
        let anonymous = TraeAuthData(accessToken: "anonymous-fixture", refreshToken: nil, email: " ",
                                     userId: nil, apiHost: apiHost, username: nil)
        let fetcher = TraeQuotaFetcher(configuration: offlineConfiguration(), readAuth: { newAccount })
        let anonymousFetcher = TraeQuotaFetcher(configuration: offlineConfiguration(), readAuth: { anonymous })
        let wrong = await fetcher.fetchAsProviderQuota(matchingAccountKeys: ["old-name", "new-id"])
        let placeholder = await anonymousFetcher.fetchAsProviderQuota(matchingAccountKeys: ["Trae User"])
        XCTAssertTrue(wrong.isEmpty, "请求必须按与投影一致的用户名键匹配，不能降级选另一别名")
        XCTAssertTrue(placeholder.isEmpty)
        XCTAssertEqual(state.requestCount, 0)

        let fresh = await fetcher.fetchAsProviderQuota(matchingAccountKeys: ["new-name"])
        XCTAssertEqual(fresh["new-name"]?.models.first?.percentage, 80)
        XCTAssertEqual(state.requests.map(\.authorization), ["Cloud-IDE-JWT new-token-fixture"])
        let missingQuota = await fetcher.fetchAsProviderQuota(matchingAccountKeys: ["new-name"])
        XCTAssertTrue(missingQuota.isEmpty, "没有实际额度时不能返回纯占位供已导入账号更新")
    }

    private func offlineConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleHTTPProtocol.self]
        return configuration
    }
}

/// 每次复核推进一格，确定性模拟授权在进入取数器后失效，无需实际启停本机代理。
private actor IDEQuotaPermissionFixture {
    private let allowedChecks: Int
    private var checks = 0

    init(allowedChecks: Int) { self.allowedChecks = allowedChecks }

    func isCurrent() -> Bool {
        checks += 1
        return checks <= allowedChecks
    }
}

/// A gate a test can suspend the injected IDE fetch on, so the interleaved main-actor
/// work (a deletion, a competing refresh) happens exactly while the fetch is in flight.
@MainActor
private final class IDEFetchGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { self.continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// Exercises the *reentrant* behaviour of `refreshImportedIDEQuotas()`.
///
/// `QuotaViewModel` is `@MainActor`, which serialises its state but does **not** make a
/// method atomic: every `await` is a suspension point at which other main-actor work
/// runs. These tests suspend inside the IDE fetch, mutate the view model from the test
/// body (i.e. exactly as a user action would), resume, and assert the refresh honours
/// the state as it is at write time rather than the snapshot it took before the await.
final class IDEQuotaRefreshReentrancyTests: XCTestCase {
    private static let persistedIDEQuotasKey = "persisted.ideQuotas"

    private func quota(_ percentage: Double, lastUpdated: Date) -> ProviderQuotaData {
        ProviderQuotaData(
            models: [ModelQuota(name: "cursor-fast", percentage: percentage, resetTime: "")],
            lastUpdated: lastUpdated
        )
    }

    /// The refresh persists to `UserDefaults.standard`; keep the developer's real data.
    private func withPersistedIDEQuotasRestored(_ body: () async -> Void) async {
        let saved = UserDefaults.standard.data(forKey: Self.persistedIDEQuotasKey)
        await body()
        if let saved {
            UserDefaults.standard.set(saved, forKey: Self.persistedIDEQuotasKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.persistedIDEQuotasKey)
        }
    }

    private func persistedIDEQuotas() -> [String: [String: ProviderQuotaData]] {
        guard let data = UserDefaults.standard.data(forKey: Self.persistedIDEQuotasKey),
              let decoded = try? JSONDecoder().decode(
                  [String: [String: ProviderQuotaData]].self, from: data
              ) else { return [:] }
        return decoded
    }

    /// The regression the review called out: an account deleted (issue #213 / PR #472)
    /// while the IDE fetch is suspended must not be restored by the write that follows.
    /// A pre-await snapshot of `providerQuotas` would resurrect it — both in memory and
    /// in the persisted snapshot the next launch reads.
    @MainActor
    func testGlobalRefreshDoesNotResurrectAccountDeletedWhileFetchIsSuspended() async {
        await withPersistedIDEQuotasRestored {
            let viewModel = QuotaViewModel()
            let kept = "kept@example.com"
            let deleted = "deleted@example.com"
            let stale = quota(10, lastUpdated: Date(timeIntervalSince1970: 1_000))
            let fresh = quota(75, lastUpdated: Date(timeIntervalSince1970: 2_000))

            viewModel.providerQuotas = [.cursor: [kept: stale, deleted: stale]]

            let gate = IDEFetchGate()
            let suspendedInFetch = expectation(description: "IDE fetch suspended")
            viewModel.ideQuotaFetchHookForTesting = { provider in
                guard provider == .cursor else { return [:] }
                suspendedInFetch.fulfill()
                await gate.wait()
                // The IDE database still knows about both accounts.
                return [kept: fresh, deleted: fresh]
            }

            let refresh = Task { await viewModel.refreshImportedIDEQuotas() }
            await fulfillment(of: [suspendedInFetch], timeout: 5)

            // Reentrant main-actor work: the user deletes the imported account while the
            // fetch is still awaiting.
            viewModel.providerQuotas[.cursor]?.removeValue(forKey: deleted)

            gate.open()
            await refresh.value

            XCTAssertNil(
                viewModel.providerQuotas[.cursor]?[deleted],
                "An account deleted during the fetch must not be restored from the pre-await snapshot"
            )
            XCTAssertNil(
                persistedIDEQuotas()[AIProvider.cursor.rawValue]?[deleted],
                "The resurrected account must not reach the persisted snapshot either"
            )
            XCTAssertEqual(
                viewModel.providerQuotas[.cursor]?[kept]?.models.first?.percentage,
                75,
                "The surviving account still receives the fresh quota (issue #163)"
            )
        }
    }

    /// The whole provider disappearing mid-fetch (the last imported account deleted) must
    /// not re-create the provider entry from the snapshot taken before the await.
    @MainActor
    func testGlobalRefreshDoesNotRestoreProviderRemovedWhileFetchIsSuspended() async {
        await withPersistedIDEQuotasRestored {
            let viewModel = QuotaViewModel()
            let account = "only@example.com"
            viewModel.providerQuotas = [
                .cursor: [account: quota(10, lastUpdated: Date(timeIntervalSince1970: 1_000))]
            ]

            let gate = IDEFetchGate()
            let suspendedInFetch = expectation(description: "IDE fetch suspended")
            viewModel.ideQuotaFetchHookForTesting = { _ in
                suspendedInFetch.fulfill()
                await gate.wait()
                return [account: self.quota(90, lastUpdated: Date(timeIntervalSince1970: 2_000))]
            }

            let refresh = Task { await viewModel.refreshImportedIDEQuotas() }
            await fulfillment(of: [suspendedInFetch], timeout: 5)

            viewModel.providerQuotas.removeValue(forKey: .cursor)

            gate.open()
            await refresh.value

            XCTAssertNil(
                viewModel.providerQuotas[.cursor],
                "Removing the provider during the fetch must survive the refresh write"
            )
        }
    }

    /// 通过可控挂起验证取消后不覆盖既有配额，并释放刷新协调槽。
    @MainActor
    func testCancelledGlobalRefreshDoesNotApplyStaleIDEQuota() async {
        await withPersistedIDEQuotasRestored {
            let viewModel = QuotaViewModel()
            let account = "user@example.com"
            let stale = quota(10, lastUpdated: Date(timeIntervalSince1970: 1_000))
            let fresh = quota(90, lastUpdated: Date(timeIntervalSince1970: 2_000))
            viewModel.providerQuotas = [.cursor: [account: stale]]

            let gate = IDEFetchGate()
            let suspendedInFetch = expectation(description: "IDE fetch suspended")
            viewModel.ideQuotaFetchHookForTesting = { provider in
                guard provider == .cursor else { return [:] }
                suspendedInFetch.fulfill()
                await gate.wait()
                return [account: fresh]
            }

            let refresh = Task { await viewModel.refreshImportedIDEQuotas() }
            await fulfillment(of: [suspendedInFetch], timeout: 5)
            refresh.cancel()
            gate.open()
            await refresh.value

            XCTAssertEqual(
                viewModel.providerQuotas[.cursor]?[account]?.lastUpdated,
                stale.lastUpdated,
                "取消后的刷新不得发布挂起期间返回的配额"
            )
        }
    }

    /// The IDE refresh holds the provider's refresh-coordination slot for the *whole*
    /// fetch/write, so a scoped refresh cannot start midway through it and be clobbered.
    /// `isRefreshBlocked(for:)` reads the same set `beginScopedRefresh` inserts into, so
    /// this is also what disables the per-account refresh button in `QuotaScreen` and
    /// `StatusBarMenuBuilder` while the fetch is in flight.
    @MainActor
    func testScopedRefreshIsBlockedWhileImportedIDEFetchIsSuspended() async {
        await withPersistedIDEQuotasRestored {
            let viewModel = QuotaViewModel()
            let account = "user@example.com"
            let stale = quota(10, lastUpdated: Date(timeIntervalSince1970: 1_000))
            let fresh = quota(60, lastUpdated: Date(timeIntervalSince1970: 2_000))
            viewModel.providerQuotas = [.cursor: [account: stale]]

            let accountID = QuotaAccountID(provider: .cursor, accountKey: account)
            XCTAssertFalse(viewModel.isRefreshBlocked(for: accountID))

            let gate = IDEFetchGate()
            let suspendedInFetch = expectation(description: "IDE fetch suspended")
            var fetchCount = 0
            viewModel.ideQuotaFetchHookForTesting = { _ in
                fetchCount += 1
                suspendedInFetch.fulfill()
                await gate.wait()
                return [account: fresh]
            }

            let refresh = Task { await viewModel.refreshImportedIDEQuotas() }
            await fulfillment(of: [suspendedInFetch], timeout: 5)

            XCTAssertTrue(
                viewModel.isRefreshBlocked(for: accountID),
                "The coordination slot must be held across the fetch, not only before it"
            )
            XCTAssertTrue(viewModel.isRefreshing(provider: .cursor))

            // A scoped refresh requested now is rejected by the slot instead of racing the
            // in-flight write: it performs no fetch and leaves the quota untouched.
            await viewModel.refreshQuota(for: .cursor)
            XCTAssertEqual(
                viewModel.providerQuotas[.cursor]?[account]?.lastUpdated,
                stale.lastUpdated,
                "A scoped refresh must not run while the global IDE refresh holds the slot"
            )

            // A second global refresh is rejected by the same slot and issues no fetch.
            await viewModel.refreshImportedIDEQuotas()
            XCTAssertEqual(fetchCount, 1, "The slot must serialise overlapping IDE refreshes")

            gate.open()
            await refresh.value

            XCTAssertFalse(viewModel.isRefreshBlocked(for: accountID), "The slot must be released")
            XCTAssertEqual(viewModel.providerQuotas[.cursor]?[account]?.models.first?.percentage, 60)
        }
    }

    /// With nothing imported the refresh must not acquire the slot, fetch, or import —
    /// Cursor/Trae stay explicit-scan only (issue #29).
    @MainActor
    func testGlobalRefreshDoesNotFetchWhenNothingIsImported() async {
        await withPersistedIDEQuotasRestored {
            let viewModel = QuotaViewModel()
            viewModel.providerQuotas = [:]

            var fetchCount = 0
            viewModel.ideQuotaFetchHookForTesting = { _ in
                fetchCount += 1
                return ["user@example.com": self.quota(50, lastUpdated: Date())]
            }

            await viewModel.refreshImportedIDEQuotas()

            XCTAssertEqual(fetchCount, 0, "A refresh must not read the IDE databases without an explicit scan")
            XCTAssertTrue(viewModel.providerQuotas.isEmpty)
        }
    }
}
