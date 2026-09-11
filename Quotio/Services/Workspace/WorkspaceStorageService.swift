import Foundation

public actor WorkspaceStorageService {
    public static let shared = WorkspaceStorageService()

    private let fileManager = FileManager.default
    private let homeDir: String
    private let sessionService: any WorkspaceSessionServicing
    private var previewPlans: [Int: WorkspaceCleanupPlan] = [:]
    private var isCleaning = false

    /// 构造阶段只保存依赖，不创建目录、不扫描或迁移真实用户数据。
    /// 未注入服务时仍使用相同 home，避免临时目录测试意外连接全局 shared。
    public init(homeDir: String = FileManager.default.homeDirectoryForCurrentUser.path,
                sessionService: (any WorkspaceSessionServicing)? = nil) {
        self.homeDir = URL(fileURLWithPath: homeDir, isDirectory: true).standardizedFileURL.path
        self.sessionService = sessionService ?? WorkspaceSessionService(homeDir: homeDir)
    }

    // MARK: - 容量分析与候选快照

    public func analyzeStorage() async -> WorkspaceStorageReport {
        let sessions = await sessionService.scanAllSessions(agentFilter: nil)
        let plan = buildCleanupPlan(sessions: sessions, olderThanDays: 30)
        previewPlans[30] = plan
        let items = WorkspaceAgent.allCases.map { agent in
            AgentStorageUsage(
                agent: agent,
                sessionBytes: measuredBytes(relativePaths: sessionStoragePaths(for: agent)),
                sessionCount: Set(sessions.filter { $0.agent == agent }.map(WorkspaceCleanupSessionKey.init)).count,
                cacheBytes: measuredBytes(relativePaths: cachePaths(for: agent)),
                logBytes: measuredBytes(relativePaths: logPaths(for: agent))
            )
        }
        return WorkspaceStorageReport(
            items: items,
            quotioAppBytes: measuredBytes(relativePaths: ["Library/Caches/com.quotio.Quotio", "Library/Logs/Quotio"]),
            oldSessionsBytes: plan.estimatedBytes,
            oldSessionsCount: plan.sessionCount
        )
    }

    public func makeCleanupPlan(olderThanDays: Int = 30) async -> WorkspaceCleanupPlan {
        let sessions = await sessionService.scanAllSessions(agentFilter: nil)
        let plan = buildCleanupPlan(sessions: sessions, olderThanDays: olderThanDays)
        previewPlans[olderThanDays] = plan
        return plan
    }

    private func buildCleanupPlan(sessions: [WorkspaceSession], olderThanDays: Int) -> WorkspaceCleanupPlan {
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: -max(1, olderThanDays), to: now) ?? now
        let groups = WorkspaceCleanupGraph.groups(in: sessions).filter { group in
            group.allSatisfy { $0.lastActiveAt < cutoff } && !WorkspaceCleanupGraph.roots(in: group).isEmpty
        }
        // 与会话删除引擎共用附件规划，AGY 的 brain、JSON 与 Claude sidecar 都计入同一预估。
        let paths = groups.flatMap { group in
            (try? WorkspaceSessionArtifactPaths.paths(for: group, homeDirectory: homeDir)) ?? []
        }
        return WorkspaceCleanupPlan(homeDirectory: homeDir, olderThanDays: olderThanDays,
                                    cutoff: cutoff, createdAt: now, groups: groups,
                                    estimatedBytes: measuredBytes(absolutePaths: paths))
    }

    // MARK: - 基于逻辑会话的统一清理

    public func cleanOldSessionsReport(olderThanDays: Int = 30) async -> WorkspaceOperationResult {
        let plan: WorkspaceCleanupPlan
        if let preview = previewPlans[olderThanDays] {
            plan = preview
        } else {
            plan = await makeCleanupPlan(olderThanDays: olderThanDays)
        }
        return await executeCleanupPlan(plan)
    }

    public func executeCleanupPlan(_ plan: WorkspaceCleanupPlan) async -> WorkspaceOperationResult {
        guard !isCleaning else { return WorkspaceOperationResult(failures: ["已有清理任务正在执行，请等待完成。"]) }
        guard plan.homeDirectory == homeDir else {
            return WorkspaceOperationResult(failures: ["清理预览不属于当前用户目录，已拒绝执行。"])
        }
        isCleaning = true
        defer {
            isCleaning = false
            previewPlans.removeValue(forKey: plan.olderThanDays)
        }
        var result = WorkspaceOperationResult()

        for expectedGroup in plan.groups {
            // 每棵父树执行前重查；等待期间新增或活跃的子会话，必须让整棵树退出本次清理，
            // 不能交给底层级联删除顺带处理，更不能把新扫描出的过期会话加进既有预览。
            let current = await sessionService.scanAllSessions(agentFilter: nil)
            let expectedKeys = Set(expectedGroup.map(WorkspaceCleanupSessionKey.init))
            let currentGroups = WorkspaceCleanupGraph.groups(in: current)
            guard let group = currentGroups.first(where: { candidate in
                candidate.contains { expectedKeys.contains(WorkspaceCleanupSessionKey($0)) }
            }), Set(group.map(WorkspaceCleanupSessionKey.init)) == expectedKeys else {
                result.failures.append("\(groupLabel(expectedGroup))：会话树已变化，已保留。")
                continue
            }
            let expected = Dictionary(uniqueKeysWithValues: expectedGroup.map { (WorkspaceCleanupSessionKey($0), $0) })
            guard group.allSatisfy({ session in
                guard let original = expected[WorkspaceCleanupSessionKey(session)] else { return false }
                return session.lastActiveAt < plan.cutoff && session.lastActiveAt <= original.lastActiveAt
                    && session.filePath == original.filePath && session.parentSessionID == original.parentSessionID
            }) else {
                result.failures.append("\(groupLabel(group))：预览后有会话活动或来源变化，已保留整棵会话树。")
                continue
            }

            let paths: [String]
            let before: Int64
            let constrainedRoots: [(WorkspaceSession, WorkspaceSessionCleanupConstraint)]
            do {
                paths = try WorkspaceSessionArtifactPaths.paths(for: group, homeDirectory: homeDir)
                // 执行严格校验路径及读取权限，不能把不可读视为零字节后继续删除。
                before = try validatedBytes(absolutePaths: paths)
                let tree = WorkspaceSessionTree(sessions: group)
                constrainedRoots = try WorkspaceCleanupGraph.roots(in: group).map { root in
                    let subtree = [root] + tree.descendants(of: root).map(\.session)
                    return (root, try WorkspaceSessionCleanupConstraint(sessions: subtree, cutoff: plan.cutoff, homeDirectory: homeDir))
                }
            } catch {
                result.failures.append("\(groupLabel(group))：\(error.localizedDescription)")
                continue
            }
            var deleteFailed = false
            var confirmedKeys = Set<WorkspaceCleanupSessionKey>()
            for (root, constraint) in constrainedRoots {
                do {
                    guard try await sessionService.deleteSession(root, constrainedBy: constraint) else {
                        result.failures.append("\(root.agent.displayName) / \(root.id)：服务未确认删除成功。")
                        deleteFailed = true
                        break
                    }
                    confirmedKeys.formUnion(constraint.sessions.map(WorkspaceCleanupSessionKey.init))
                } catch {
                    result.failures.append("\(root.agent.displayName) / \(root.id)：\(error.localizedDescription)")
                    deleteFailed = true
                    break
                }
            }

            // SQLite 删除行不保证数据库文件立即缩小，所以不虚报整份数据库容量。
            // 部分失败时也只计算候选附件实际减少的字节与确实消失的逻辑会话。
            let remaining = await sessionService.scanAllSessions(agentFilter: nil)
            let remainingKeys = Set(remaining.map(WorkspaceCleanupSessionKey.init))
            let removedCount = confirmedKeys.intersection(expectedKeys.subtracting(remainingKeys)).count
            do {
                let after = try validatedBytes(absolutePaths: paths)
                result.freedBytes += max(0, before - after)
            } catch {
                // 无法读取不代表附件已经消失，核验失败时不能把全部预估容量当作释放量。
                result.failures.append("\(groupLabel(group))：无法核验释放容量：\(error.localizedDescription)")
            }
            result.succeededCount += removedCount
            if !deleteFailed && removedCount != expectedKeys.count {
                result.failures.append("\(groupLabel(group))：删除后仍有会话记录，未将其计入成功。")
            }
        }
        return result
    }

    // MARK: - 缓存清理

    public func clearCachesReport(for agent: WorkspaceAgent? = nil) async -> WorkspaceOperationResult {
        guard !isCleaning else { return WorkspaceOperationResult(failures: ["已有清理任务正在执行，请等待完成。"]) }
        isCleaning = true
        defer { isCleaning = false }
        var result = WorkspaceOperationResult()
        let agents = agent.map { [$0] } ?? WorkspaceAgent.allCases
        for target in agents {
            for relative in cachePaths(for: target) {
                let path = absolutePath(relative)
                do {
                    let files = try validatedFiles(at: path, rejectingLocks: true)
                    guard !files.isEmpty else { continue }
                    var failed = false
                    for file in files {
                        do {
                            try validateContainedPath(file.path)
                            let attrs = try fileManager.attributesOfItem(atPath: file.path)
                            guard attrs[.type] as? FileAttributeType == .typeRegular else {
                                throw storageError("缓存文件类型已经变化，已保留：\(relative)")
                            }
                            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                            try fileManager.removeItem(at: file)
                            result.freedBytes += size
                        } catch {
                            failed = true
                            result.failures.append("\(relative)：\(error.localizedDescription)")
                        }
                    }
                    // 保留原缓存目录及空子目录，避免删除扫描后刚出现的锁和新文件。
                    if !failed { result.succeededCount += 1 }
                } catch {
                    result.failures.append("\(relative)：\(error.localizedDescription)")
                }
            }
        }
        return result
    }

    /// 保留原调用接口，但把部分失败反馈给旧调用者，不能再无条件返回成功容量。
    public func clearCaches(for agent: WorkspaceAgent? = nil) async throws -> Int64 {
        let result = await clearCachesReport(for: agent)
        try result.throwIfFailed()
        return result.freedBytes
    }

    public func cleanOldSessions(olderThanDays: Int = 30) async throws -> (count: Int, freedBytes: Int64) {
        let result = await cleanOldSessionsReport(olderThanDays: olderThanDays)
        try result.throwIfFailed()
        return (result.succeededCount, result.freedBytes)
    }

    // MARK: - 路径定义：统计与删除使用同一份缓存白名单

    private func cachePaths(for agent: WorkspaceAgent) -> [String] {
        switch agent {
        case .claude: return [".claude/cache", ".claude/debug"]
        // tmp 和 presence 含运行锁、可执行中间文件及在线状态，不属于可随时删除的缓存。
        case .codex: return [".codex/cache"]
        case .opencode: return [".local/share/opencode/cache"]
        case .pi: return [".pi/cache", ".pi/agent/cache"]
        case .agy: return [".gemini/antigravity-cli/cache", ".gemini/cache"]
        }
    }

    private func logPaths(for agent: WorkspaceAgent) -> [String] {
        switch agent {
        case .claude: return [".claude/logs"]
        case .codex: return [".codex/logs"]
        case .opencode: return [".local/share/opencode/logs"]
        case .pi: return [".pi/logs"]
        case .agy: return [".gemini/antigravity-cli/log", ".gemini/antigravity-cli/crashes", ".gemini/logs"]
        }
    }

    private func sessionStoragePaths(for agent: WorkspaceAgent) -> [String] {
        switch agent {
        case .claude: return [".claude/projects"]
        case .codex: return [".codex/sessions", ".codex/archived_sessions", ".codex/state_5.sqlite", ".codex/state_5.sqlite-wal"]
        case .opencode: return [".local/share/opencode/opencode.db", ".local/share/opencode/opencode.db-wal", ".local/share/opencode/storage"]
        case .pi: return [".pi/agent/sessions", ".pi/sessions"]
        case .agy: return [".gemini/antigravity-cli/brain", ".gemini/antigravity-cli/conversations",
                           ".gemini/antigravity-cli/conversation_summaries.db", ".gemini/antigravity-cli/conversation_summaries.db-wal",
                           ".gemini/antigravity-cli/history.jsonl", ".gemini/tmp"]
        }
    }

    private func absolutePath(_ relative: String) -> String {
        URL(fileURLWithPath: homeDir, isDirectory: true).appendingPathComponent(relative).path
    }

    private func groupLabel(_ group: [WorkspaceSession]) -> String {
        guard let first = WorkspaceCleanupGraph.roots(in: group).first ?? group.first else { return "会话" }
        return "\(first.agent.displayName) / \(first.id)"
    }

    // MARK: - 不跟随符号链接的文件测量与边界校验

    private func measuredBytes(relativePaths: [String]) -> Int64 {
        measuredBytes(absolutePaths: relativePaths.map(absolutePath))
    }

    private func measuredBytes(absolutePaths: [String]) -> Int64 {
        // 统计允许对单个不可读路径降级；执行流程则调用 throwing 版本阻止越界或漏检。
        var seen: Set<String> = []
        return absolutePaths.reduce(0) { total, path in
            let files = (try? validatedFiles(at: path)) ?? []
            return total + files.reduce(0) { sum, file in
                // 同一附件可能同时作为正文路径和 brain/sidecar 子项出现。
                // 以规范化物理路径去重，消除系统路径别名与 URL 序列化差异。
                guard seen.insert(file.resolvingSymlinksInPath().standardizedFileURL.path).inserted,
                      let attrs = try? fileManager.attributesOfItem(atPath: file.path) else { return sum }
                return sum + ((attrs[.size] as? NSNumber)?.int64Value ?? 0)
            }
        }
    }

    private func validatedBytes(absolutePaths: [String]) throws -> Int64 {
        var seen: Set<String> = []
        var total: Int64 = 0
        for path in absolutePaths {
            for file in try validatedFiles(at: path) where seen.insert(file.resolvingSymlinksInPath().standardizedFileURL.path).inserted {
                let attrs = try fileManager.attributesOfItem(atPath: file.path)
                total += (attrs[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return total
    }

    /// 校验每一级路径而非字符串前缀，拒绝 home 本身、越界路径与中间符号链接。
    /// home 自身可处于系统 /var -> /private/var 别名下，用户目录以内不接受重定向。
    private func validateContainedPath(_ path: String) throws {
        let base = URL(fileURLWithPath: homeDir, isDirectory: true).standardizedFileURL
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let baseParts = base.pathComponents
        let targetParts = target.pathComponents
        guard targetParts.count > baseParts.count, Array(targetParts.prefix(baseParts.count)) == baseParts else {
            throw storageError("路径超出允许的用户目录，已拒绝清理。")
        }
        var current = base
        for component in targetParts.dropFirst(baseParts.count) {
            current.appendPathComponent(component)
            do {
                let attrs = try fileManager.attributesOfItem(atPath: current.path)
                if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw storageError("路径含符号链接，已保留原路径与链接目标。")
                }
            } catch let error as NSError {
                if isMissingFile(error) { continue }
                throw error
            }
        }
    }

    private func validatedFiles(at path: String, rejectingLocks: Bool = false) throws -> [URL] {
        try validateContainedPath(path)
        var pending = [URL(fileURLWithPath: path)]
        var files: [URL] = []
        while let url = pending.popLast() {
            let attrs: [FileAttributeKey: Any]
            do {
                attrs = try fileManager.attributesOfItem(atPath: url.path)
            } catch let error as NSError {
                if isMissingFile(error) { continue }
                throw error
            }
            let type = attrs[.type] as? FileAttributeType
            guard type != .typeSymbolicLink else { throw storageError("缓存或会话附件含符号链接，已保留。") }
            if rejectingLocks {
                let name = url.lastPathComponent.lowercased()
                guard name != "lock" && !name.hasSuffix(".lock") && !name.hasSuffix(".pid")
                        && type != .typeSocket else {
                    throw storageError("缓存包含运行锁或进程文件，已跳过该目录。")
                }
            }
            if type == .typeRegular {
                files.append(url)
            } else if type == .typeDirectory {
                pending.append(contentsOf: try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))
            } else {
                throw storageError("目录包含无法安全清理的特殊文件，已保留。")
            }
        }
        return files
    }

    private func storageError(_ message: String) -> NSError {
        NSError(domain: "WorkspaceStorageService", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func isMissingFile(_ error: NSError) -> Bool {
        error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    }
}
