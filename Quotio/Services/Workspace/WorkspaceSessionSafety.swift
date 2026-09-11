import Foundation
import SQLite3

/// 会话操作失败必须保留原因，调用方才能区分“没有记录”与“记录仍在但操作失败”。
nonisolated enum WorkspaceSessionOperationError: LocalizedError {
    case unsafePath(String)
    case invalidIdentifier
    case database(String)
    case terminal(String)

    var errorDescription: String? {
        switch self {
        case .unsafePath(let path): return "拒绝操作不属于会话文件范围的路径：\(path)"
        case .invalidIdentifier: return "会话标识无效，无法安全构造会话路径。"
        case .database(let reason): return "会话数据库操作失败：\(reason)"
        case .terminal(let reason): return "无法在终端恢复会话：\(reason)"
        }
    }
}

/// 终端命令只由应用认识的程序和独立参数构成，不执行会话元数据提供的整段命令。
public nonisolated enum WorkspaceSessionCommandBuilder {
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func resumeCommand(agent: WorkspaceAgent, id: String, parentID: String? = nil) -> String {
        let arguments: [String]
        switch agent {
        case .claude: arguments = ["claude", "--resume", parentID ?? id]
        case .codex: arguments = ["codex", "resume", id]
        case .opencode: arguments = ["opencode", "-s", id]
        case .pi: arguments = ["pi", "--session", id]
        case .agy: arguments = ["agy", "--conversation", id]
        }
        // 常量程序/选项与数据参数采用同一转义规则，避免新增客户端时遗漏保护。
        return arguments.map(quote).joined(separator: " ")
    }

    public static func terminalCommand(session: WorkspaceSession, homeDirectory: String) -> String {
        let directory = session.projectDirectory.flatMap { $0.isEmpty ? nil : $0 } ?? homeDirectory
        return "cd -- \(quote(directory)) && \(resumeCommand(agent: session.agent, id: session.id, parentID: session.agent == .claude ? session.parentSessionID : nil))"
    }
}

/// 不以字符串前缀判断目录归属；根本身、同名前缀目录和解析符号链接后的越界目标都禁止删除。
nonisolated struct WorkspaceSessionPathPolicy {
    let homeDirectory: String
    let agent: WorkspaceAgent

    var roots: [URL] {
        let components: [String]
        switch agent {
        case .claude: components = [".claude/projects"]
        case .codex: components = [".codex/sessions", ".codex/archived_sessions"]
        case .opencode: components = [".local/share/opencode/storage/session"]
        case .pi: components = [".pi/agent/sessions", ".pi/sessions"]
        case .agy: components = [".gemini/antigravity-cli/brain", ".gemini/antigravity-cli/conversations", ".gemini/tmp"]
        }
        return components.map { URL(fileURLWithPath: homeDirectory).appendingPathComponent($0).resolvingSymlinksInPath().standardizedFileURL }
    }

    func validate(_ path: String, allowDirectory: Bool = false) throws {
        guard !path.isEmpty, path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw WorkspaceSessionOperationError.unsafePath(path)
        }
        try Self.validateHomeAncestors(path, homeDirectory: homeDirectory)
        let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let parts = candidate.pathComponents
        guard roots.contains(where: { parts.count > $0.pathComponents.count && parts.starts(with: $0.pathComponents) }) else {
            throw WorkspaceSessionOperationError.unsafePath(path)
        }
        // 除明确授权的 Claude sidecar / AGY brain 目录，所有记录路径都必须是普通文件。
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeRegular || (allowDirectory && type == .typeDirectory) else {
                throw WorkspaceSessionOperationError.unsafePath(path)
            }
        }
        if !allowDirectory {
            let name = candidate.lastPathComponent
            let validExtension = agent == .opencode ? name.hasSuffix(".json") : name.hasSuffix(".jsonl") || (agent == .agy && name.hasSuffix(".json")) || (agent == .claude && name.hasSuffix(".meta.json"))
            guard validExtension else { throw WorkspaceSessionOperationError.unsafePath(path) }
        }
    }

    static func validateIdentifier(_ identifier: String) throws {
        guard !identifier.isEmpty, identifier != ".", identifier != "..",
              !identifier.contains("/"), !identifier.contains("\\"), !identifier.utf8.contains(0) else {
            throw WorkspaceSessionOperationError.invalidIdentifier
        }
    }

    /// home 之上的系统映射（例如 /var）可以存在；home 内客户端目录的任何符号链接都不能扩大操作范围。
    static func validateHomeAncestors(_ path: String, homeDirectory: String) throws {
        let declaredHome = URL(fileURLWithPath: homeDirectory).standardizedFileURL
        let physicalHome = declaredHome.resolvingSymlinksInPath().standardizedFileURL
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let base: URL
        if parts.starts(with: declaredHome.pathComponents) { base = declaredHome }
        else if parts.starts(with: physicalHome.pathComponents) { base = physicalHome }
        else { throw WorkspaceSessionOperationError.unsafePath(path) }
        var current = physicalHome
        for component in parts.dropFirst(base.pathComponents.count) {
            current.appendPathComponent(component)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw WorkspaceSessionOperationError.unsafePath(path)
            }
        }
    }

    /// sqlite 定位符只允许访问该 Provider 的固定数据库，不接受任意外部数据库路径。
    static func validateLocator(_ source: String, expectedDatabase: String, identifier: String) throws {
        guard let locator = parseLocator(source), locator.id == identifier,
              URL(fileURLWithPath: locator.path).standardizedFileURL == URL(fileURLWithPath: expectedDatabase).standardizedFileURL else {
            throw WorkspaceSessionOperationError.unsafePath(source)
        }
    }

    static func parseLocator(_ source: String) -> (path: String, id: String)? {
        guard source.hasPrefix("sqlite:"), let separator = source.lastIndex(of: ":"), separator > source.index(source.startIndex, offsetBy: 6) else { return nil }
        return (String(source[source.index(source.startIndex, offsetBy: 7)..<separator]), String(source[source.index(after: separator)...]))
    }
}

/// SQLite 错误不能与“影响零行”混为一谈。绑定使用 SQLITE_TRANSIENT，避免临时 NSString 生命周期造成悬空指针。
nonisolated final class WorkspaceSessionDatabase {
    private(set) var handle: OpaquePointer?

    init(path: String, homeDirectory: String? = nil) throws {
        if let homeDirectory { try WorkspaceSessionPathPolicy.validateHomeAncestors(path, homeDirectory: homeDirectory) }
        // 允许 /var → /private/var 这样的系统祖先目录映射，但固定数据库文件本身不能是符号链接。
        guard (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeRegular else {
            throw WorkspaceSessionOperationError.unsafePath(path)
        }
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            sqlite3_close(handle)
            handle = nil
            throw WorkspaceSessionOperationError.database(reason)
        }
        sqlite3_busy_timeout(handle, 1_000)
        do { try execute("PRAGMA foreign_keys = ON") }
        catch {
            // 初始化失败时也显式关闭 C 句柄，不能依赖尚未完成初始化的对象析构。
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    private func prepare(_ sql: String, parameters: [String]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw WorkspaceSessionOperationError.database(String(cString: sqlite3_errmsg(handle)))
        }
        for (index, parameter) in parameters.enumerated() {
            let result = parameter.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard result == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw WorkspaceSessionOperationError.database(String(cString: sqlite3_errmsg(handle)))
            }
        }
        return statement
    }

    @discardableResult
    func execute(_ sql: String, parameters: [String] = []) throws -> Int {
        let statement = try prepare(sql, parameters: parameters)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw WorkspaceSessionOperationError.database(String(cString: sqlite3_errmsg(handle)))
        }
        return Int(sqlite3_changes(handle))
    }

    func rows(_ sql: String, parameters: [String] = []) throws -> [[String?]] {
        let statement = try prepare(sql, parameters: parameters)
        defer { sqlite3_finalize(statement) }
        var result: [[String?]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                result.append((0..<sqlite3_column_count(statement)).map { index in sqlite3_column_text(statement, index).map { String(cString: $0) } })
            case SQLITE_DONE: return result
            default: throw WorkspaceSessionOperationError.database(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    func hasTable(_ name: String) throws -> Bool {
        try !rows("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", parameters: [name]).isEmpty
    }

    func hasColumn(_ name: String, table: String) throws -> Bool {
        // table 仅来自下方 Provider 的常量；列名通过结果比较，不能由外部数据拼接 SQL。
        try rows("PRAGMA table_info(\(table))").contains { $0.count > 1 && $0[1] == name }
    }

    func deleteIfPresent(table: String, column: String, identifiers: [String]) throws {
        guard try hasTable(table) else { return }
        for identifier in identifiers { try execute("DELETE FROM \(table) WHERE \(column) = ?", parameters: [identifier]) }
    }
}

nonisolated struct WorkspaceSessionDeletionTarget: Sendable {
    let path: String
    let isDirectory: Bool
    init(_ path: String, directory: Bool = false) { self.path = path; self.isDirectory = directory }
}

/// 删除期间先持有数据库写事务，再预检完整文件计划；文件以同目录重命名暂存，SQL 失败时原路恢复。
/// 暂存保留在原卷，避免跨卷复制失败；提交后才真正移除暂存内容，不会因写锁先丢掉正文。
nonisolated enum WorkspaceSessionDeletionTransaction {
    static func run(
        database: WorkspaceSessionDatabase?,
        policy: WorkspaceSessionPathPolicy,
        cleanupConstraint: WorkspaceSessionCleanupConstraint? = nil,
        plan: () throws -> [WorkspaceSessionDeletionTarget],
        mutateDatabase: () throws -> Bool
    ) throws -> Bool {
        if let database { try database.execute("BEGIN IMMEDIATE") }
        var staged: [(original: String, temporary: String)] = []
        var committed = false
        do {
            var proposed = try plan()
            if let cleanupConstraint {
                try cleanupConstraint.validateFiles()
                proposed = cleanupConstraint.frozenFileTargets()
            }
            // 在触碰任何文件前检查全部路径，防止安全检查在删除到一半时才发现越界子任务。
            for target in proposed { try policy.validate(target.path, allowDirectory: target.isDirectory || cleanupConstraint != nil) }
            var targets: [WorkspaceSessionDeletionTarget] = []
            for target in proposed.sorted(by: { $0.path.count < $1.path.count }) {
                let canonical = URL(fileURLWithPath: target.path).standardizedFileURL.pathComponents
                if targets.contains(where: { prior in
                    let previous = URL(fileURLWithPath: prior.path).standardizedFileURL.pathComponents
                    return canonical == previous || (prior.isDirectory && canonical.starts(with: previous))
                }) { continue }
                targets.append(target)
            }
            for target in targets where FileManager.default.fileExists(atPath: target.path) {
                // 重命名前再次检查，拒绝扫描后被替换成目录/符号链接的会话文件。
                try policy.validate(target.path, allowDirectory: target.isDirectory || cleanupConstraint != nil)
                try cleanupConstraint?.validateFile(target.path)
                let temporary = URL(fileURLWithPath: target.path).deletingLastPathComponent().appendingPathComponent(".quotio-session-delete-\(UUID().uuidString)").path
                try FileManager.default.moveItem(atPath: target.path, toPath: temporary)
                staged.append((target.path, temporary))
            }
            // 已打开的文件句柄仍可能在重命名后追加内容；SQL 提交前再核验隔离文件，
            // 如果正文变化则回滚事务并原路恢复，不把新写入当作旧附件销毁。
            for item in staged { try cleanupConstraint?.validateFile(item.temporary, originalPath: item.original) }
            let databaseChanged = try mutateDatabase()
            if let database { try database.execute("COMMIT") }
            committed = true
            // 已提交的内容若因权限等原因无法清除，抛出明确错误，暂存数据仍可人工恢复。
            for item in staged { try FileManager.default.removeItem(atPath: item.temporary) }
            return databaseChanged || !staged.isEmpty
        } catch {
            if !committed {
                if let database { _ = try? database.execute("ROLLBACK") }
                var restorationErrors: [String] = []
                for item in staged.reversed() {
                    do { try FileManager.default.moveItem(atPath: item.temporary, toPath: item.original) }
                    catch { restorationErrors.append("\(item.temporary) → \(item.original)：\(error.localizedDescription)") }
                }
                if !restorationErrors.isEmpty {
                    throw WorkspaceSessionOperationError.database("删除失败，部分暂存文件需要恢复：" + restorationErrors.joined(separator: "；"))
                }
            }
            throw error
        }
    }

    /// visited 同时防止损坏元数据形成循环，并确保任意深度的子孙节点只处理一次。
    static func descendants(root: String, edges: [(parent: String, child: String)]) -> [String] {
        let children = Dictionary(grouping: edges, by: \.parent)
        var visited = Set<String>()
        var ordered: [String] = []
        var pending = [root]
        while let identifier = pending.popLast() {
            guard visited.insert(identifier).inserted else { continue }
            ordered.append(identifier)
            pending.append(contentsOf: (children[identifier] ?? []).map(\.child))
        }
        return ordered
    }
}
