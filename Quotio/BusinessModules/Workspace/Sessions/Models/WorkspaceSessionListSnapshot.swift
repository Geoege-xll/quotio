import Foundation

/// 同一份会话数据、客户端和搜索词共享一次筛选与建树结果。
/// 主行渲染需要逐个读取子任务数量；如果每行重建完整会话树，刷新开销会随主行数成倍增长。
/// 快照只派生显示数据，不修改原始会话，也不改变主会话/子任务的分类契约。
nonisolated struct WorkspaceSessionListSnapshot {
    typealias ProjectGroup = (id: String, projectName: String, directory: String?, sessions: [WorkspaceSession])

    let filteredSessions: [WorkspaceSession]
    let roots: [WorkspaceSession]
    let tree: WorkspaceSessionTree
    let searchExpandedRootIDs: Set<String>
    let projectGroups: [ProjectGroup]

    init(sessions: [WorkspaceSession], agent: WorkspaceAgent, searchText: String) {
        let source = sessions.filter { $0.agent == agent }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let sourceTree = WorkspaceSessionTree(sessions: source)
        if query.isEmpty {
            filteredSessions = source
            tree = sourceTree
            searchExpandedRootIDs = []
        } else {
            let matched = source.filter { session in
                session.title.localizedLowercase.contains(query) ||
                    session.projectName.localizedLowercase.contains(query) ||
                    (session.projectDirectory?.localizedLowercase.contains(query) ?? false) ||
                    (session.summary?.localizedLowercase.contains(query) ?? false) ||
                    session.id.localizedLowercase.contains(query)
            }
            var visibleIDs = Set(matched.map(\.id))
            var expandedRoots = Set<String>()
            // 沿原有关系保留命中行的祖先；只有本来能作为入口的主会话才需要临时展开。
            // 命中主行本身不会展开无关后代，孤儿和损坏的关系也不会因此获得入口。
            for session in matched {
                for ancestor in sourceTree.ancestors(of: session) {
                    visibleIDs.insert(ancestor.id)
                    if ancestor.isMainListVisible { expandedRoots.insert(ancestor.id) }
                }
            }
            filteredSessions = source.filter { visibleIDs.contains($0.id) }
            tree = WorkspaceSessionTree(sessions: filteredSessions)
            searchExpandedRootIDs = expandedRoots
        }
        // 通用树 roots 会为孤立节点和损坏环补遍历入口，不能用于产品主会话分类；
        // 同时过滤已归档、跨客户端导入、非交互子探针与空壳记录，仅展示有效可浏览主会话。
        roots = filteredSessions.filter(\.isMainListVisible).sorted { $0.lastActiveAt > $1.lastActiveAt }
        let groups = Dictionary(grouping: roots) { $0.projectDirectory ?? "unknown:\($0.projectName)" }
        projectGroups = groups.map { identity, items in
            (id: identity, projectName: items.first?.projectName ?? "Unknown",
             directory: items.first?.projectDirectory, sessions: items)
        }.sorted { $0.projectName.localizedCaseInsensitiveCompare($1.projectName) == .orderedAscending }
    }
}

extension WorkspaceSessionRelationship.Kind {
    // 展示映射不增补关系证据，也不参与主会话入口判定。
    nonisolated var presentationTitleKey: String {
        switch self {
        case .main: "workspace.sessions.kind.main"
        case .subagent: "workspace.sessions.kind.subagent"
        case .internalSession: "workspace.sessions.kind.internal"
        case .unknown: "workspace.sessions.kind.unknown"
        }
    }
}
