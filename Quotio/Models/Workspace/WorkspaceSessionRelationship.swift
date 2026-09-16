import Foundation

/// 客户端只提供关系证据，浏览层只消费统一结果。子任务身份不依赖父记录是否仍然存在；
/// 无法读取关系的裸存储文件使用 unknown，不能仅凭“没有父 ID”冒充主会话。
public nonisolated struct WorkspaceSessionRelationship: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case main, subagent, internalSession, unknown }
    public let kind: Kind
    public let parentSessionID: String?

    public init(kind: Kind = .main, parentSessionID: String? = nil) {
        let parent = Self.identifier(parentSessionID)
        self.parentSessionID = parent
        // AGY 的父关系也可能属于内部旁支；保留 internal 身份，不伪称所有旁支都是子代理。
        self.kind = parent == nil || kind == .internalSession ? kind : .subagent
    }

    public var isMainSession: Bool { kind == .main }
    public var isSubagent: Bool { kind == .subagent }

    /// 主来源优先提供父 ID，补充来源只补缺口；任何明确的子任务证据都不能被缺省主会话覆盖。
    public func merging(_ other: Self) -> Self {
        let mergedKind: Kind = isSubagent || other.isSubagent ? .subagent
            : (kind == .internalSession || other.kind == .internalSession ? .internalSession
               : (isMainSession || other.isMainSession ? .main : .unknown))
        return Self(kind: mergedKind, parentSessionID: parentSessionID ?? other.parentSessionID)
    }

    static func identifier(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// 三个客户端的原生字段在此集中适配；数据库与文件入口调用相同函数，
/// 不使用项目名、标题、提示词、普通消息 parentUuid 或 AGY 消息 source 推断会话关系。
nonisolated enum WorkspaceSessionRelationshipAdapter {
    static func codex(source: Any?, parentID: String? = nil) -> WorkspaceSessionRelationship {
        let object = sourceObject(source)
        let sourceParent = codexParent(in: object)
        // 官方 app-server schema 使用 subAgent，SQLite/rollout 使用 subagent；昵称不属于来源类型。
        let subagent = object?["subagent"] ?? object?["subAgent"]
        let sourceName = WorkspaceSessionRelationship.identifier(source as? String)
        let subagentNames: Set<String> = ["subagent", "subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther"]
        let mainNames: Set<String> = ["cli", "vscode", "exec", "appServer", "app_server"]
        let marked = subagent != nil && !(subagent is NSNull) || sourceName.map(subagentNames.contains) == true
        let main = sourceName.map(mainNames.contains) == true || object?["custom"] is String
        return .init(kind: marked ? .subagent : (main ? .main : .unknown),
                     parentSessionID: WorkspaceSessionRelationship.identifier(parentID) ?? sourceParent)
    }

    static func claude(metadata: [String: Any], pathParentID: String? = nil) -> WorkspaceSessionRelationship {
        let marked = metadata["isSidechain"] as? Bool == true
        // 官方文档用所属 session 目录定义父关系；平铺旧文件只确认子身份，
        // 不把可能代表自身或共享上下文的 sessionId 直接猜成执行父 ID。
        let hasSessionMetadata = metadata["isSidechain"] as? Bool == false
            || WorkspaceSessionRelationship.identifier(metadata["sessionId"] as? String) != nil
        return .init(kind: marked ? .subagent : (hasSessionMetadata ? .main : .unknown), parentSessionID: pathParentID)
    }

    static func agy(metadata: [String: Any], hasSummary: Bool) -> WorkspaceSessionRelationship {
        let parent = WorkspaceSessionRelationship.identifier(metadata["parent_conversation_id"] as? String)
            ?? WorkspaceSessionRelationship.identifier(metadata["parent_id"] as? String)
        let depth = metadata["nesting_depth"] as? Int ?? 0
        let internalFlag = metadata["is_internal"] as? Bool ?? metadata["Internal"] as? Bool
        // 官方 1.2.2 isInternalTrajectory 同时涵盖子代理、battle fork、/btw 侧问；
        // 只有层级证据才明确称为 subagent。内部标记本身不提供父 ID。
        // 对应官方来源与版本边界见 docs/workspace-session-contract.md。
        let kind: WorkspaceSessionRelationship.Kind
        if depth > 0 { kind = .subagent }
        else if parent != nil || internalFlag == true { kind = .internalSession }
        else if hasSummary || internalFlag == false { kind = .main }
        else { kind = .unknown }
        return .init(kind: kind, parentSessionID: parent)
    }

    static func codexParent(in source: Any?) -> String? {
        let object = sourceObject(source)
        let subagent = (object?["subagent"] ?? object?["subAgent"]) as? [String: Any]
        let spawn = subagent?["thread_spawn"] as? [String: Any]
        return WorkspaceSessionRelationship.identifier(spawn?["parent_thread_id"] as? String)
    }

    private static func sourceObject(_ source: Any?) -> [String: Any]? {
        if let object = source as? [String: Any] { return object }
        guard let text = source as? String, let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
