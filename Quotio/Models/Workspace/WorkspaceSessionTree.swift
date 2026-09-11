import Foundation

/// 会话图以“客户端 + 会话 ID”作为身份，避免不同客户端使用相同 ID 时串联。
/// 浏览、搜索和删除后的状态更新共用遍历规则；孤立节点仍可见，损坏的环不会无限递归。
public nonisolated struct WorkspaceSessionTree {
    private let sessions: [WorkspaceSession]
    private let lookup: [String: WorkspaceSession]
    private let children: [String: [WorkspaceSession]]

    public init(sessions: [WorkspaceSession]) {
        var lookup: [String: WorkspaceSession] = [:]
        for session in sessions where lookup[Self.key(session)] == nil {
            lookup[Self.key(session)] = session
        }
        self.lookup = lookup
        var included = Set<String>()
        self.sessions = sessions.filter { included.insert(Self.key($0)).inserted }
        self.children = Dictionary(grouping: self.sessions.filter { $0.parentSessionID != nil }) {
            Self.key(agent: $0.agent, id: $0.parentSessionID!)
        }
    }

    public static func key(_ session: WorkspaceSession) -> String {
        key(agent: session.agent, id: session.id)
    }

    public static func key(agent: WorkspaceAgent, id: String) -> String {
        "\(agent.rawValue):\(id)"
    }

    public var roots: [WorkspaceSession] {
        var result = sessions.filter { session in
            guard let parent = session.parentSessionID else { return true }
            return parent == session.id || lookup[Self.key(agent: session.agent, id: parent)] == nil
        }
        var reached = Set<String>()
        for root in result {
            reached.insert(Self.key(root))
            reached.formUnion(descendants(of: root).map { Self.key($0.session) })
        }
        // 环形损坏记录没有自然根：稳定选择一个入口，使其内容仍能被检查和删除。
        for candidate in sessions.sorted(by: { Self.key($0) < Self.key($1) }) where !reached.contains(Self.key(candidate)) {
            result.append(candidate)
            reached.insert(Self.key(candidate))
            reached.formUnion(descendants(of: candidate).map { Self.key($0.session) })
        }
        return result.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    public func descendants(of parent: WorkspaceSession) -> [(session: WorkspaceSession, depth: Int)] {
        var result: [(session: WorkspaceSession, depth: Int)] = []
        var seen: Set<String> = [Self.key(parent)]
        var pending = (children[Self.key(parent)] ?? []).reversed().map { ($0, 1) }
        while let (session, depth) = pending.popLast() {
            guard seen.insert(Self.key(session)).inserted else { continue }
            result.append((session, depth))
            pending.append(contentsOf: (children[Self.key(session)] ?? []).reversed().map { ($0, depth + 1) })
        }
        return result
    }

    public func ancestors(of session: WorkspaceSession) -> [WorkspaceSession] {
        var current = session
        var result: [WorkspaceSession] = []
        var seen: Set<String> = [Self.key(session)]
        while let parentID = current.parentSessionID,
              let parent = lookup[Self.key(agent: current.agent, id: parentID)],
              seen.insert(Self.key(parent)).inserted {
            result.append(parent)
            current = parent
        }
        return result
    }
}
