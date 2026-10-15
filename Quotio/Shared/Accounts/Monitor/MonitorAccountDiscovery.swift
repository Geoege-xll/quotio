//
//  MonitorAccountDiscovery.swift
//  Quotio
//

import Foundation

/// 原监控账号发现 actor；依赖实例、发现顺序、来源优先级、Codex 身份分组与禁用回填完整保留。
/// 各提供商的读取和原有挂起点不重排，不增加全局去重规则或持久缓存；空白辅助仅调整调用位置。
actor MonitorAccountDiscovery {
    private let vault: MonitorCredentialStore
    private let directAuthService: DirectAuthFileService
    private let metadata: MonitorMetadataStore
    private let codexFetcher: CodexCLIQuotaFetcher

    init(
        vault: MonitorCredentialStore = MonitorCredentialVault.shared,
        directAuthService: DirectAuthFileService = DirectAuthFileService(),
        metadata: MonitorMetadataStore = .shared,
        codexFetcher: CodexCLIQuotaFetcher? = nil
    ) {
        self.vault = vault
        self.directAuthService = directAuthService
        self.metadata = metadata
        self.codexFetcher = codexFetcher ?? CodexCLIQuotaFetcher(vault: vault, metadata: metadata)
    }

    func discover() async -> [MonitorAccount] {
        let legacyFiles = await directAuthService.scanAllAuthFiles()
        let codexAliases = Self.codexAliases(from: legacyFiles)
        var candidates = await canonicalizeCodexAccounts(await vault.accounts(), aliases: codexAliases)
        candidates.append(contentsOf: await discoverNativeFiles(codexAliases: codexAliases))
        candidates.append(contentsOf: discoverNativeKeychains(codexAliases: codexAliases))
        let legacy = legacyFiles.map(MonitorAccount.makeLegacy)
        candidates.append(contentsOf: legacy)
        // Codex 统一按实际凭据 account ID 归并，并保留源 ID、删除权限和所有来源的禁用状态。
        candidates.removeAll { $0.provider == .codex }
        candidates.append(contentsOf: await codexFetcher.monitorCredentialGroups().map(\.account))

        let disabled = await metadata.disabledAccountIDs()
        return Self.selectPreferred(candidates, disabledIDs: disabled)
    }

    nonisolated static func selectPreferred(
        _ candidates: [MonitorAccount],
        disabledIDs: Set<String> = []
    ) -> [MonitorAccount] {
        var selected: [String: MonitorAccount] = [:]
        for var account in candidates {
            account.isDisabled = account.isDisabled || disabledIDs.contains(account.id)
            let key = account.deduplicationKey
            if let existing = selected[key], existing.source.priority >= account.source.priority {
                continue
            }
            selected[key] = account
        }
        return selected.values.sorted {
            if $0.provider.displayName == $1.provider.displayName {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return $0.provider.displayName < $1.provider.displayName
        }
    }

    nonisolated static func canonicalizeCodexAccount(
        _ account: MonitorAccount,
        accountID: String?,
        aliases: [String: String]
    ) -> MonitorAccount {
        guard account.provider == .codex,
              let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              let canonicalKey = aliases[accountID] else { return account }
        return MonitorAccount(
            id: account.id,
            provider: account.provider,
            accountKey: canonicalKey,
            displayName: account.displayName,
            source: account.source,
            credentialReference: account.credentialReference,
            canDelete: account.canDelete,
            isDisabled: account.isDisabled
        )
    }

    private nonisolated static func codexAliases(from files: [DirectAuthFile]) -> [String: String] {
        var keysByAccountID: [String: Set<String>] = [:]
        for file in files where file.provider == .codex {
            guard let json = MonitorIdentity.json(at: file.filePath) else { continue }
            let accountID = (json["account_id"] as? String)
                ?? MonitorIdentity.jwtNestedString(
                    json["id_token"] as? String,
                    namespace: "https://api.openai.com/auth",
                    claim: "chatgpt_account_id"
                )
            guard let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !accountID.isEmpty else { continue }
            keysByAccountID[accountID, default: []].insert(file.filename.codexFilenameKey)
        }
        return keysByAccountID.reduce(into: [:]) { aliases, entry in
            guard entry.value.count == 1, let key = entry.value.first else { return }
            aliases[entry.key] = key
        }
    }

    private func canonicalizeCodexAccounts(
        _ accounts: [MonitorAccount],
        aliases: [String: String]
    ) async -> [MonitorAccount] {
        var result: [MonitorAccount] = []
        for account in accounts {
            guard account.provider == .codex,
                  let credential = await vault.credential(for: account.id) else {
                result.append(account)
                continue
            }
            let accountID = credential.accountID
                ?? MonitorIdentity.jwtNestedString(
                    credential.idToken,
                    namespace: "https://api.openai.com/auth",
                    claim: "chatgpt_account_id"
                )
            result.append(Self.canonicalizeCodexAccount(account, accountID: accountID, aliases: aliases))
        }
        return result
    }

    func setDisabled(_ disabled: Bool, accountID: String, revision: UInt64? = nil, state: MonitorStateRevision? = nil, mutationAccountID: String? = nil) async {
        if let group = await codexFetcher.monitorCredentialGroups().first(where: { $0.account.id == accountID }) {
            // 同一逻辑账号的禁用变更一次提交，重新启用也不会遗留隐藏来源的禁用标记。
            // 新禁用只写稳定身份，不能留下会在邮箱消歧后误禁用另一账号的邮箱标记。
            // 启用则同时清理旧版原始 ID，包括当前有歧义的邮箱，防止拓扑恢复后旧禁用回流。
            var ids: Set<String> = [group.stableDisabledID]
            if !disabled {
                ids.formUnion(group.sources.map { $0.account.id })
                // 来源从原生变为自有后主标识会变化，同时清理之前按 account ID 保存的稳定标记。
                ids.formUnion(group.sources.map { CodexMonitorGroup.disabledID(for: $0.identity) })
                ids.insert(group.account.id)
                ids.insert(MonitorAccount.make(provider: .codex, accountKey: group.account.accountKey, source: group.account.source).id)
            }
            try? await metadata.setDisabled(disabled, accountIDs: ids, revision: revision, state: state, mutationAccountID: mutationAccountID ?? accountID)
            return
        }
        try? await metadata.setDisabled(disabled, accountIDs: [accountID], revision: revision, state: state, mutationAccountID: mutationAccountID ?? accountID)
    }

    func disabledAccountIDs() async -> Set<String> {
        await metadata.disabledAccountIDs()
    }

    private func discoverNativeFiles(codexAliases: [String: String]) async -> [MonitorAccount] {
        var accounts: [MonitorAccount] = []
        accounts.append(contentsOf: discoverCodexFiles(aliases: codexAliases))
        accounts.append(contentsOf: discoverClaudeFile())
        if ClaudeDesktopCredentialReader.hasCredentialMaterial() {
            accounts.append(.make(
                provider: .claude,
                accountKey: "Claude Desktop",
                source: .localIDE,
                credentialReference: "claude-desktop"
            ))
        }
        accounts.append(contentsOf: discoverCopilotFiles())
        accounts.append(contentsOf: discoverKiroFile())
        accounts.append(contentsOf: discoverFactoryDroidCredential())
        accounts.append(contentsOf: discoverAmpCredential())
        accounts.append(contentsOf: discoverDevinCredential())
        accounts.append(contentsOf: discoverGrokCredentials())
        let antigravityDatabase = MonitorIdentity.expand("~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb")
        if let token = try? await AntigravityDatabaseService().getCurrentTokenInfo(),
           MonitorIdentity.nilIfBlank(token.accessToken) != nil || MonitorIdentity.nilIfBlank(token.refreshToken) != nil {
            accounts.append(.make(
                provider: .antigravity,
                accountKey: "Antigravity",
                source: .localIDE,
                credentialReference: antigravityDatabase
            ))
        }
        return accounts
    }

    private func discoverFactoryDroidCredential() -> [MonitorAccount] {
        guard let credential = FactoryDroidCredentialReader.load() else { return [] }
        return [FactoryDroidQuotaFetcher.localAccount(for: credential)]
    }

    private func discoverAmpCredential() -> [MonitorAccount] {
        guard let credential = AmpNativeCredentialReader.load() else { return [] }
        return [AmpQuotaFetcher.localAccount(provider: .amp, sourcePath: credential.sourcePath)]
    }

    private func discoverDevinCredential() -> [MonitorAccount] {
        let credentialsPath = MonitorIdentity.expand(DevinQuotaFetcher.credentialsPath)
        if let text = try? String(contentsOfFile: credentialsPath, encoding: .utf8),
           DevinQuotaFetcher.parseCredentialsTOML(text) != nil {
            return [.make(
                provider: .devin,
                accountKey: "Devin",
                source: .nativeCredential,
                credentialReference: credentialsPath
            )]
        }

        let databasePath = MonitorIdentity.expand(DevinQuotaFetcher.stateDBPath)
        guard DevinQuotaFetcher.loadAppCredential(path: databasePath) != nil else { return [] }
        return [.make(
            provider: .devin,
            accountKey: "Devin",
            source: .localIDE,
            credentialReference: databasePath
        )]
    }

    private func discoverGrokCredentials() -> [MonitorAccount] {
        let path = MonitorIdentity.expand(GrokQuotaFetcher.authPath)
        return GrokQuotaFetcher.loadCandidates(path: path).map { candidate in
            .make(
                provider: .grok,
                accountKey: candidate.entryKey,
                displayName: candidate.displayName,
                source: .nativeCredential,
                credentialReference: path + "#" + candidate.entryKey
            )
        }
    }

    private func discoverCodexFiles(aliases: [String: String]) -> [MonitorAccount] {
        var paths: [String] = []
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            paths.append((home as NSString).appendingPathComponent("auth.json"))
        }
        paths.append(contentsOf: ["~/.config/codex/auth.json", "~/.codex/auth.json"].map(MonitorIdentity.expand))
        return paths.compactMap { path in
            guard let json = MonitorIdentity.json(at: path),
                  let tokens = json["tokens"] as? [String: Any],
                  (tokens["access_token"] as? String)?.isEmpty == false else { return nil }
            let email = MonitorIdentity.jwtString(tokens["id_token"] as? String, claim: "email")
            let accountID = (tokens["account_id"] as? String)
                ?? MonitorIdentity.jwtNestedString(tokens["id_token"] as? String, namespace: "https://api.openai.com/auth", claim: "chatgpt_account_id")
            let key = email ?? accountID ?? "Codex"
            let account = MonitorAccount.make(provider: .codex, accountKey: key, source: .nativeCredential, credentialReference: path)
            return Self.canonicalizeCodexAccount(account, accountID: accountID, aliases: aliases)
        }
    }

    private func discoverClaudeFile() -> [MonitorAccount] {
        let base = ClaudeCredentialOwnership.configDirectory(environment: ProcessInfo.processInfo.environment)
        let path = (base as NSString).appendingPathComponent(".credentials.json")
        guard let json = MonitorIdentity.json(at: path),
              let oauth = json["claudeAiOauth"] as? [String: Any],
              (oauth["accessToken"] as? String)?.isEmpty == false else { return [] }
        let email = (oauth["email"] as? String) ?? "Claude Code"
        return [.make(provider: .claude, accountKey: email, source: .nativeCredential, credentialReference: path)]
    }

    private func discoverCopilotFiles() -> [MonitorAccount] {
        // 与取数共用原生解析器，保留受支持主机和用户；不同企业同名用户不能折叠成一个占位账号。
        CopilotQuotaFetcher.nativeCredentials(paths: CopilotQuotaFetcher.defaultNativePaths).map { value in
            let key = value.host.accountKey(value.username ?? "GitHub Copilot")
            return MonitorAccount.make(provider: .copilot, accountKey: key, source: .nativeCredential, credentialReference: value.path)
        }
    }

    private func discoverKiroFile() -> [MonitorAccount] {
        let path = MonitorIdentity.expand("~/.aws/sso/cache/kiro-auth-token.json")
        guard let json = MonitorIdentity.json(at: path),
              (json["accessToken"] as? String ?? json["access_token"] as? String)?.isEmpty == false else { return [] }
        let key = (json["email"] as? String) ?? (json["profileArn"] as? String) ?? "Kiro"
        return [.make(provider: .kiro, accountKey: key, source: .nativeCredential, credentialReference: path)]
    }

    private func discoverNativeKeychains(codexAliases: [String: String]) -> [MonitorAccount] {
        var accounts: [MonitorAccount] = []
        if let data = KeychainHelper.readExternalCredential(service: "Codex Auth"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tokens = json["tokens"] as? [String: Any],
           (tokens["access_token"] as? String)?.isEmpty == false {
            let idToken = tokens["id_token"] as? String
            let email = MonitorIdentity.jwtString(idToken, claim: "email") ?? "Codex"
            let accountID = (tokens["account_id"] as? String)
                ?? MonitorIdentity.jwtNestedString(idToken, namespace: "https://api.openai.com/auth", claim: "chatgpt_account_id")
            let account = MonitorAccount.make(provider: .codex, accountKey: email, source: .nativeCredential, credentialReference: "keychain:Codex Auth")
            accounts.append(Self.canonicalizeCodexAccount(account, accountID: accountID, aliases: codexAliases))
        }
        let claudeService = ClaudeCredentialOwnership.keychainService(environment: ProcessInfo.processInfo.environment)
        if let data = KeychainHelper.readExternalCredential(service: claudeService),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = json["claudeAiOauth"] as? [String: Any],
           (oauth["accessToken"] as? String)?.isEmpty == false {
            accounts.append(.make(provider: .claude, accountKey: (oauth["email"] as? String) ?? "Claude Code", source: .nativeCredential, credentialReference: "keychain:" + claudeService))
        }
        return accounts
    }
}

