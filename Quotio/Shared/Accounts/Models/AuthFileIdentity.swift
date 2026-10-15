import Foundation

/// CPA 会同时返回磁盘元数据和运行期记录；它们是同一凭据的两种描述。
/// 对照 EasyCLIProxyAPI 的 dedupeAuthFiles：同文件的唯一索引可吸收无索引记录，
/// 不同有效索引不能合并。这里只处理已解码的元数据，不读取令牌或认证文件内容。
nonisolated enum AuthFileIdentity {
    private struct FileID: Hashable {
        let provider: String
        let name: String
    }

    private static func fileID(_ file: AuthFile) -> FileID {
        FileID(provider: file.providerType?.rawValue ?? file.provider, name: file.name)
    }

    private static func index(_ file: AuthFile) -> String {
        file.authIndex?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func deduplicated(_ files: [AuthFile]) -> [AuthFile] {
        // 按首次出现顺序输出，避免 API 的磁盘／运行条目重排导致卡片跳动。
        let groups = Dictionary(grouping: files, by: fileID)
        var seen = Set<FileID>()
        let merged = files.flatMap { file -> [AuthFile] in
            let identity = fileID(file)
            guard seen.insert(identity).inserted, let entries = groups[identity] else { return [] }
            let indexes = Set(entries.map(index).filter { !$0.isEmpty })
            if indexes.count <= 1 { return [merge(entries)] }
            // 同名但索引冲突时，无索引记录也不能随便吸收到某一个运行凭据。
            var seenIndexes = Set<String>()
            return entries.compactMap { entry in
                let key = index(entry)
                guard seenIndexes.insert(key).inserted else { return nil }
                return merge(entries.filter { index($0) == key })
            }
        }
        let idCounts = merged.reduce(into: [String: Int]()) { $0[$1.id, default: 0] += 1 }
        return merged.map { file in
            guard idCounts[file.id, default: 0] > 1 else { return file }
            // CPA 不返回 id 时现有解码器回退到 name；同名不同索引／提供商会碰撞。
            // 仅修正内存展示和查找 ID，请求仍使用原 name/authIndex，不回写认证文件。
            let provider = file.providerType?.rawValue ?? file.provider
            let routingKey = AuthFile.cpaQuotaLookupKey(name: file.name, authIndex: file.authIndex)
            return merge([file], id: "credential:\(provider.utf8.count):\(provider):\(routingKey)")
        }
    }

    private static func merge(_ entries: [AuthFile], id: String? = nil) -> AuthFile {
        // 当前运行索引负责路由、状态和启停；磁盘记录补充文件归属、邮箱与套餐元数据。
        // 与官方按文件信息补充的原则一致，同时不让旧磁盘 error 覆盖运行期的新状态。
        let primary = entries.first { !index($0).isEmpty } ?? entries[0]
        let stored = entries.first { $0.source == "file" }
            ?? entries.first { $0.path?.isEmpty == false && $0.runtimeOnly != true }
        func value(_ keyPath: KeyPath<AuthFile, String?>) -> String? {
            ([primary] + entries).compactMap { $0[keyPath: keyPath] }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        var metadata = primary.quotaMetadata
        for entry in entries {
            metadata.projectID = metadata.projectID ?? entry.quotaProjectID
            metadata.accountID = metadata.accountID ?? entry.quotaAccountID
            metadata.plan = metadata.plan ?? entry.quotaPlan
            metadata.userID = metadata.userID ?? entry.quotaUserID
            // 运行记录可能省略主机，由同文件磁盘记录补齐；冲突主机不能退成公共账号身份。
            if let host = entry.quotaMetadata.githubHost {
                metadata.githubHost = metadata.githubHost.map { $0 == host ? $0 : "invalid-host" } ?? host
            }
        }
        return AuthFile(id: id ?? primary.id, name: primary.name, provider: primary.provider,
            label: value(\.label), status: primary.status, statusMessage: primary.statusMessage,
            disabled: primary.disabled, unavailable: primary.unavailable,
            runtimeOnly: stored?.runtimeOnly ?? (stored == nil ? primary.runtimeOnly : false),
            source: stored?.source ?? primary.source, path: stored?.path ?? primary.path,
            email: value(\.email), accountType: value(\.accountType), account: value(\.account),
            authIndex: value(\.authIndex), createdAt: value(\.createdAt), updatedAt: value(\.updatedAt),
            lastRefresh: value(\.lastRefresh), quotaMetadata: metadata)
    }

    /// 目录身份与缓存身份分开：账号只来自当前目录，旧邮箱／文件名缓存附属到凭据。
    /// 每个别名必须只有一个目录所有者；同邮箱不同文件、同名不同索引均拒绝猜测。
    static func quotaAliases(mode: OperatingMode, proxyRunning: Bool, authFiles: [AuthFile],
                             directFiles: [DirectAuthFile]) -> [AIProvider: [String: String]] {
        guard mode == .localProxy else { return [:] }
        let current = deduplicated(authFiles)
        var claims: [AIProvider: [String: [String: String]]] = [:]
        var canonicalKeys: [AIProvider: Set<String>] = [:]
        func claim(provider: AIProvider, owner: String, canonical: String, aliases: [String]) {
            canonicalKeys[provider, default: []].insert(canonical)
            for alias in aliases where alias != canonical && !alias.isEmpty {
                claims[provider, default: [:]][alias, default: [:]][owner] = canonical
            }
        }
        if proxyRunning {
            let localAliasCounts = directFiles.reduce(into: [AIProvider: [String: Int]]()) {
                $0[$1.provider, default: [:]][$1.menuBarAccountKey, default: 0] += 1
            }
            for file in current {
                guard let provider = file.providerType else { continue }
                let key = file.quotaLookupKey
                let sameDiskFiles = directFiles.filter {
                    $0.provider == provider && $0.filename == file.name
                        && (provider != .copilot || GitHubHost.saved($0.githubHost) == GitHubHost.saved(file.quotaMetadata.githubHost))
                }
                let sameAPIRecords = authFiles.filter {
                    fileID($0) == fileID(file)
                        && (provider != .copilot || GitHubHost.saved($0.quotaMetadata.githubHost) == GitHubHost.saved(file.quotaMetadata.githubHost))
                }
                let unindexedKeys = [.codex, .copilot].contains(provider) ? []
                    : [AuthFile.cpaQuotaLookupKey(name: file.name, authIndex: nil)]
                // CPA 配置可指向另一个认证目录；同名文件若具有明确不同路径，不能
                // 仅凭邮箱或文件名把固定默认目录的额度迁过去。路径缺失时沿用唯一键规则。
                let conflictingDiskKeys = Set(sameDiskFiles.filter { disk in
                    guard let path = file.path, !path.isEmpty else { return false }
                    return URL(fileURLWithPath: path).standardizedFileURL.path
                        != URL(fileURLWithPath: disk.filePath).standardizedFileURL.path
                }.flatMap { [$0.menuBarAccountKey, $0.filename,
                    $0.filename.hasSuffix(".json") ? String($0.filename.dropLast(5)) : $0.filename] })
                claim(provider: provider, owner: key, canonical: key,
                    aliases: (file.legacyQuotaLookupKeys + sameDiskFiles.map(\.menuBarAccountKey)
                        + sameAPIRecords.map(\.quotaLookupKey) + unindexedKeys).filter {
                            !conflictingDiskKeys.contains($0)
                                && (localAliasCounts[provider]?[$0, default: 0] ?? 0) <= 1
                        })
            }
        } else {
            let counts = directFiles.reduce(into: [AIProvider: [String: Int]]()) {
                $0[$1.provider, default: [:]][$1.menuBarAccountKey, default: 0] += 1
            }
            for file in directFiles {
                // 本地邮箱键碰撞时维持现有只读缓存提示，不把两个 CPA 凭据压成一份额度。
                guard counts[file.provider]?[file.menuBarAccountKey] == 1 else { continue }
                let apiRecords = authFiles.filter {
                    guard $0.providerType == file.provider, $0.name == file.filename else { return false }
                    if file.provider == .copilot,
                       GitHubHost.saved($0.quotaMetadata.githubHost) != GitHubHost.saved(file.githubHost) { return false }
                    guard let path = $0.path, !path.isEmpty else { return true }
                    return URL(fileURLWithPath: path).standardizedFileURL.path
                        == URL(fileURLWithPath: file.filePath).standardizedFileURL.path
                }
                let indexes = Set(apiRecords.map(index).filter { !$0.isEmpty })
                // 官方规则把冲突索引视为不同凭据；停服也不能把它们不可逆压到同一个邮箱槽位。
                let compatibleKeys = indexes.count <= 1 ? apiRecords.map(\.quotaLookupKey) : []
                // Codex／Copilot 曾按文件名、邮箱或旧 login 固定账号。把这类兼容
                // 规则也放在同一个目录归属校验中，避免第二套迁移绕过路径／碰撞保护。
                let legacyKeys = [.codex, .copilot].contains(file.provider)
                    ? [file.filename, file.filename.hasSuffix(".json")
                        ? String(file.filename.dropLast(5)) : file.filename,
                       file.copilotUsesScopedIdentity ? nil : file.filename.copilotFilenameKey].compactMap { $0 }
                        + (file.copilotUsesScopedIdentity ? [] : [file.email].compactMap { $0 })
                        + (file.copilotUsesScopedIdentity ? [] : file.legacyIdentityKeys) : []
                claim(provider: file.provider, owner: file.id, canonical: file.menuBarAccountKey,
                    aliases: compatibleKeys + [file.filename] + legacyKeys)
            }
        }
        return claims.reduce(into: [:]) { result, entry in
            // 一个键本身仍代表独立目录凭据时，不能因为它也是别人旧别名而把它吞掉。
            result[entry.key] = entry.value.compactMapValues { owners in
                owners.count == 1 ? owners.values.first : nil
            }.filter { !canonicalKeys[entry.key, default: []].contains($0.key) }
        }
    }

    /// 已有规范槽位优先；没有时选该凭据最近的旧快照。只换键，不聚合或平均额度。
    static func rekey<Value>(_ entries: [AIProvider: [String: Value]],
                             aliases: [AIProvider: [String: String]],
                             prefer: (Value, Value) -> Bool) -> [AIProvider: [String: Value]] {
        entries.reduce(into: [:]) { result, providerEntries in
            let (provider, values) = providerEntries
            var mapped = values
            for (alias, canonical) in (aliases[provider] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let legacy = values[alias] else { continue }
                mapped.removeValue(forKey: alias)
                if values[canonical] != nil { continue }
                if let previous = mapped[canonical], !prefer(legacy, previous) { continue }
                mapped[canonical] = legacy
            }
            result[provider] = mapped
        }
    }

    /// 固定项跟随同一凭据的键迁移，保持用户顺序；已经固定新旧两种键时只保留一项。
    /// 这不是重新自动挑选账号，也不能修改用户的“已手动选择”偏好。
    @MainActor static func rekeyMenuBarItems(_ items: [MenuBarQuotaItem],
                                 aliases: [AIProvider: [String: String]]) -> [MenuBarQuotaItem] {
        var seen = Set<String>()
        return items.compactMap { item in
            let canonical = item.aiProvider.flatMap { aliases[$0]?[item.accountKey] } ?? item.accountKey
            // 旧 copilot 提供商别名与现有枚举规范化，避免同键被当成两个固定项。
            let mapped = MenuBarQuotaItem(provider: item.aiProvider?.rawValue ?? item.provider, accountKey: canonical)
            return seen.insert(mapped.id).inserted ? mapped : nil
        }
    }
}
