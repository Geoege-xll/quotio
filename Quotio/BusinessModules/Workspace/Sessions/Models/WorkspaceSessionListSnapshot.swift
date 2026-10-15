import Foundation

/// 同一份会话数据、客户端和搜索词共享一次筛选与建树结果。
/// 主行渲染需要逐个读取子任务数量；如果每行重建完整会话树，刷新开销会随主行数成倍增长。
/// 快照只派生显示数据，不修改原始会话，也不改变主会话/子任务的分类契约。
nonisolated struct WorkspaceSessionListSnapshot {
    typealias ProjectGroup = (id: String, projectName: String, directory: String?, sessions: [WorkspaceSession])

    let filteredSessions: [WorkspaceSession]
    let roots: [WorkspaceSession]
    let tree: WorkspaceSessionTree
    let projectGroups: [ProjectGroup]

    init(sessions: [WorkspaceSession], agent: WorkspaceAgent, searchText: String) {
        let source = sessions.filter { $0.agent == agent }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let sourceTree = WorkspaceSessionTree(sessions: source)
        if query.isEmpty {
            filteredSessions = source
            tree = sourceTree
        } else {
            let matched = source.filter { session in
                session.title.localizedLowercase.contains(query) ||
                    session.projectName.localizedLowercase.contains(query) ||
                    (session.projectDirectory?.localizedLowercase.contains(query) ?? false) ||
                    (session.summary?.localizedLowercase.contains(query) ?? false) ||
                    session.id.localizedLowercase.contains(query)
            }
            var visibleIDs = Set(matched.map(\.id))
            // 搜索命中子任务时保留祖先路径，使原有展开控件仍能访问命中行。
            for session in matched { visibleIDs.formUnion(sourceTree.ancestors(of: session).map(\.id)) }
            filteredSessions = source.filter { visibleIDs.contains($0.id) }
            tree = WorkspaceSessionTree(sessions: filteredSessions)
        }
        // 通用树 roots 会为孤立节点和损坏环补遍历入口，不能用于产品主会话分类。
        roots = filteredSessions.filter(\.isMainSession).sorted { $0.lastActiveAt > $1.lastActiveAt }
        let groups = Dictionary(grouping: roots) { $0.projectDirectory ?? "unknown:\($0.projectName)" }
        projectGroups = groups.map { identity, items in
            (id: identity, projectName: items.first?.projectName ?? "Unknown",
             directory: items.first?.projectDirectory, sessions: items)
        }.sorted { $0.projectName.localizedCaseInsensitiveCompare($1.projectName) == .orderedAscending }
    }
}
