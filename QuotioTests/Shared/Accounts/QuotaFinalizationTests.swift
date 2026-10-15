import XCTest
@testable import QuotioPlus

/// 第九批收尾回归：验证展示读取与主类真实槽位联动，以及切换门面、密钥草稿的既有约定。
/// 偏好使用临时 suite，请求使用离线 URLProtocol；不启动 CPA、不读取账号目录或执行 IDE 切换。
/// VM 仍沿用原共享基础设施构造，关闭后台服务仅隔离本测试触发的刷新和调度。
@MainActor
final class QuotaFinalizationTests: XCTestCase {
    private func fixture() throws -> QuotaViewModel {
        let suite = "quotio-finalization-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(OperatingMode.localProxy.rawValue, forKey: "operatingMode")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = QuotaViewModel(
            directAuthService: DirectAuthFileService(authDirectory: directory), startsBackgroundServices: false,
            modeManager: OperatingModeManager(defaults: defaults), menuBarSettings: MenuBarSettingsManager(defaults: defaults),
            refreshSettings: RefreshSettingsManager(defaults: defaults), warmupSettings: WarmupSettingsManager(defaults: defaults)
        )
        addTeardownBlock { @MainActor in
            model.stopQuotaAutoRefresh()
            defaults.removePersistentDomain(forName: suite)
        }
        return model
    }

    /// 复用已有跨类夹具，唯一随机主机保证请求不会访问真实管理端或其他用例的状态。
    private func client(_ response: @escaping @Sendable (URLRequest, Int) -> LifecycleHTTPState.Response)
        -> (ManagementAPIClient, LifecycleHTTPState) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let state = LifecycleHTTPState(response: response)
        LifecycleHTTPProtocol.register(state, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleHTTPProtocol.self]
        let client = ManagementAPIClient(baseURL: "https://" + host + ManagementAPIClient.managementPath,
                                         authKey: "fixture", configuration: configuration)
        addTeardownBlock {
            await client.invalidate()
            LifecycleHTTPProtocol.remove(host: host)
        }
        return (client, state)
    }

    func testPresentationTracksActualRefreshSlotsAndCurrentDirectory() throws {
        let model = try fixture()
        model.authFiles = try JSONDecoder().decode([AuthFile].self, from: Data(#"[{"name":"native","provider":"claude","status":"active"},{"name":"legacy","provider":"claude","status":"ready"},{"name":"failed","provider":"codex","status":"error"},{"name":"unknown","provider":"fixture-unknown","status":"error"}]"#.utf8))
        XCTAssertEqual(model.totalAccounts, 4)
        XCTAssertEqual(model.readyAccounts, 2)
        XCTAssertEqual(model.authFilesByProvider[.claude]?.map(\.name), ["native", "legacy"])
        XCTAssertEqual(model.authFilesByProvider.values.flatMap { $0 }.count, 3)

        // 经主类原申请／释放入口验证展示，不能直接改写 private(set) 集合来制造成功样本。
        let account = QuotaAccountID(provider: .claude, accountKey: "native")
        let sibling = QuotaAccountID(provider: .claude, accountKey: "legacy")
        XCTAssertTrue(model.beginScopedRefresh(provider: .claude, account: account))
        XCTAssertTrue(model.isLoadingQuotas)
        XCTAssertTrue(model.isRefreshing(provider: .claude))
        XCTAssertTrue(model.isRefreshing(account: account))
        XCTAssertFalse(model.isRefreshing(account: sibling))
        XCTAssertFalse(model.beginBatchRefresh(providers: [.claude]))
        model.endScopedRefresh(provider: .claude, account: account)
        XCTAssertTrue(model.beginBatchRefresh(providers: [.claude]))
        XCTAssertTrue(model.isRefreshing(account: sibling))
        model.endBatchRefresh(providers: [.claude])
        XCTAssertFalse(model.isLoadingQuotas)
        XCTAssertFalse(model.beginScopedRefresh(provider: .qwen))
        model.authFiles.removeFirst()
        XCTAssertEqual(model.totalAccounts, 3)
        XCTAssertEqual(model.readyAccounts, 1)
        XCTAssertEqual(model.authFilesByProvider[.claude]?.map(\.name), ["legacy"])
    }

    func testMonitorPresentationKeepsIssuePriorityAndLiveCadence() throws {
        let model = try fixture(), now = Date()
        let account = MonitorAccount.make(provider: .claude, accountKey: "work", source: .nativeCredential)
        let identity = QuotaAccountID(provider: .claude, accountKey: "work")
        model.monitorIssues[.claude] = MonitorRefreshIssue(message: "provider failure", occurredAt: now)
        model.monitorAccountIssues[identity] = MonitorRefreshIssue(message: "account failure", occurredAt: now)
        XCTAssertEqual(model.monitorStatus(for: account).message, "account failure")
        model.monitorAccountIssues.removeValue(forKey: identity)
        XCTAssertEqual(model.monitorStatus(for: account).message, "provider failure")

        // 新观察使旧错误失效，但不在只读展示中清理错误表；随后频率变更应即时改变陈旧判定。
        model.providerQuotas[.claude] = ["work": ProviderQuotaData(models: [], lastUpdated: now.addingTimeInterval(10))]
        XCTAssertEqual(model.monitorStatus(for: account).status, "ready")
        XCTAssertNotNil(model.monitorIssues[.claude])
        model.monitorIssues.removeAll()
        model.refreshSettings.refreshCadence = .manual
        model.providerQuotas[.claude] = ["work": ProviderQuotaData(models: [], lastUpdated: now.addingTimeInterval(-700))]
        XCTAssertEqual(model.monitorStatus(for: account).status, "outdated")
        model.refreshSettings.refreshCadence = .fifteenMinutes
        XCTAssertEqual(model.monitorStatus(for: account).status, "ready")
    }

    func testAntigravityConfirmationCancelAndDismissUseOriginalSwitcher() throws {
        let model = try fixture(), switcher = model.antigravitySwitcher
        let previousState = switcher.switchState, previousAccount = switcher.currentActiveAccount
        defer {
            switcher.switchState = previousState
            switcher.currentActiveAccount = previousAccount
        }
        // 只驱动原切换器内存状态，禁止 executeSwitch 或 detect 触及用户 IDE、凭据和进程。
        switcher.currentActiveAccount = AntigravityActiveAccount(email: "Work@example.com", detectedAt: Date())
        XCTAssertTrue(model.isAntigravityAccountActive(email: "work@example.com"))
        XCTAssertFalse(model.isAntigravityAccountActive(email: ""))
        model.beginAntigravitySwitch(accountId: "fixture", email: "next@example.com")
        XCTAssertEqual(switcher.switchState, .confirming(accountId: "fixture", accountEmail: "next@example.com"))
        model.cancelAntigravitySwitch()
        XCTAssertEqual(switcher.switchState, .idle)
        switcher.switchState = .success(accountId: "fixture")
        model.dismissAntigravitySwitchResult()
        XCTAssertEqual(switcher.switchState, .idle)
        XCTAssertEqual(switcher.currentActiveAccount?.email, "Work@example.com")
    }

    func testInvalidAPIKeyDraftsDoNotSendRequestsOrOccupyMutationGuard() async throws {
        let model = try fixture()
        let (client, state) = client { _, _ in .replyStatus("{}", 401) }
        model.setAuthImportClientForTesting(client)
        model.apiKeys = ["existing"]
        let emptyAdded = await model.addAPIKey("  \n")
        let duplicateAdded = await model.addAPIKey(" existing ")
        let emptyUpdated = await model.updateAPIKey(old: "existing", new: " ")
        XCTAssertFalse(emptyAdded)
        XCTAssertFalse(duplicateAdded)
        XCTAssertFalse(emptyUpdated)
        XCTAssertEqual(state.requestCount, 0)
        XCTAssertEqual(model.apiKeys, ["existing"])
        XCTAssertFalse(model.isMutatingAPIKeys)
    }

    func testAPIKeyWriteFailurePreservesConfirmedListAndDraftResult() async throws {
        let model = try fixture()
        let (client, state) = client { request, _ in
            request.httpMethod == "GET" ? .reply(#"["existing"]"#) : .replyStatus("{}", 401)
        }
        model.setAuthImportClientForTesting(client)
        model.apiKeys = ["existing"]
        let updated = await model.updateAPIKey(old: "existing", new: "replacement")
        XCTAssertFalse(updated, "失败返回值继续要求界面保留草稿")
        XCTAssertEqual(state.requests.map(\.method), ["GET", "PUT"])
        XCTAssertEqual(model.apiKeys, ["existing"])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isMutatingAPIKeys)
    }

    func testAPIKeyPendingWriteRejectsSecondEditAndCancellationReleasesGuard() async throws {
        let model = try fixture()
        let started = expectation(description: "首个修改已进入离线挂起请求")
        let (client, state) = client { request, count in
            if count == 1 { started.fulfill(); return .hold }
            return request.httpMethod == "GET" ? .reply(#"["existing"]"#) : .reply(#"{"status":"ok","config-version":8}"#)
        }
        model.setAuthImportClientForTesting(client)
        model.apiKeys = ["existing"]
        let pending = Task { await model.addAPIKey("pending") }
        defer { pending.cancel() }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(model.isMutatingAPIKeys)
        let secondEdit = await model.updateAPIKey(old: "existing", new: "second")
        let secondDelete = await model.deleteAPIKey("existing")
        XCTAssertFalse(secondEdit)
        XCTAssertFalse(secondDelete)
        XCTAssertEqual(state.requestCount, 1)
        pending.cancel()
        let cancelledResult = await pending.value
        XCTAssertFalse(cancelledResult)
        XCTAssertEqual(model.apiKeys, ["existing"])
        XCTAssertFalse(model.isMutatingAPIKeys)

        // 取消释放后仍可成功写入；true 与清空旧错误保持原页面关闭草稿的约定。
        let added = await model.addAPIKey(" after-cancel ")
        XCTAssertTrue(added)
        XCTAssertEqual(model.apiKeys, ["existing", "after-cancel"])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isMutatingAPIKeys)
        XCTAssertEqual(state.requests.map(\.method), ["GET", "GET", "PUT"])
    }
}
