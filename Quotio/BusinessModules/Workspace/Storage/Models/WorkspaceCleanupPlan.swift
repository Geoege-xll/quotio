import Foundation

/// 清理身份必须同时包含客户端与会话 ID；不同客户端使用相同 ID 时不能互相级联。
public nonisolated struct WorkspaceCleanupSessionKey: Hashable, Sendable {
    public let agent: WorkspaceAgent
    public let id: String

    init(_ session: WorkspaceSession) {
        agent = session.agent
        id = session.id
    }

    init(agent: WorkspaceAgent, id: String) {
        self.agent = agent
        self.id = id
    }
}

/// 容量预览与执行共用同一份不可变候选快照。执行只能缩小或跳过这份快照，
/// 不能因为时间过去或扫描出了新会话而顺便扩大用户看到的清理范围。
public nonisolated struct WorkspaceCleanupPlan: Sendable {
    public let olderThanDays: Int
    public let cutoff: Date
    public let createdAt: Date
    public let estimatedBytes: Int64
    public let candidates: [WorkspaceSession]
    public var sessionCount: Int { candidates.count }

    let homeDirectory: String
    let groups: [[WorkspaceSession]]

    init(homeDirectory: String, olderThanDays: Int, cutoff: Date, createdAt: Date,
         groups: [[WorkspaceSession]], estimatedBytes: Int64) {
        self.homeDirectory = homeDirectory
        self.olderThanDays = olderThanDays
        self.cutoff = cutoff
        self.createdAt = createdAt
        self.groups = groups
        self.candidates = groups.flatMap { $0 }
        self.estimatedBytes = estimatedBytes
    }
}

/// 用无向连通分量表示完整父树：不仅父会话会保护其子会话，近期子会话也会
/// 反过来保护所有祖先及同树成员；缺失父记录时仍借助虚拟父节点关联兄弟会话。
nonisolated enum WorkspaceCleanupGraph {
    static func groups(in sessions: [WorkspaceSession]) -> [[WorkspaceSession]] {
        var records: [WorkspaceCleanupSessionKey: WorkspaceSession] = [:]
        for session in sessions {
            let key = WorkspaceCleanupSessionKey(session)
            if records[key].map({ $0.lastActiveAt > session.lastActiveAt }) != true {
                records[key] = session
            }
        }

        var edges: [WorkspaceCleanupSessionKey: Set<WorkspaceCleanupSessionKey>] = [:]
        for (key, session) in records {
            if edges[key] == nil { edges[key] = [] }
            if let parentID = session.parentSessionID, !parentID.isEmpty {
                let parent = WorkspaceCleanupSessionKey(agent: session.agent, id: parentID)
                edges[key, default: []].insert(parent)
                edges[parent, default: []].insert(key)
            }
        }

        var visited: Set<WorkspaceCleanupSessionKey> = []
        var result: [[WorkspaceSession]] = []
        let orderedKeys = records.keys.sorted { ($0.agent.rawValue, $0.id) < ($1.agent.rawValue, $1.id) }
        for key in orderedKeys where !visited.contains(key) {
            var pending = [key]
            var group: [WorkspaceSession] = []
            while let next = pending.popLast() {
                guard visited.insert(next).inserted else { continue }
                if let record = records[next] { group.append(record) }
                pending.append(contentsOf: edges[next, default: []])
            }
            if !group.isEmpty {
                result.append(group.sorted { $0.id < $1.id })
            }
        }
        return result
    }

    /// 只删除确实存在根节点的父树；环形或自引用关系不属于可安全推断的清理对象。
    static func roots(in group: [WorkspaceSession]) -> [WorkspaceSession] {
        let keys = Set(group.map(WorkspaceCleanupSessionKey.init))
        return group.filter { session in
            guard let parent = session.parentSessionID, !parent.isEmpty else { return true }
            return !keys.contains(WorkspaceCleanupSessionKey(agent: session.agent, id: parent))
        }
    }
}

/// 清理专用的删除约束跨越 actor 等待边界传递；候选和附件在调用服务前冻结，
/// 数据库事务取得写锁后再核验，不允许普通删除引擎重新发现更多后代并一并删除。
public nonisolated struct WorkspaceSessionCleanupConstraint: Sendable {
    public let sessions: [WorkspaceSession]
    public let cutoff: Date
    private let targets: [WorkspaceSessionDeletionTarget]
    private let files: [String: Fingerprint]

    private struct Fingerprint: Sendable, Equatable {
        let type: String
        let size: Int64
        let modified: Date?
        let inode: UInt64
    }

    public init(sessions: [WorkspaceSession], cutoff: Date, homeDirectory: String) throws {
        self.sessions = sessions
        self.cutoff = cutoff
        self.targets = try sessions.flatMap { try WorkspaceSessionArtifactPaths.targets(for: $0, homeDirectory: homeDirectory) }
        for session in sessions {
            guard session.lastActiveAt < cutoff else { throw Self.changed() }
            let policy = WorkspaceSessionPathPolicy(homeDirectory: homeDirectory, agent: session.agent)
            for target in try WorkspaceSessionArtifactPaths.targets(for: session, homeDirectory: homeDirectory) {
                try policy.validate(target.path, allowDirectory: target.isDirectory)
            }
        }
        self.files = try Self.snapshot(targets)
    }

    func validateObserved(_ current: [WorkspaceSession], root: WorkspaceSession) throws {
        let sameAgent = current.filter { $0.agent == root.agent }
        let tree = WorkspaceSessionTree(sessions: sameAgent)
        guard let actualRoot = sameAgent.first(where: { $0.id == root.id }) else { throw Self.changed() }
        let observed = [actualRoot] + tree.descendants(of: actualRoot).map(\.session)
        guard Set(observed.map(WorkspaceCleanupSessionKey.init)) == Set(sessions.map(WorkspaceCleanupSessionKey.init)) else { throw Self.changed() }
        for actual in observed {
            guard let expected = sessions.first(where: { $0.agent == actual.agent && $0.id == actual.id }),
                  actual.lastActiveAt < cutoff, actual.lastActiveAt <= expected.lastActiveAt,
                  actual.filePath == expected.filePath, actual.parentSessionID == expected.parentSessionID else { throw Self.changed() }
        }
    }

    func validateDatabase(ids: [String], rows: [(id: String, path: String?, date: Date?, parent: String?)]) throws {
        guard Set(ids) == Set(sessions.map(\.id)) else { throw Self.changed() }
        for identifier in ids {
            guard let row = rows.first(where: { $0.id == identifier }),
                  let expected = sessions.first(where: { $0.id == identifier }),
                  let date = row.date, date < cutoff, date <= expected.lastActiveAt,
                  row.parent == expected.parentSessionID else { throw Self.changed() }
            if let path = row.path, path != expected.filePath { throw Self.changed() }
        }
    }

    func validateFiles() throws {
        guard try Self.snapshot(targets) == files else { throw Self.changed() }
    }

    /// 清理模式只隔离已冻结的普通文件，不递归重命名／删除整目录。
    /// 校验后刚出现的新文件因此不在操作清单中，始终保留在原目录。
    func frozenFileTargets() -> [WorkspaceSessionDeletionTarget] {
        files.compactMap { path, value in value.type == FileAttributeType.typeRegular.rawValue ? WorkspaceSessionDeletionTarget(path) : nil }
    }

    func validateFile(_ path: String, originalPath: String? = nil) throws {
        guard try Self.fingerprint(path) == files[originalPath ?? path] else { throw Self.changed() }
    }

    static func changed() -> NSError {
        NSError(domain: "WorkspaceCleanup", code: 2, userInfo: [NSLocalizedDescriptionKey: "会话或附件在清理前发生变化，已拒绝扩大删除范围。"])
    }

    private static func fingerprint(_ path: String) throws -> Fingerprint {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeDirectory else { throw changed() }
            return Fingerprint(type: type?.rawValue ?? "", size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                               modified: attributes[.modificationDate] as? Date, inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                return Fingerprint(type: "missing", size: 0, modified: nil, inode: 0)
            }
            throw error
        }
    }

    private static func snapshot(_ targets: [WorkspaceSessionDeletionTarget]) throws -> [String: Fingerprint] {
        var result: [String: Fingerprint] = [:]
        var pending = targets.map(\.path)
        while let path = pending.popLast() {
            guard result[path] == nil else { continue }
            let fingerprint = try fingerprint(path)
            result[path] = fingerprint
            if fingerprint.type == FileAttributeType.typeDirectory.rawValue {
                pending += try FileManager.default.contentsOfDirectory(atPath: path).map { (path as NSString).appendingPathComponent($0) }
            }
        }
        return result
    }
}
