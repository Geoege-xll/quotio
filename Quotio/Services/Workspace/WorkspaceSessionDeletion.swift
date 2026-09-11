import Foundation

/// 浏览、存储预估和删除共用同一附件范围。这里仅列出路径，不读写用户文件；最终操作仍需重新校验。
public nonisolated enum WorkspaceSessionArtifactPaths {
    public static func paths(for sessions: [WorkspaceSession], homeDirectory: String) throws -> [String] {
        try sessions.flatMap { session in
            let targets = try targets(for: session, homeDirectory: homeDirectory)
            let policy = WorkspaceSessionPathPolicy(homeDirectory: homeDirectory, agent: session.agent)
            for target in targets { try policy.validate(target.path, allowDirectory: target.isDirectory) }
            return targets.map(\.path)
        }
    }

    static func targets(for session: WorkspaceSession, homeDirectory: String) throws -> [WorkspaceSessionDeletionTarget] {
        try targets(agent: session.agent, identifier: session.id, path: session.filePath, homeDirectory: homeDirectory)
    }

    static func targets(agent: WorkspaceAgent, identifier: String, path: String = "", homeDirectory: String) throws -> [WorkspaceSessionDeletionTarget] {
        try WorkspaceSessionPathPolicy.validateIdentifier(identifier)
        var targets: [WorkspaceSessionDeletionTarget] = []
        if !path.isEmpty && !path.hasPrefix("sqlite:") { targets.append(WorkspaceSessionDeletionTarget(path)) }
        switch agent {
        case .claude:
            guard !path.isEmpty, !path.hasPrefix("sqlite:"), path.hasSuffix(".jsonl") else {
                throw WorkspaceSessionOperationError.unsafePath(path)
            }
            let stem = URL(fileURLWithPath: path).deletingPathExtension().path
            // Claude 主会话同名目录存放 subagents；子任务还可能有配对的 meta.json。
            targets.append(WorkspaceSessionDeletionTarget(stem, directory: true))
            targets.append(WorkspaceSessionDeletionTarget(stem + ".meta.json"))
        case .agy:
            let base = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".gemini/antigravity-cli")
            targets.append(WorkspaceSessionDeletionTarget(base.appendingPathComponent("brain/\(identifier)").path, directory: true))
            targets.append(WorkspaceSessionDeletionTarget(base.appendingPathComponent("conversations/\(identifier).json").path))
        case .opencode:
            targets.append(WorkspaceSessionDeletionTarget(URL(fileURLWithPath: homeDirectory).appendingPathComponent(".local/share/opencode/storage/session/\(identifier).json").path))
        case .codex, .pi: break
        }
        return targets
    }
}

/// Provider 的公开删除入口也调用本引擎，不能依赖 Facade 曾经做过安全检查。
nonisolated enum WorkspaceSessionDeletionEngine {
    static func delete(_ session: WorkspaceSession, expectedAgent: WorkspaceAgent, homeDirectory: String, relatedSessions: [WorkspaceSession] = [], cleanupConstraint: WorkspaceSessionCleanupConstraint? = nil) throws -> Bool {
        guard session.agent == expectedAgent else { throw WorkspaceSessionOperationError.invalidIdentifier }
        try WorkspaceSessionPathPolicy.validateIdentifier(session.id)
        let policy = WorkspaceSessionPathPolicy(homeDirectory: homeDirectory, agent: expectedAgent)
        let home = URL(fileURLWithPath: homeDirectory)
        switch expectedAgent {
        case .claude, .pi:
            guard !session.filePath.isEmpty, !session.filePath.hasPrefix("sqlite:") else {
                throw WorkspaceSessionOperationError.unsafePath(session.filePath)
            }
            return try WorkspaceSessionDeletionTransaction.run(database: nil, policy: policy, cleanupConstraint: cleanupConstraint) {
                if expectedAgent == .pi {
                    let edges = relatedSessions.compactMap { candidate -> (parent: String, child: String)? in
                        guard let parent = candidate.parentSessionID else { return nil }; return (parent, candidate.id)
                    }
                    let identifiers = Set(WorkspaceSessionDeletionTransaction.descendants(root: session.id, edges: edges))
                    let related = relatedSessions.filter { identifiers.contains($0.id) && $0.id != session.id }
                    return try ([session] + related).flatMap { try WorkspaceSessionArtifactPaths.targets(for: $0, homeDirectory: homeDirectory) }
                }
                return try WorkspaceSessionArtifactPaths.targets(for: session, homeDirectory: homeDirectory)
            } mutateDatabase: { false }
        case .codex:
            // 与发现阶段使用相同的活动数据库；绝不枚举并修改 state_* 备份或历史副本。
            let path = home.appendingPathComponent(".codex/state_5.sqlite").path
            try validateSelectedPath(session, databasePath: path, policy: policy)
            let database = try openExistingDatabase(path, homeDirectory: homeDirectory)
            var identifiers: [String] = []
            return try WorkspaceSessionDeletionTransaction.run(database: database, policy: policy, cleanupConstraint: cleanupConstraint) {
                guard let database else {
                    let edges = relatedSessions.compactMap { candidate -> (parent: String, child: String)? in
                        guard let parent = candidate.parentSessionID else { return nil }; return (parent, candidate.id)
                    }
                    let wanted = Set(WorkspaceSessionDeletionTransaction.descendants(root: session.id, edges: edges))
                    return try ([session] + relatedSessions.filter { wanted.contains($0.id) && $0.id != session.id }).flatMap {
                        try WorkspaceSessionArtifactPaths.targets(for: $0, homeDirectory: homeDirectory)
                    }
                }
                var edges: [(parent: String, child: String)] = []
                if try database.hasTable("thread_spawn_edges") {
                    edges = try database.rows("SELECT parent_thread_id, child_thread_id FROM thread_spawn_edges").compactMap { row in
                        guard let parent = row[0], let child = row[1] else { return nil }; return (parent, child)
                    }
                }
                let sourceColumn = try database.hasColumn("source", table: "threads") ? "source" : "NULL"
                let activityColumn = try database.hasColumn("updated_at", table: "threads") ? "updated_at" : "NULL"
                let rows = try database.rows("SELECT id, rollout_path, \(sourceColumn), \(activityColumn) FROM threads")
                // 某些客户端版本只在 source JSON 中记录父任务；同样纳入后代计划，避免遗留正文。
                for row in rows {
                    if let child = row[0], let source = row[2], let parent = parentThreadID(in: source) { edges.append((parent, child)) }
                }
                if cleanupConstraint != nil {
                    edges += relatedSessions.compactMap { record in record.parentSessionID.map { (parent: $0, child: record.id) } }
                }
                identifiers = WorkspaceSessionDeletionTransaction.descendants(root: session.id, edges: edges)
                let wanted = Set(identifiers)
                if let cleanupConstraint {
                    var checked = rows.compactMap { row -> (id: String, path: String?, date: Date?, parent: String?)? in
                        guard let id = row[0] else { return nil }
                        return (id, row[1], activityDate(row[3], milliseconds: false), edges.first { $0.child == id }?.parent)
                    }
                    let databaseIDs = Set(checked.map(\.id))
                    checked += relatedSessions.filter { !databaseIDs.contains($0.id) }.map { ($0.id, $0.filePath, $0.lastActiveAt, $0.parentSessionID) }
                    try cleanupConstraint.validateDatabase(ids: identifiers, rows: checked)
                }
                var targets: [WorkspaceSessionDeletionTarget] = []
                if !session.filePath.isEmpty && !session.filePath.hasPrefix("sqlite:") { targets.append(WorkspaceSessionDeletionTarget(session.filePath)) }
                for row in rows where row[0].map(wanted.contains) == true {
                    if let path = row[1], !path.isEmpty { targets.append(WorkspaceSessionDeletionTarget(path)) }
                }
                if cleanupConstraint != nil {
                    targets += relatedSessions.filter { wanted.contains($0.id) && !$0.filePath.isEmpty && !$0.filePath.hasPrefix("sqlite:") }.map { WorkspaceSessionDeletionTarget($0.filePath) }
                }
                return targets
            } mutateDatabase: {
                guard let database else { return false }
                var changed = false
                for identifier in identifiers.reversed() {
                    try database.deleteIfPresent(table: "thread_artifacts", column: "thread_id", identifiers: [identifier])
                    try database.deleteIfPresent(table: "thread_dynamic_tools", column: "thread_id", identifiers: [identifier])
                    if try database.hasTable("thread_spawn_edges") {
                        try database.execute("DELETE FROM thread_spawn_edges WHERE parent_thread_id = ? OR child_thread_id = ?", parameters: [identifier, identifier])
                    }
                    if try database.execute("DELETE FROM threads WHERE id = ?", parameters: [identifier]) > 0 { changed = true }
                }
                return changed
            }
        case .opencode, .agy:
            let isOpenCode = expectedAgent == .opencode
            let path = home.appendingPathComponent(isOpenCode ? ".local/share/opencode/opencode.db" : ".gemini/antigravity-cli/conversation_summaries.db").path
            try validateSelectedPath(session, databasePath: path, policy: policy)
            let database = try openExistingDatabase(path, homeDirectory: homeDirectory)
            let table = isOpenCode ? "session" : "conversation_summaries"
            let key = isOpenCode ? "id" : "conversation_id"
            let parentKey = isOpenCode ? "parent_id" : "parent_conversation_id"
            var identifiers = [session.id]
            return try WorkspaceSessionDeletionTransaction.run(database: database, policy: policy, cleanupConstraint: cleanupConstraint) {
                if let database {
                    // 父字段缺失是已知旧版本契约；其它 SQL 错误继续上抛，不能误当空数据库。
                    let parentColumn = try database.hasColumn(parentKey, table: table) ? parentKey : "NULL"
                    let activityName = isOpenCode ? "time_updated" : "last_modified_time"
                    let activityColumn = try database.hasColumn(activityName, table: table) ? activityName : "NULL"
                    let rows = try database.rows("SELECT \(key), \(parentColumn), \(activityColumn) FROM \(table)")
                    let edges: [(parent: String, child: String)] = rows.compactMap { row in
                        guard let child = row[0], let parent = row[1], !parent.isEmpty else { return nil }; return (parent, child)
                    }
                    identifiers = WorkspaceSessionDeletionTransaction.descendants(root: session.id, edges: edges)
                    if let cleanupConstraint {
                        let checked = rows.compactMap { row -> (id: String, path: String?, date: Date?, parent: String?)? in
                            guard let id = row[0] else { return nil }
                            let date = isOpenCode ? activityDate(row[2], milliseconds: true) : row[2].flatMap { SessionIOUtils.parseDate($0) }
                            return (id, nil, date, row[1].flatMap { $0.isEmpty ? nil : $0 })
                        }
                        try cleanupConstraint.validateDatabase(ids: identifiers, rows: checked)
                    }
                } else {
                    let edges = relatedSessions.compactMap { candidate -> (parent: String, child: String)? in
                        guard let parent = candidate.parentSessionID else { return nil }; return (parent, candidate.id)
                    }
                    identifiers = WorkspaceSessionDeletionTransaction.descendants(root: session.id, edges: edges)
                }
                var targets = try WorkspaceSessionArtifactPaths.targets(for: session, homeDirectory: homeDirectory)
                for identifier in identifiers where identifier != session.id {
                    let discoveredPath = relatedSessions.first { $0.id == identifier }?.filePath ?? ""
                    targets += try WorkspaceSessionArtifactPaths.targets(agent: expectedAgent, identifier: identifier, path: discoveredPath, homeDirectory: homeDirectory)
                }
                return targets
            } mutateDatabase: {
                guard let database else { return false }
                var changed = false
                for identifier in identifiers.reversed() {
                    if isOpenCode {
                        // 部分旧库没有外键级联；显式清理已知消息表，兼容其表根本不存在的情况。
                        try database.deleteIfPresent(table: "part", column: "session_id", identifiers: [identifier])
                        try database.deleteIfPresent(table: "message", column: "session_id", identifiers: [identifier])
                    }
                    if try database.execute("DELETE FROM \(table) WHERE \(key) = ?", parameters: [identifier]) > 0 { changed = true }
                }
                return changed
            }
        }
    }

    private static func activityDate(_ value: String?, milliseconds: Bool) -> Date? {
        guard let value, let seconds = Int64(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds && seconds > 1_000_000_000_000 ? seconds / 1000 : seconds))
    }

    private static func openExistingDatabase(_ path: String, homeDirectory: String) throws -> WorkspaceSessionDatabase? {
        try WorkspaceSessionPathPolicy.validateHomeAncestors(path, homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try WorkspaceSessionDatabase(path: path, homeDirectory: homeDirectory)
    }

    private static func validateSelectedPath(_ session: WorkspaceSession, databasePath: String, policy: WorkspaceSessionPathPolicy) throws {
        if session.filePath.hasPrefix("sqlite:") {
            try WorkspaceSessionPathPolicy.validateLocator(session.filePath, expectedDatabase: databasePath, identifier: session.id)
        } else if !session.filePath.isEmpty {
            try policy.validate(session.filePath)
        }
    }

    static func parentThreadID(in source: String) -> String? {
        guard let data = source.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        func find(_ value: Any) -> String? {
            if let dictionary = value as? [String: Any] {
                if let identifier = dictionary["parent_thread_id"] as? String, !identifier.isEmpty { return identifier }
                for child in dictionary.values { if let identifier = find(child) { return identifier } }
            } else if let values = value as? [Any] {
                for child in values { if let identifier = find(child) { return identifier } }
            }
            return nil
        }
        return find(value)
    }
}
