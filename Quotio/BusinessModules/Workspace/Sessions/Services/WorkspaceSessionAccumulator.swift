import Foundation

/// 同一客户端的数据库、摘要和正文文件可能重复登记同一 ID。
/// 调用方按展示信息的优先级写入；后续来源补关系证据，不能重复创建行或抹掉已知子身份。
nonisolated struct WorkspaceSessionAccumulator {
    private(set) var sessions: [WorkspaceSession] = []
    private var indices: [String: Int] = [:]

    func contains(id: String, agent: WorkspaceAgent) -> Bool {
        indices[WorkspaceSessionTree.key(agent: agent, id: id)] != nil
    }

    mutating func append(_ session: WorkspaceSession) {
        let key = WorkspaceSessionTree.key(session)
        if let index = indices[key] {
            sessions[index] = sessions[index].mergingSupplement(session)
        } else {
            indices[key] = sessions.count
            sessions.append(session)
        }
    }

    mutating func mergeRelationship(_ relationship: WorkspaceSessionRelationship, id: String, agent: WorkspaceAgent) {
        guard let index = indices[WorkspaceSessionTree.key(agent: agent, id: id)] else { return }
        sessions[index] = sessions[index].mergingRelationship(relationship)
    }
}
