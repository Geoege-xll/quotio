//
//  MonitorRefreshCoordinator.swift
//  Quotio
//

import Foundation

/// 原监控刷新协调器，按完整类型连同私有状态、嵌套 Flight、Task 与 Debug 钩子迁移。
/// 保留 issues 的 private(set)、同提供商同世代共享等待、失败退避、完成版本和快照收尾顺序。
/// 等待者仍复用原 Flight；账号世代变化后的结果拒绝与旧任务不得清除新任务的规则不变。
actor MonitorRefreshCoordinator {
    nonisolated let revision = MonitorStateRevision()
    private let discovery: MonitorAccountDiscovery
    private let snapshots: MonitorSnapshotStore
    private struct Flight {
        let id: UUID
        let revision: UInt64
        let task: Task<[String: ProviderQuotaData], Never>
    }
    private var inFlight: [AIProvider: Flight] = [:]
    private var retryAfter: [AIProvider: Date] = [:]
    private(set) var issues: [AIProvider: MonitorRefreshIssue] = [:]
    /// 普通刷新不会推进账号世代；单独记录各服务商已完成的刷新，避免启动快照覆盖并发结果。
    private var completedRefreshVersions: [AIProvider: UInt64] = [:]
    #if DEBUG
    /// 在等待网络结果前触发，测试用它确定多个等待者都已经进入同一轮刷新。
    private var waiterHookForTesting: (@Sendable () -> Void)?
    func setWaiterHookForTesting(_ hook: (@Sendable () -> Void)?) { waiterHookForTesting = hook }
    /// 测试可在快照读取完成后暂停启动流程，稳定复现同世代刷新的交错顺序。
    private var bootstrapLoadedHookForTesting: (@Sendable () async -> Void)?
    func setBootstrapLoadedHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        bootstrapLoadedHookForTesting = hook
    }
    #endif

    /// Generic account keys that represent the same underlying login as a more
    /// specific, higher-priority credential for the same provider (e.g. a
    /// nameless "Claude Code" native credential once "Claude Desktop" is also
    /// discovered). `discoverAccounts` hides these from the account list to
    /// avoid duplicate rows; `QuotaViewModel` uses the same table to keep quota
    /// data for hidden placeholders from lingering on the Quota screen.
    static let placeholderAccountKeys: [AIProvider: Set<String>] = [
        .copilot: ["github copilot"],
        .antigravity: ["antigravity"],
        .claude: ["claude code"],
        .codex: ["codex", "codex user"],
        .kiro: ["kiro"],
    ]

    /// 显式支持 GHE 主机范围的占位身份，账号发现和额度收尾共用，避免各自维护不一致的字符串。
    nonisolated static func isPlaceholder(provider: AIProvider, accountKey: String) -> Bool {
        if provider == .copilot { return GitHubHost.placeholderHost(accountKey: accountKey) != nil }
        return placeholderAccountKeys[provider]?.contains(accountKey.lowercased()) == true
    }

    init(
        discovery: MonitorAccountDiscovery = MonitorAccountDiscovery(),
        snapshots: MonitorSnapshotStore = MonitorSnapshotStore()
    ) {
        self.discovery = discovery
        self.snapshots = snapshots
    }

    func bootstrap() async -> MonitorRefreshBatch {
        let generation = revision.current
        let refreshVersions = completedRefreshVersions
        let snapshot = await snapshots.loadSnapshot()
        #if DEBUG
        if let bootstrapLoadedHookForTesting { await bootstrapLoadedHookForTesting() }
        #endif
        // 上次刷新失败时保留的额度仍可查看，但进入监控模式后必须继续显示失败状态。
        // 账号世代不涵盖普通刷新；逐服务商比较完成次数，保留读取期间的新失败或恢复结果。
        if revision.current == generation {
            for provider in Set(issues.keys).union(snapshot.issues.keys) {
                guard completedRefreshVersions[provider] == refreshVersions[provider] else { continue }
                issues[provider] = snapshot.issues[provider]
            }
        }
        return MonitorRefreshBatch(
            accounts: await discoverAccounts(merging: snapshot.quotas),
            quotas: snapshot.quotas,
            issues: issues,
            accountIssues: snapshot.accountIssues
        )
    }

    func discoverAccounts(merging quotas: [AIProvider: [String: ProviderQuotaData]] = [:]) async -> [MonitorAccount] {
        var accounts = await discovery.discover()
        accounts = Self.applyingQuotaDisplayNames(accounts, quotas: quotas)
        let disabledIDs = await discovery.disabledAccountIDs()
        let existingKeys = Set(accounts.map(\.deduplicationKey))
        var appendedKeys = existingKeys

        for (provider, accountQuotas) in quotas {
            let source: MonitorAccountSource
            switch provider {
            case .cursor, .trae: source = .localIDE
            case .glm, .warp, .clinePass, .factoryDroid, .openRouter, .amp: source = .apiKey
            default: source = .nativeCredential
            }
            for (accountKey, quota) in accountQuotas {
                let account = Self.makeQuotaDerivedAccount(
                    provider: provider,
                    accountKey: accountKey,
                    displayName: quota.accountDisplayName,
                    source: source,
                    disabledIDs: disabledIDs
                )
                guard appendedKeys.insert(account.deduplicationKey).inserted else { continue }
                accounts.append(account)
            }
        }
        accounts = Self.removingHiddenPlaceholders(accounts)
        return accounts.sorted {
            if $0.provider.displayName == $1.provider.displayName {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return $0.provider.displayName < $1.provider.displayName
        }
    }

    /// 发现收尾的纯投影；独立验证企业占位替换，不在测试中扫描用户真实凭据。
    nonisolated static func removingHiddenPlaceholders(_ accounts: [MonitorAccount]) -> [MonitorAccount] {
        accounts.filter { account in
            guard Self.isPlaceholder(provider: account.provider, accountKey: account.accountKey) else { return true }
            return !accounts.contains {
                $0.provider == account.provider
                    && $0.id != account.id
                    && !Self.isPlaceholder(provider: $0.provider, accountKey: $0.accountKey)
                    && $0.source.priority >= account.source.priority
                    && (account.provider != .copilot || GitHubHost.placeholderHost(accountKey: account.accountKey)
                        == GitHubHost.accountHost(accountKey: $0.accountKey))
            }
        }
    }

    nonisolated static func makeQuotaDerivedAccount(
        provider: AIProvider,
        accountKey: String,
        displayName: String? = nil,
        source: MonitorAccountSource,
        disabledIDs: Set<String>
    ) -> MonitorAccount {
        // Accounts imported from a local IDE (Cursor, Trae) exist only as imported quota
        // data with no owned credential, so removing that data fully deletes them and
        // they will not reappear on the next discovery pass (issue #213).
        var account = MonitorAccount.make(
            provider: provider,
            accountKey: accountKey,
            displayName: displayName,
            source: source,
            canDelete: provider.isImportedFromLocalIDE
        )
        account.isDisabled = disabledIDs.contains(account.id)
        return account
    }

    nonisolated static func applyingQuotaDisplayNames(
        _ accounts: [MonitorAccount],
        quotas: [AIProvider: [String: ProviderQuotaData]]
    ) -> [MonitorAccount] {
        accounts.map { account in
            guard let displayName = quotas[account.provider]?[account.accountKey]?.accountDisplayName else {
                return account
            }
            return MonitorAccount(
                id: account.id,
                provider: account.provider,
                accountKey: account.accountKey,
                displayName: displayName,
                source: account.source,
                credentialReference: account.credentialReference,
                canDelete: account.canDelete,
                isDisabled: account.isDisabled
            )
        }
    }

    func refresh(
        provider: AIProvider,
        force: Bool,
        previous: [String: ProviderQuotaData],
        credentialAvailability: MonitorCredentialAvailability = .unknown,
        credentialAccountKeys: Set<String>? = nil,
        operation: @escaping @Sendable () async -> [String: ProviderQuotaData]
    ) async -> [String: ProviderQuotaData] {
        let generation = revision.current
        // nil 表示无法完整枚举身份；空集合表示确认无可用凭据，不能把请求失败误当成删除。
        let previous = previous.filter { credentialAccountKeys?.contains($0.key) ?? true }
        if !force, let retry = retryAfter[provider], retry > Date() {
            return previous
        }
        let flight: Flight
        if let existing = inFlight[provider], existing.revision == generation {
            flight = existing
        } else {
            flight = Flight(id: UUID(), revision: generation, task: Task { await operation() })
            inFlight[provider] = flight
        }
        #if DEBUG
        waiterHookForTesting?()
        #endif
        let fetched = await flight.task.value
        // 所有等待者执行相同的世代检查，旧任务也不能清除后来启动的新任务登记。
        guard revision.current == generation, !Task.isCancelled else { return [:] }
        if inFlight[provider]?.id == flight.id { inFlight[provider] = nil }
        let fresh = fetched.filter { credentialAccountKeys?.contains($0.key) ?? true }
        // 即使本次成功后 issues 原本就为空，也要阻止并发 bootstrap 恢复磁盘上的旧失败。
        completedRefreshVersions[provider, default: 0] &+= 1

        if fresh.isEmpty, credentialAvailability == .missing {
            issues.removeValue(forKey: provider)
            retryAfter.removeValue(forKey: provider)
            return [:]
        }

        if fresh.isEmpty, !previous.isEmpty {
            issues[provider] = MonitorRefreshIssue(
                message: "monitor.refresh.failed".localizedStatic(),
                occurredAt: Date()
            )
            retryAfter[provider] = Date().addingTimeInterval(60)
            return previous
        }

        if !fresh.isEmpty {
            var merged = previous
            merged.merge(fresh) { _, new in new }
            if !(credentialAccountKeys ?? Set(previous.keys)).subtracting(fresh.keys).isEmpty {
                issues[provider] = MonitorRefreshIssue(
                    message: "monitor.refresh.partial".localizedStatic(),
                    occurredAt: Date()
                )
                retryAfter[provider] = Date().addingTimeInterval(60)
            } else {
                issues.removeValue(forKey: provider)
                retryAfter.removeValue(forKey: provider)
            }
            return merged
        }

        issues.removeValue(forKey: provider)
        retryAfter.removeValue(forKey: provider)
        return fresh
    }

    func finish(quotas: [AIProvider: [String: ProviderQuotaData]], accountIssues: [QuotaAccountID: MonitorRefreshIssue] = [:], revision expected: UInt64? = nil) async {
        // 调用方在捕获 quotas 的同一个同步段捕获世代；不能等存储 actor 收到调用才生成版本。
        let expected = expected ?? revision.current
        await snapshots.store(quotas, issues: issues, accountIssues: accountIssues, revision: expected, state: revision)
    }

    /// Forget every Monitor-owned trace of a single account: its persisted snapshot
    /// entry (`Monitor/snapshots-v1.json`) and any disabled flag it left behind in
    /// `Monitor/accounts-v1.json`.
    ///
    /// Unlike `finish(quotas:)` this never rewrites unrelated entries, so it is safe to
    /// call from whichever mode is active. Deleting an account imported from Cursor or
    /// Trae has to run in every mode: the account row is shown outside Monitor mode, but
    /// `bootstrap()` reads the snapshot back when Monitor mode is entered, which would
    /// otherwise resurrect the deleted account (issue #213).
    func forgetSnapshotAccount(provider: AIProvider, accountKey: String, revision expected: UInt64? = nil, mutationAccountID: String? = nil) async {
        // `MonitorAccount.make` derives the id from provider + normalized account key, so
        // this resolves the same id the Monitor row used when it was disabled.
        let accountID = MonitorAccount.make(
            provider: provider,
            accountKey: accountKey,
            source: .localIDE
        ).id
        let mutationID = mutationAccountID ?? accountID
        let generation = expected ?? revision.advance(accountID: mutationID)
        await snapshots.removeAccount(provider: provider, accountKey: accountKey, revision: generation, state: revision, mutationAccountID: mutationID)
        guard await discovery.disabledAccountIDs().contains(accountID), revision.isCurrent(generation, accountID: mutationID) else { return }
        await discovery.setDisabled(false, accountID: accountID, revision: generation, state: revision, mutationAccountID: mutationID)
    }

    func currentIssues() -> [AIProvider: MonitorRefreshIssue] {
        issues
    }

    func setDisabled(_ disabled: Bool, accountID: String, revision expected: UInt64? = nil) async {
        let generation = expected ?? revision.advance(accountID: accountID)
        await discovery.setDisabled(disabled, accountID: accountID, revision: generation, state: revision)
    }

    func deleteOwnedAccount(accountID: String, revision expected: UInt64? = nil) async {
        let generation = expected ?? revision.advance(accountID: accountID)
        await MonitorCredentialVault.shared.delete(accountID: accountID, revision: generation, state: revision)
    }
}

