//
//  WorkspaceSessionService.swift
//  Quotio - Unified Agent Session Management Service
//  Encapsulated Provider Architecture for Claude, Codex, OpenCode, Pi, and Antigravity (AGY)
//

import Foundation
import SQLite3
import AppKit

// MARK: - Provider Protocol

/// 客户端磁盘协议必须显式退出模块默认的 MainActor 隔离，否则非隔离 struct 的协议实现
/// 仍会被推断为主线程方法，扫描、SQLite 等锁和删除文件都会阻塞界面。
/// @concurrent 同时约束具体实现：即使从主线程直接调用 Provider，也要切换到通用执行器。
public nonisolated protocol AgentSessionProviderProtocol: Sendable {
    var agent: WorkspaceAgent { get }
    @concurrent func scanSessions() async -> [WorkspaceSession]
    @concurrent func loadMessages(for session: WorkspaceSession) async throws -> [WorkspaceSessionMessage]
    @concurrent func deleteSession(_ session: WorkspaceSession) async throws -> Bool
}

// MARK: - WorkspaceSessionService (Facade & Coordinator)

public actor WorkspaceSessionService {
    public static let shared = WorkspaceSessionService()

    private let homeDir: String
    private let fileManager = FileManager.default
    private let providers: [WorkspaceAgent: any AgentSessionProviderProtocol]

    public init(homeDir: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.homeDir = homeDir
        self.providers = [
            .claude: ClaudeSessionProvider(homeDir: homeDir),
            .codex: CodexSessionProvider(homeDir: homeDir),
            .opencode: OpenCodeSessionProvider(homeDir: homeDir),
            .pi: PiSessionProvider(homeDir: homeDir),
            .agy: AGYSessionProvider(homeDir: homeDir)
        ]
    }

    // MARK: - Scan Sessions

    public func scanAllSessions(agentFilter: WorkspaceAgent? = nil) async -> [WorkspaceSession] {
        var results: [WorkspaceSession] = []

        if let filter = agentFilter {
            if let provider = providers[filter] {
                results = await provider.scanSessions()
            }
        } else {
            // Concurrent scan across all providers
            await withTaskGroup(of: [WorkspaceSession].self) { group in
                for provider in providers.values {
                    group.addTask {
                        await provider.scanSessions()
                    }
                }
                for await agentSessions in group {
                    results.append(contentsOf: agentSessions)
                }
            }
        }

        // Sort descending by last active date
        return results.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    // MARK: - Load Messages

    public func loadSessionMessages(session: WorkspaceSession) async throws -> [WorkspaceSessionMessage] {
        guard let provider = providers[session.agent] else {
            throw NSError(
                domain: "WorkspaceSessionService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No provider found for agent \(session.agent.displayName)"]
            )
        }
        return try await provider.loadMessages(for: session)
    }

    // MARK: - Safe Delete Session

    public func deleteSession(_ session: WorkspaceSession) async throws -> Bool {
        guard let provider = providers[session.agent] else { return false }
        // 安全检查位于每个 Provider 共用的删除引擎中，直接调用 Provider 也不能绕过保护。
        // actor 在等待并发 Provider 时允许重入，不能把 Facade 当作删除操作的全局串行锁。
        // 当前页面写入由共享 ViewModel 的删除状态互斥；SQLite 写锁和回滚仍由事务引擎管理。
        return try await provider.deleteSession(session)
    }

    public func deleteSession(_ session: WorkspaceSession, constrainedBy constraint: WorkspaceSessionCleanupConstraint) async throws -> Bool {
        guard let provider = providers[session.agent] else { return false }
        let current = await provider.scanSessions()
        try constraint.validateObserved(current, root: session)
        // 此后引擎内部没有 await；SQLite 下仍在 BEGIN IMMEDIATE 之后重查后代、来源与活动字段。
        return try WorkspaceSessionDeletionEngine.delete(session, expectedAgent: session.agent, homeDirectory: homeDir,
                                                          relatedSessions: current, cleanupConstraint: constraint)
    }

    // MARK: - Resume in Terminal

    public func resumeInTerminal(session: WorkspaceSession) async throws {
        // 不信任持久化的 resumeCommand；按客户端协议重新构造参数，缺失 cwd 时使用真实 home。
        let command = WorkspaceSessionCommandBuilder.terminalCommand(session: session, homeDirectory: homeDir)
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        let source = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        try await MainActor.run {
            guard let script = NSAppleScript(source: source) else {
                throw WorkspaceSessionOperationError.terminal("无法构造 AppleScript")
            }
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error {
                throw WorkspaceSessionOperationError.terminal(error[NSAppleScript.errorMessage] as? String ?? error.description)
            }
        }
    }

}

// MARK: - Shared File & String Utilities

nonisolated enum SessionIOUtils {
    /// 按列探测旧版数据库能力，避免一个可选列缺失导致所有关系字段一起降级。
    /// 表名只接受代码内的固定标识符，不能将会话元数据拼接成 SQL。
    static func columns(in table: String, database: OpaquePointer?) -> Set<String> {
        guard ["threads", "thread_spawn_edges", "conversation_summaries"].contains(table) else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 1) { names.insert(String(cString: text)) }
        }
        return names
    }

    static func readHeadAndTailLines(path: String, headCount: Int, tailCount: Int) -> (head: [String], tail: [String])? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            // 按完整的换行边界解码，不能把 UTF-8 字节流固定截成 64 KB 后整块丢弃。
            let limit = 2 * 1024 * 1024
            var headData = Data()
            while headData.count < limit && headData.filter({ $0 == 10 }).count < headCount {
                guard let chunk = try handle.read(upToCount: min(64 * 1024, limit - headData.count)), !chunk.isEmpty else { break }
                headData.append(chunk)
            }
            let headAtEnd = UInt64(headData.count) == size
            var headParts = headData.split(separator: 10, omittingEmptySubsequences: false)
            if !headAtEnd && headData.last != 10 { headParts.removeLast() }
            let head = headParts.compactMap { String(data: Data($0), encoding: .utf8) }.filter { !$0.isEmpty }
            // 关系补全只读取头部元数据，避免为数据库已登记的每条会话重复读取大段正文尾部。
            if tailCount == 0 { return (Array(head.prefix(headCount)), []) }
            let offset = size > UInt64(limit) ? size - UInt64(limit) : 0
            try handle.seek(toOffset: offset)
            let tailData = try handle.readToEnd() ?? Data()
            var tailParts = tailData.split(separator: 10, omittingEmptySubsequences: false)
            // 非零偏移可能落在一条 JSON 或一个中文字符中间，首个碎片不能当成完整记录。
            if offset > 0 && !tailParts.isEmpty { tailParts.removeFirst() }
            let tail = tailParts.compactMap { String(data: Data($0), encoding: .utf8) }.filter { !$0.isEmpty }
            return (Array(head.prefix(headCount)), Array(tail.suffix(tailCount)))
        } catch { return nil }
    }

    static func parseDate(_ value: String) -> Date? {
        let normalized = value.replacingOccurrences(of: " ", with: "T")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: normalized) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: normalized)
    }

    static func extractUUID(from string: String) -> String? {
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        if let match = regex.firstMatch(in: string, range: range),
           let matchRange = Range(match.range, in: string) {
            return String(string[matchRange])
        }
        return nil
    }


}

// MARK: - Claude Provider

public nonisolated struct ClaudeSessionProvider: AgentSessionProviderProtocol {
    public let agent: WorkspaceAgent = .claude
    private let homeDir: String
    private var fileManager: FileManager { FileManager.default }

    public init(homeDir: String) {
        self.homeDir = homeDir
    }

    @concurrent
    public func scanSessions() async -> [WorkspaceSession] {
        let projectsDir = (homeDir as NSString).appendingPathComponent(".claude/projects")
        guard fileManager.fileExists(atPath: projectsDir) else { return [] }

        var accumulated = WorkspaceSessionAccumulator()
        var flatSessions: [WorkspaceSession] = []
        let enumerator = fileManager.enumerator(atPath: projectsDir)

        while let file = enumerator?.nextObject() as? String {
            guard file.hasSuffix(".jsonl") else { continue }
            let fullPath = (projectsDir as NSString).appendingPathComponent(file)

            if file.contains("/subagents/") {
                if let subMeta = parseClaudeSubagentMeta(filePath: fullPath, relativePath: file) {
                    accumulated.append(subMeta)
                }
            } else {
                if let meta = parseClaudeSessionMeta(filePath: fullPath) {
                    flatSessions.append(meta)
                }
            }
        }

        // 官方 subagents 路径比历史平铺副本提供更完整的身份，先入集合，合并时保留该正文路径。
        flatSessions.forEach { accumulated.append($0) }
        return accumulated.sessions
    }

    private func parseClaudeSubagentMeta(filePath: String, relativePath: String) -> WorkspaceSession? {
        let parts = relativePath.components(separatedBy: "/subagents/")
        guard parts.count >= 2 else { return nil }

        let parentDir = parts[0]
        let parentUUID = URL(fileURLWithPath: parentDir).lastPathComponent
        let subagentFile = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        let subagentID = subagentFile

        let metaPath = (filePath as NSString).deletingPathExtension + ".meta.json"
        var description: String? = nil
        var agentType: String? = nil

        if fileManager.fileExists(atPath: metaPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: metaPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            description = json["description"] as? String
            agentType = json["agentType"] as? String
        }

        guard let (head, tail) = SessionIOUtils.readHeadAndTailLines(path: filePath, headCount: 10, tailCount: 10) else {
            return nil
        }

        var cwd: String?
        var createdAt: Date?
        var firstPrompt: String?

        for line in head {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if cwd == nil { cwd = json["cwd"] as? String }
            if createdAt == nil, let ts = json["timestamp"] as? String {
                createdAt = SessionIOUtils.parseDate(ts)
            }
            if firstPrompt == nil {
                if let msg = json["message"] as? [String: Any],
                   let role = msg["role"] as? String, role == "user" {
                    firstPrompt = extractUserPrompt(from: msg["content"])
                } else if let prompt = json["prompt"] as? String, !prompt.isEmpty {
                    firstPrompt = prompt
                }
            }
        }

        var lastActiveAt = createdAt ?? Date()
        for line in tail.reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let ts = json["timestamp"] as? String, let date = SessionIOUtils.parseDate(ts) {
                lastActiveAt = date
                break
            }
        }

        let attributes = (try? fileManager.attributesOfItem(atPath: filePath)) ?? [:]
        let fileSize = (attributes[.size] as? Int64) ?? 0
        let modDate = (attributes[.modificationDate] as? Date) ?? lastActiveAt
        let projectName = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? URL(fileURLWithPath: parentDir).deletingLastPathComponent().lastPathComponent

        let typePrefix = (agentType != nil && !agentType!.isEmpty && agentType != "claude") ? "[\(agentType!)] " : ""
        let displayTitle = description.map { "\(typePrefix)\($0)" } ?? firstPrompt ?? "子任务 (\(subagentID.prefix(8)))"

        return WorkspaceSession(
            id: subagentID,
            agent: .claude,
            title: displayTitle,
            summary: description ?? firstPrompt,
            projectDirectory: cwd,
            projectName: projectName,
            createdAt: createdAt,
            lastActiveAt: modDate,
            filePath: filePath,
            fileSizeBytes: fileSize,
            messageCount: 0,
            resumeCommand: WorkspaceSessionCommandBuilder.resumeCommand(agent: .claude, id: subagentID, parentID: parentUUID),
            relationship: WorkspaceSessionRelationshipAdapter.claude(metadata: [:], pathParentID: parentUUID)
        )
    }

    private func parseClaudeSessionMeta(filePath: String) -> WorkspaceSession? {
        guard let (head, tail) = SessionIOUtils.readHeadAndTailLines(path: filePath, headCount: 15, tailCount: 20) else {
            return nil
        }

        var sessionID: String?
        var cwd: String?
        var createdAt: Date?
        var firstUserPrompt: String?
        var agentID: String?
        var relationshipMetadata: [[String: Any]] = []

        for line in head {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if sessionID == nil, let sid = json["sessionId"] as? String {
                sessionID = sid
            }
            relationshipMetadata.append(json)
            if agentID == nil { agentID = WorkspaceSessionRelationship.identifier(json["agentId"] as? String) }
            if cwd == nil, let dir = json["cwd"] as? String {
                cwd = dir
            }
            if createdAt == nil, let ts = json["timestamp"] as? String {
                createdAt = SessionIOUtils.parseDate(ts)
            }

            if firstUserPrompt == nil {
                if let msg = json["message"] as? [String: Any],
                   let role = msg["role"] as? String, role == "user" {
                    firstUserPrompt = extractUserPrompt(from: msg["content"])
                } else if let prompt = json["prompt"] as? String, !prompt.isEmpty {
                    firstUserPrompt = prompt
                }
            }

            // 继续检查有界头部中的关系字段，不能因标题已经齐全就跳过后续 sidechain 标记。
        }

        var lastActiveAt = createdAt ?? Date()
        var customTitle: String?

        for line in tail.reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let ts = json["timestamp"] as? String, let date = SessionIOUtils.parseDate(ts) {
                lastActiveAt = date
                break
            }
            if customTitle == nil, let title = json["title"] as? String, !title.isEmpty {
                customTitle = title
            }
        }

        let filenameID = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        let hasSidechain = relationshipMetadata.contains { $0["isSidechain"] as? Bool == true }
        // 平铺子代理文件也可能共享父 sessionId；采用与 subagents 目录一致的 agent-<id> 身份。
        let sid = hasSidechain ? agentID.map { $0.hasPrefix("agent-") ? $0 : "agent-\($0)" } ?? filenameID : sessionID ?? filenameID
        let relationship = relationshipMetadata.reduce(WorkspaceSessionRelationship(kind: .unknown)) {
            $0.merging(WorkspaceSessionRelationshipAdapter.claude(metadata: $1))
        }
        let attributes = (try? fileManager.attributesOfItem(atPath: filePath)) ?? [:]
        let fileSize = (attributes[.size] as? Int64) ?? 0
        let modDate = (attributes[.modificationDate] as? Date) ?? lastActiveAt
        let projectName = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown"
        let displayTitle = customTitle ?? firstUserPrompt ?? "Claude Session (\(sid.prefix(8)))"

        return WorkspaceSession(
            id: sid,
            agent: .claude,
            title: displayTitle,
            summary: firstUserPrompt,
            projectDirectory: cwd,
            projectName: projectName,
            createdAt: createdAt,
            lastActiveAt: modDate,
            filePath: filePath,
            fileSizeBytes: fileSize,
            messageCount: 0,
            resumeCommand: WorkspaceSessionCommandBuilder.resumeCommand(agent: .claude, id: sid, parentID: relationship.parentSessionID),
            relationship: relationship
        )
    }

    private func extractUserPrompt(from content: Any?) -> String? {
        if let str = content as? String { return str }
        if let array = content as? [[String: Any]] {
            return array.compactMap { $0["text"] as? String }.first
        }
        return nil
    }

    @concurrent
    public func loadMessages(for session: WorkspaceSession) async throws -> [WorkspaceSessionMessage] {
        try WorkspaceSessionPathPolicy(homeDirectory: homeDir, agent: .claude).validate(session.filePath)
        let content = try String(contentsOfFile: session.filePath, encoding: .utf8)
        var messages: [WorkspaceSessionMessage] = []

        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let ts = (json["timestamp"] as? String).flatMap { SessionIOUtils.parseDate($0) }

            if let msg = json["message"] as? [String: Any] {
                let roleStr = msg["role"] as? String ?? "assistant"
                let role: WorkspaceMessageRole = roleStr == "user" ? .user : .assistant
                let text = extractContentText(from: msg["content"])
                if !text.isEmpty {
                    messages.append(WorkspaceSessionMessage(role: role, content: text, timestamp: ts))
                }
            } else if let prompt = json["prompt"] as? String, !prompt.isEmpty {
                messages.append(WorkspaceSessionMessage(role: .user, content: prompt, timestamp: ts))
            }
        }
        return messages
    }

    private func extractContentText(from content: Any?) -> String {
        if let str = content as? String { return str }
        if let array = content as? [[String: Any]] {
            return array.compactMap { item -> String? in
                if let text = item["text"] as? String { return text }
                if let contentStr = item["content"] as? String { return contentStr }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }

    @concurrent
    public func deleteSession(_ session: WorkspaceSession) async throws -> Bool {
        // 路径校验、完整级联计划和回滚策略由统一引擎负责，避免各客户端实现漂移。
        try WorkspaceSessionDeletionEngine.delete(session, expectedAgent: .claude, homeDirectory: homeDir)
    }
}

// MARK: - Codex Provider

public nonisolated struct CodexSessionProvider: AgentSessionProviderProtocol {
    public let agent: WorkspaceAgent = .codex
    private let homeDir: String
    private var fileManager: FileManager { FileManager.default }

    public init(homeDir: String) {
        self.homeDir = homeDir
    }

    @concurrent
    public func scanSessions() async -> [WorkspaceSession] {
        let codexDir = (homeDir as NSString).appendingPathComponent(".codex")
        let state5Path = (codexDir as NSString).appendingPathComponent("state_5.sqlite")

        // 已归档记录也用于存储管理；文件扫描只补充数据库尚未登记的会话。
        let databaseSessions = fileManager.fileExists(atPath: state5Path) ? scanCodexSQLite(dbPath: state5Path) : []

        // 2. Fallback: Scan filesystem .jsonl files
        let sessionsDir = (codexDir as NSString).appendingPathComponent("sessions")
        let archivedDir = (codexDir as NSString).appendingPathComponent("archived_sessions")
        let indexPath = (codexDir as NSString).appendingPathComponent("session_index.jsonl")

        var titles: [String: String] = [:]
        if let indexContent = try? String(contentsOfFile: indexPath, encoding: .utf8) {
            for line in indexContent.components(separatedBy: .newlines) {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = json["id"] as? String,
                      let title = json["thread_name"] as? String else { continue }
                titles[id] = title
            }
        }

        var accumulated = WorkspaceSessionAccumulator()
        databaseSessions.forEach { accumulated.append($0) }
        let knownPaths = Dictionary(databaseSessions.map { ($0.filePath, $0.id) }, uniquingKeysWith: { first, _ in first })

        for root in [sessionsDir, archivedDir] where fileManager.fileExists(atPath: root) {
            let enumerator = fileManager.enumerator(atPath: root)
            while let file = enumerator?.nextObject() as? String {
                guard file.hasSuffix(".jsonl") else { continue }
                let fullPath = (root as NSString).appendingPathComponent(file)
                if let id = knownPaths[fullPath] {
                    // SQLite 的展示字段优先，但不能覆盖 rollout 中更完整的关系证据。
                    accumulated.mergeRelationship(readCodexRelationship(filePath: fullPath, expectedID: id), id: id, agent: .codex)
                    continue
                }
                if let meta = parseCodexSessionMeta(filePath: fullPath, titles: titles) {
                    accumulated.append(meta)
                }
            }
        }
        return accumulated.sessions
    }

    private func scanCodexSQLite(dbPath: String) -> [WorkspaceSession] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        let columns = SessionIOUtils.columns(in: "threads", database: db)
        guard columns.contains("id") else { return [] }
        let edgeColumns = SessionIOUtils.columns(in: "thread_spawn_edges", database: db)
        let hasEdges = edgeColumns.isSuperset(of: ["parent_thread_id", "child_thread_id"])
        func column(_ name: String) -> String { columns.contains(name) ? "t.\(name)" : "NULL" }
        let query = """
        SELECT
            t.id,
            \(column("title")),
            \(column("first_user_message")),
            \(column("cwd")),
            \(column("rollout_path")),
            \(column("created_at")),
            \(column("updated_at")),
            \(hasEdges ? "e.parent_thread_id" : "NULL"),
            \(column("source")),
            \(column("agent_nickname")),
            \(column("agent_role"))
        FROM threads t
        \(hasEdges ? "LEFT JOIN thread_spawn_edges e ON t.id = e.child_thread_id" : "")
        ORDER BY \(columns.contains("updated_at") ? "t.updated_at" : "t.id") DESC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var sessions: [WorkspaceSession] = []
        var seenIDs = Set<String>()

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idText)
            guard !seenIDs.contains(id) else { continue }
            seenIDs.insert(id)

            let rawTitle = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) }
            let firstUserMsg = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) }
            let cwd = sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) }
            let rolloutPath = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) } ?? ""
            let createdAtSec = sqlite3_column_int64(stmt, 5)
            let updatedAtSec = sqlite3_column_int64(stmt, 6)
            var parentThreadID = sqlite3_column_text(stmt, 7).flatMap { String(cString: $0) }
                .flatMap { $0.isEmpty ? nil : $0 }
            let source = sqlite3_column_text(stmt, 8).flatMap { String(cString: $0) }
            let agentNickname = sqlite3_column_text(stmt, 9).flatMap { String(cString: $0) }
            let agentRole = sqlite3_column_text(stmt, 10).flatMap { String(cString: $0) }

            // 边表缺失或父 ID 为空时，沿用 JSONL 与删除检查共同使用的结构化来源解析，
            // 避免把非 UUID 的有效父 ID 丢掉，导致原本能挂载的子会话变成孤立节点。
            if parentThreadID == nil, let source {
                parentThreadID = WorkspaceSessionDeletionEngine.parentThreadID(in: source)
            }

            let relationship = WorkspaceSessionRelationshipAdapter.codex(source: source, parentID: parentThreadID)
            let isSubagent = relationship.isSubagent
            let createdDate = createdAtSec > 0 ? Date(timeIntervalSince1970: TimeInterval(createdAtSec)) : Date()
            let updatedDate = updatedAtSec > 0 ? Date(timeIntervalSince1970: TimeInterval(updatedAtSec)) : createdDate
            let projectName = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown"

            var displayTitle = ""
            if isSubagent {
                if let nick = agentNickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nick.isEmpty {
                    if let role = agentRole?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty {
                        displayTitle = "\(nick) (\(role))"
                    } else {
                        displayTitle = nick
                    }
                } else if let first = firstUserMsg?.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty, !first.hasPrefix("<") {
                    displayTitle = first
                } else if let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, !title.hasPrefix("<") {
                    displayTitle = title
                } else {
                    displayTitle = "子任务 (\(id.prefix(8)))"
                }
            } else {
                if let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, !title.hasPrefix("<"), !title.hasPrefix("# Files") {
                    displayTitle = title
                } else if let first = firstUserMsg?.trimmingCharacters(in: .whitespacesAndNewlines), !first.isEmpty, !first.hasPrefix("<"), !first.hasPrefix("# Files") {
                    displayTitle = first
                } else if let raw = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                    displayTitle = raw
                } else {
                    displayTitle = "Codex Session (\(id.prefix(8)))"
                }
            }

            let singleLineTitle = displayTitle.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? displayTitle

            sessions.append(WorkspaceSession(
                id: id,
                agent: .codex,
                title: singleLineTitle,
                summary: firstUserMsg,
                projectDirectory: cwd,
                projectName: projectName,
                createdAt: createdDate,
                lastActiveAt: updatedDate,
                filePath: rolloutPath,
                fileSizeBytes: 0,
                messageCount: 0,
                resumeCommand: WorkspaceSessionCommandBuilder.resumeCommand(agent: .codex, id: id),
                relationship: relationship
            ))
        }

        return sessions
    }

    private func parseCodexSessionMeta(filePath: String, titles: [String: String]) -> WorkspaceSession? {
        guard let (head, tail) = SessionIOUtils.readHeadAndTailLines(path: filePath, headCount: 15, tailCount: 25) else {
            return nil
        }

        var sessionID: String?
        var cwd: String?
        var createdAt: Date?
        var firstPrompt: String?
        var relationship = WorkspaceSessionRelationship(kind: .unknown)

        for line in head {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let itemType = json["type"] as? String
            let payload = json["payload"] as? [String: Any]
            if itemType == "session_meta" {
                // guardian 等辅助会话只有 source.subagent，没有父 ID；身份与父关系必须分别读取。
                // 与 SQLite 共用官方来源类型适配，不用昵称推断身份。
                relationship = relationship.merging(WorkspaceSessionRelationshipAdapter.codex(
                    source: payload?["source"]))
            }

            if itemType == "session_meta" || payload?["id"] != nil || payload?["session_id"] != nil {
                if sessionID == nil {
                    sessionID = payload?["id"] as? String ?? payload?["session_id"] as? String
                }
                if cwd == nil {
                    cwd = payload?["cwd"] as? String
                }
                if createdAt == nil, let ts = payload?["timestamp"] as? String {
                    createdAt = SessionIOUtils.parseDate(ts)
                }
            }

            if sessionID == nil {
                sessionID = json["session_id"] as? String ?? json["id"] as? String
            }
            if cwd == nil {
                cwd = json["cwd"] as? String
            }
            if createdAt == nil, let ts = json["timestamp"] as? String {
                createdAt = SessionIOUtils.parseDate(ts)
            }

            if firstPrompt == nil {
                if itemType == "response_item",
                   payload?["type"] as? String == "message",
                   payload?["role"] as? String == "user",
                   let content = payload?["content"] as? [[String: Any]] {
                    for item in content {
                        if let txt = item["text"] as? String {
                            let cleanText = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !cleanText.isEmpty &&
                               !cleanText.hasPrefix("<environment_context>") &&
                               !cleanText.hasPrefix("<recommended_plugins>") &&
                               !cleanText.hasPrefix("# AGENTS.md") &&
                               !cleanText.hasPrefix("<model_switch>") {
                                firstPrompt = cleanText
                                break
                            }
                        }
                    }
                } else if let prompt = json["prompt"] as? String, !prompt.isEmpty {
                    firstPrompt = prompt
                }
            }
        }

        let attributes = (try? fileManager.attributesOfItem(atPath: filePath)) ?? [:]
        let fileSize = (attributes[.size] as? Int64) ?? 0
        var lastActiveAt = (attributes[.modificationDate] as? Date) ?? (createdAt ?? Date())

        for line in tail.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let ts = json["timestamp"] as? String, let date = SessionIOUtils.parseDate(ts) {
                lastActiveAt = date
                break
            }
        }

        let filename = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        let sid: String
        // source/边表才定义执行关系；带两个 UUID 的旧文件名也可能是普通 fork，不能据此猜父任务。
        if let id = sessionID, !id.isEmpty {
            sid = id
        } else if let uuidMatch = SessionIOUtils.extractUUID(from: filename.components(separatedBy: "_").last ?? filename) {
            sid = uuidMatch
        } else {
            sid = filename
        }

        let isSubagent = relationship.isSubagent
        let knownTitle = titles[sid]
        let projectName = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown"
        let fallbackTitle = isSubagent ? "子任务 (\(sid.prefix(8)))" : "Codex Session (\(sid.prefix(8)))"
        let displayTitle = knownTitle ?? firstPrompt ?? fallbackTitle

        return WorkspaceSession(
            id: sid,
            agent: .codex,
            title: displayTitle,
            summary: firstPrompt,
            projectDirectory: cwd,
            projectName: projectName,
            createdAt: createdAt,
            lastActiveAt: lastActiveAt,
            filePath: filePath,
            fileSizeBytes: fileSize,
            messageCount: 0,
            resumeCommand: WorkspaceSessionCommandBuilder.resumeCommand(agent: .codex, id: sid),
            relationship: relationship
        )
    }

    private func readCodexRelationship(filePath: String, expectedID: String) -> WorkspaceSessionRelationship {
        guard let lines = SessionIOUtils.readHeadAndTailLines(path: filePath, headCount: 15, tailCount: 0)?.head else {
            return .init(kind: .unknown)
        }
        return lines.reduce(WorkspaceSessionRelationship(kind: .unknown)) { relationship, line in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "session_meta", let payload = json["payload"] as? [String: Any] else { return relationship }
            // 路径相同不保证记录相同；陈旧数据库指到另一份 rollout 时不能借用其父子关系。
            guard payload["id"] as? String == expectedID else { return relationship }
            return relationship.merging(WorkspaceSessionRelationshipAdapter.codex(
                source: payload["source"]))
        }
    }

    @concurrent
    public func loadMessages(for session: WorkspaceSession) async throws -> [WorkspaceSessionMessage] {
        try WorkspaceSessionPathPolicy(homeDirectory: homeDir, agent: .codex).validate(session.filePath)
        let content = try String(contentsOfFile: session.filePath, encoding: .utf8)
        var messages: [WorkspaceSessionMessage] = []

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            var itemType = json["type"] as? String
            var payload = json["payload"] as? [String: Any]
            if itemType == nil, let respItem = json["response_item"] as? [String: Any] {
                itemType = "response_item"
                payload = (respItem["payload"] as? [String: Any]) ?? respItem
            }
            let ts = (json["timestamp"] as? String).flatMap { SessionIOUtils.parseDate($0) }

            if itemType == "response_item", let p = payload {
                let pType = p["type"] as? String
                if pType == "message" {
                    let roleStr = p["role"] as? String ?? "assistant"
                    let role: WorkspaceMessageRole = roleStr == "user" ? .user : .assistant
                    var textParts: [String] = []
                    if let directText = p["text"] as? String {
                        textParts.append(directText)
                    }
                    if let contentArr = p["content"] as? [[String: Any]] {
                        for c in contentArr {
                            if let txt = c["text"] as? String {
                                textParts.append(txt)
                            }
                        }
                    }
                    let combined = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !combined.isEmpty {
                        messages.append(WorkspaceSessionMessage(role: role, content: combined, timestamp: ts))
                    }
                } else if pType == "custom_tool_call" {
                    let toolName = p["name"] as? String ?? "tool"
                    let input = p["input"] as? String ?? ""
                    messages.append(WorkspaceSessionMessage(
                        role: .tool,
                        content: "调用工具: \(toolName)\n\(input)",
                        timestamp: ts,
                        toolCalls: [toolName]
                    ))
                } else if pType == "reasoning", let summary = p["summary"] as? [[String: Any]] {
                    let summaryText = summary.compactMap { $0["text"] as? String }.joined(separator: " ")
                    if !summaryText.isEmpty {
                        messages.append(WorkspaceSessionMessage(role: .assistant, content: "💭 \(summaryText)", timestamp: ts))
                    }
                }
            } else if let prompt = json["prompt"] as? String, !prompt.isEmpty {
                messages.append(WorkspaceSessionMessage(role: .user, content: prompt, timestamp: ts))
            }
        }
        return messages
    }

    @concurrent
    public func deleteSession(_ session: WorkspaceSession) async throws -> Bool {
        // 数据库存在时仍可能漏登记文件子任务；删除使用与浏览相同的合并关系，再由事务复核。
        let related = await scanSessions()
        return try WorkspaceSessionDeletionEngine.delete(session, expectedAgent: .codex, homeDirectory: homeDir, relatedSessions: related)
    }
}

// MARK: - OpenCode Provider

public nonisolated struct OpenCodeSessionProvider: AgentSessionProviderProtocol {
    public let agent: WorkspaceAgent = .opencode
    private let homeDir: String
    private var fileManager: FileManager { FileManager.default }

    public init(homeDir: String) {
        self.homeDir = homeDir
    }

    @concurrent
    public func scanSessions() async -> [WorkspaceSession] {
        let baseDir = (homeDir as NSString).appendingPathComponent(".local/share/opencode")
        let dbPath = (baseDir as NSString).appendingPathComponent("opencode.db")

        // 1. Primary: SQLite session table
        if fileManager.fileExists(atPath: dbPath) {
            let sqliteSessions = scanOpenCodeSQLite(dbPath: dbPath)
            if !sqliteSessions.isEmpty { return sqliteSessions }
        }

        // 2. Fallback: JSON storage files
        let storageDir = (baseDir as NSString).appendingPathComponent("storage/session")
        guard fileManager.fileExists(atPath: storageDir) else { return [] }

        var sessions: [WorkspaceSession] = []
        if let files = fileManager.enumerator(atPath: storageDir) {
            while let file = files.nextObject() as? String {
                guard file.hasSuffix(".json") else { continue }
                let fullPath = (storageDir as NSString).appendingPathComponent(file)
                let sid = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: fullPath)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                let title = json["title"] as? String ?? "OpenCode Session"
                let cwd = json["directory"] as? String
                let projectName = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown"
                let attrs = (try? fileManager.attributesOfItem(atPath: fullPath)) ?? [:]
                let modDate = (attrs[.modificationDate] as? Date) ?? Date()
                let fileSize = (attrs[.size] as? Int64) ?? 0
                let parentID = json["parent_id"] as? String ?? json["parentId"] as? String
                let hasParent = parentID != nil && !parentID!.isEmpty
                let isSubagent = hasParent

                sessions.append(WorkspaceSession(
                    id: sid,
                    agent: .opencode,
                    title: title,
                    summary: nil,
                    projectDirectory: cwd,
                    projectName: projectName,
                    createdAt: modDate,
                    lastActiveAt: modDate,
                    filePath: fullPath,
                    fileSizeBytes: fileSize,
                    messageCount: 0,
                    resumeCommand: WorkspaceSessionCommandBuilder.resumeCommand(agent: .opencode, id: sid),
                    parentSessionID: hasParent ? parentID : nil,
                    isSubagent: isSubagent
                ))
            }
        }
        return sessions
    }

    private func scanOpenCodeSQLite(dbPath: String) -> [WorkspaceSession] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        // Support both modern schema (with parent_id) and legacy schema
        let queryWithParent = "SELECT id, title, directory, time_created, time_updated, parent_id FROM session ORDER BY time_updated DESC;"
        let queryWithoutParent = "SELECT id, title, directory, time_created, time_updated, NULL FROM session ORDER BY time_updated DESC;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, queryWithParent, -1, &stmt, nil) != SQLITE_OK {
            guard sqlite3_prepare_v2(db, queryWithoutParent, -1, &stmt, nil) == SQLITE_OK else { return [] }
        }
        defer { sqlite3_finalize(stmt) }

        var sessions: [WorkspaceSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let title = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? "OpenCode Session"
            let directory = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) }
            let createdAtSec = sqlite3_column_int64(stmt, 3)
            let updatedAtSec = sqlite3_column_int64(stmt, 4)
            let parentID = sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) }
            let hasParent = parentID != nil && !parentID!.isEmpty
            let isSubagent = hasParent

            let createdDate = createdAtSec > 0 ? Date(timeIntervalSince1970: TimeInterval(createdAtSec > 1_000_000_000_000 ? createdAtSec / 1000 : createdAtSec)) : Date()
            let updatedDate = updatedAtSec > 0 ? Date(timeIntervalSince1970: TimeInterval(updatedAtSec > 1_000_000_000_000 ? updatedAtSec / 1000 : updatedAtSec)) : createdDate
            let projectName = directory.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown"

            sessions.append(WorkspaceSession(
                id: id,
                agent: .opencode,
                title: title,
                summary: nil,
                projectDirectory: directory,
                projectName: projectName,
                createdAt: createdDate,
                lastActiveAt: updatedDate,
                filePath: "sqlite:\(dbPath):\(id)",
                fileSizeBytes: 0,
                messageCount: 0,
                resumeCommand: WorkspaceSessionCommandBuilder.resumeCommand(agent: .opencode, id: id),
                parentSessionID: hasParent ? parentID : nil,
                isSubagent: isSubagent
            ))
        }

        return sessions
    }

    @concurrent
    public func loadMessages(for session: WorkspaceSession) async throws -> [WorkspaceSessionMessage] {
        if session.filePath.hasPrefix("sqlite:") {
            return loadOpenCodeSQLiteMessages(source: session.filePath)
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: session.filePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messagesArr = json["messages"] as? [[String: Any]] else { return [] }

        return messagesArr.compactMap { msg -> WorkspaceSessionMessage? in
            guard let roleStr = msg["role"] as? String,
                  let content = msg["content"] as? String else { return nil }
            return WorkspaceSessionMessage(
                role: roleStr == "user" ? .user : .assistant,
                content: content
            )
        }
    }

    private func loadOpenCodeSQLiteMessages(source: String) -> [WorkspaceSessionMessage] {
        guard let locator = WorkspaceSessionPathPolicy.parseLocator(source) else { return [] }
        let expected = URL(fileURLWithPath: homeDir).appendingPathComponent(".local/share/opencode/opencode.db").path
        guard (try? WorkspaceSessionPathPolicy.validateLocator(source, expectedDatabase: expected, identifier: locator.id)) != nil else { return [] }
        let dbPath = locator.path
        let sessionID = locator.id

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        // Join message and part tables by message_id
        let query = """
        SELECT m.data, p.data
        FROM part p
        JOIN message m ON p.message_id = m.id
        WHERE p.session_id = ?
        ORDER BY p.time_created ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        _ = sessionID.withCString { sqlite3_bind_text(stmt, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }

        var messages: [WorkspaceSessionMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let mDataStr = sqlite3_column_text(stmt, 0).flatMap { String(cString: $0) } ?? ""
            let pDataStr = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""

            var role: WorkspaceMessageRole = .assistant
            if let mData = mDataStr.data(using: .utf8),
               let mJSON = try? JSONSerialization.jsonObject(with: mData) as? [String: Any],
               let r = mJSON["role"] as? String, r == "user" {
                role = .user
            }

            var contentText = ""
            if let pData = pDataStr.data(using: .utf8),
               let pJSON = try? JSONSerialization.jsonObject(with: pData) as? [String: Any],
               let text = pJSON["text"] as? String {
                contentText = text
            }

            if !contentText.isEmpty {
                messages.append(WorkspaceSessionMessage(role: role, content: contentText))
            }
        }

        return messages
    }

    @concurrent
    public func deleteSession(_ session: WorkspaceSession) async throws -> Bool {
        // 路径校验、完整级联计划和回滚策略由统一引擎负责，避免各客户端实现漂移。
        let databasePath = URL(fileURLWithPath: homeDir).appendingPathComponent(".local/share/opencode/opencode.db").path
        // 无数据库的旧客户端仍需按文件元数据追踪全部子孙，不能只删被点击的一条记录。
        let related = fileManager.fileExists(atPath: databasePath) ? [] : await scanSessions()
        return try WorkspaceSessionDeletionEngine.delete(session, expectedAgent: .opencode, homeDirectory: homeDir, relatedSessions: related)
    }
}

// MARK: - Pi Provider

public nonisolated struct PiSessionProvider: AgentSessionProviderProtocol {
    public let agent: WorkspaceAgent = .pi
    private let homeDir: String
    private var fileManager: FileManager { FileManager.default }

    public init(homeDir: String) {
        self.homeDir = homeDir
    }

    @concurrent
    public func scanSessions() async -> [WorkspaceSession] {
        let roots = [
            (homeDir as NSString).appendingPathComponent(".pi/agent/sessions"),
            (homeDir as NSString).appendingPathComponent(".pi/sessions")
        ]

        var sessions: [WorkspaceSession] = []
        for root in roots where fileManager.fileExists(atPath: root) {
            let enumerator = fileManager.enumerator(atPath: root)
            while let file = enumerator?.nextObject() as? String {
                guard file.hasSuffix(".jsonl") else { continue }
                let fullPath = (root as NSString).appendingPathComponent(file)
                if let meta = parsePiSessionMeta(filePath: fullPath) {
                    sessions.append(meta)
                }
            }
        }
        return sessions
    }

    private func parsePiSessionMeta(filePath: String) -> WorkspaceSession? {
        guard let (head, tail) = SessionIOUtils.readHeadAndTailLines(path: filePath, headCount: 15, tailCount: 20) else { return nil }
        let entries = head.compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        guard let header = entries.first(where: { $0["type"] as? String == "session" }),
              let identifier = header["id"] as? String else { return nil }
        let cwd = header["cwd"] as? String
        let createdAt = (header["timestamp"] as? String).flatMap(SessionIOUtils.parseDate)
        // parentId 属于会话内消息树；跨会话关系仅来自 header.parentSession，通常是父 JSONL 路径。
        let parentID = (header["parentSession"] as? String).flatMap { path -> String? in
            guard !path.isEmpty else { return nil }
            let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return SessionIOUtils.extractUUID(from: filename) ?? filename
        }
        let firstPrompt = entries.compactMap { entry -> String? in
            guard entry["type"] as? String == "message", let message = entry["message"] as? [String: Any], message["role"] as? String == "user" else { return nil }
            let text = piContentText(message["content"])
            return text.isEmpty ? nil : text
        }.first
        var customTitle: String?
        var lastDate: Date?
        for line in tail.reversed() {
            guard let data = line.data(using: .utf8), let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if lastDate == nil { lastDate = (entry["timestamp"] as? String).flatMap(SessionIOUtils.parseDate) }
            if customTitle == nil, entry["type"] as? String == "session_info" { customTitle = entry["name"] as? String }
        }
        let attributes = (try? fileManager.attributesOfItem(atPath: filePath)) ?? [:]
        return WorkspaceSession(
            id: identifier, agent: .pi,
            title: customTitle ?? firstPrompt ?? "Pi Session (\(identifier.prefix(8)))",
            summary: firstPrompt, projectDirectory: cwd,
            projectName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown",
            createdAt: createdAt, lastActiveAt: lastDate ?? (attributes[.modificationDate] as? Date) ?? createdAt ?? Date(),
            filePath: filePath, fileSizeBytes: attributes[.size] as? Int64 ?? 0, messageCount: 0,
            resumeCommand: WorkspaceSessionCommandBuilder.resumeCommand(agent: .pi, id: identifier),
            parentSessionID: parentID, isSubagent: parentID != nil
        )
    }

    private func piContentText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block in
            if block["type"] as? String == "text" { return block["text"] as? String }
            if block["type"] as? String == "thinking" { return block["thinking"] as? String }
            return nil
        }.joined(separator: "\n")
    }

    @concurrent
    public func loadMessages(for session: WorkspaceSession) async throws -> [WorkspaceSessionMessage] {
        try WorkspaceSessionPathPolicy(homeDirectory: homeDir, agent: .pi).validate(session.filePath)
        let content = try String(contentsOfFile: session.filePath, encoding: .utf8)
        return content.components(separatedBy: .newlines).compactMap { line in
            guard let data = line.data(using: .utf8), let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  entry["type"] as? String == "message", let message = entry["message"] as? [String: Any] else { return nil }
            let text = piContentText(message["content"])
            guard !text.isEmpty else { return nil }
            let role: WorkspaceMessageRole
            switch message["role"] as? String {
            case "user": role = .user
            case "toolResult", "bashExecution": role = .tool
            case "system": role = .system
            default: role = .assistant
            }
            let timestamp = (entry["timestamp"] as? String).flatMap(SessionIOUtils.parseDate)
            return WorkspaceSessionMessage(id: entry["id"] as? String ?? UUID().uuidString, role: role, content: text, timestamp: timestamp)
        }
    }

    @concurrent
    public func deleteSession(_ session: WorkspaceSession) async throws -> Bool {
        // 路径校验、完整级联计划和回滚策略由统一引擎负责，避免各客户端实现漂移。
        let related = await scanSessions()
        return try WorkspaceSessionDeletionEngine.delete(session, expectedAgent: .pi, homeDirectory: homeDir, relatedSessions: related)
    }
}

// MARK: - AGY (Antigravity) Provider

public nonisolated struct AGYSessionProvider: AgentSessionProviderProtocol {
    public let agent: WorkspaceAgent = .agy
    private let homeDir: String
    private var fileManager: FileManager { FileManager.default }

    public init(homeDir: String) {
        self.homeDir = homeDir
    }

    @concurrent
    public func scanSessions() async -> [WorkspaceSession] {
        var accumulated = WorkspaceSessionAccumulator()
        let base = URL(fileURLWithPath: homeDir).appendingPathComponent(".gemini/antigravity-cli")
        let dbPath = base.appendingPathComponent("conversation_summaries.db").path
        // 摘要库和旧 JSON 提供结构化身份与项目，优先于不含会话关系的 brain 正文。
        if fileManager.fileExists(atPath: dbPath) {
            scanAGYSQLite(dbPath: dbPath).forEach { accumulated.append($0) }
        }
        let convsDir = base.appendingPathComponent("conversations")
        let files = ((try? fileManager.contentsOfDirectory(atPath: convsDir.path)) ?? []).sorted()
        for file in files where file.hasSuffix(".json") {
            let id = (file as NSString).deletingPathExtension
            if let session = parseAGYConversationJSON(filePath: convsDir.appendingPathComponent(file).path, id: id) {
                accumulated.append(session)
            }
        }

        let cache = readAGYMetadataCache(base: base)
        let brainDir = base.appendingPathComponent("brain")
        let brainIDs = (try? fileManager.contentsOfDirectory(atPath: brainDir.path)) ?? []
        let databaseIDs = files.filter { $0.hasSuffix(".db") }.map { ($0 as NSString).deletingPathExtension }
        // 缓存只能补充仍有实体文件的会话，不能让已删除会话仅凭陈旧缓存重新出现。
        for id in Set(brainIDs + databaseIDs).sorted() {
            guard !accumulated.contains(id: id, agent: .agy) else { continue }
            let log = agyTranscriptPath(id: id)
            let database = convsDir.appendingPathComponent("\(id).db").path
            guard let path = log ?? (fileManager.fileExists(atPath: database) ? database : nil) else { continue }
            if let summary = cache[id]?["summary"] as? [String: Any] {
                accumulated.append(parseAGYConversationMetadata(summary, filePath: path, id: id))
            } else if let log, let session = parseAGYBrainTranscript(filePath: log, id: id) {
                accumulated.append(session)
            } else if let session = parseAGYConversationDB(filePath: database, id: id) {
                accumulated.append(session)
            }
        }

        let tmpDir = (homeDir as NSString).appendingPathComponent(".gemini/tmp")
        if fileManager.fileExists(atPath: tmpDir) {
            scanLegacyGeminiTmp(tmpDir: tmpDir).forEach { accumulated.append($0) }
        }
        // is_internal 的官方实现含 /btw 和 battle fork，不能直接转换成 isSubagent。
        for (id, metadata) in cache {
            accumulated.mergeRelationship(WorkspaceSessionRelationshipAdapter.agy(metadata: metadata, hasSummary: false), id: id, agent: .agy)
        }
        return accumulated.sessions
    }

    private func readAGYMetadataCache(base: URL) -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: base.appendingPathComponent("cache/conversation_metadata.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json["conversations"] as? [String: [String: Any]] ?? [:]
    }

    /// 正文来源选择与会话分类分离；优先完整日志，不能让有日志就等价于主会话。
    private func agyTranscriptPath(id: String) -> String? {
        let logs = URL(fileURLWithPath: homeDir).appendingPathComponent(".gemini/antigravity-cli/brain/\(id)/.system_generated/logs")
        return ["transcript_full.jsonl", "transcript.jsonl"].map { logs.appendingPathComponent($0).path }
            .first { fileManager.fileExists(atPath: $0) }
    }

    private func scanAGYSQLite(dbPath: String) -> [WorkspaceSession] {
        var db: OpaquePointer?
        // Antigravity CLI 使用 SQLite WAL 模式，优先以 READWRITE 打开以安全完成 WAL 索引恢复
        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
            sqlite3_close(db)
            guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(db)
                return []
            }
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        let columns = SessionIOUtils.columns(in: "conversation_summaries", database: db)
        func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
        let query = """
        SELECT conversation_id, title, preview, step_count, last_modified_time, workspace_uris,
               \(column("parent_conversation_id")), \(column("nesting_depth")), \(column("agent_name"))
        FROM conversation_summaries
        ORDER BY last_modified_time DESC
        ;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var sessions: [WorkspaceSession] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cidPtr = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: cidPtr)
            let rawTitle = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""
            let preview = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? ""
            let stepCount = Int(sqlite3_column_int(stmt, 3))
            let timeStr = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) } ?? ""
            let urisStr = sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) } ?? ""
            let parentCID = sqlite3_column_text(stmt, 6).flatMap { String(cString: $0) }
            let depth = Int(sqlite3_column_int(stmt, 7))
            let agentName = sqlite3_column_text(stmt, 8).flatMap { String(cString: $0) }
            let relationship = WorkspaceSessionRelationshipAdapter.agy(metadata: [
                "parent_conversation_id": parentCID ?? "", "nesting_depth": depth
            ], hasSummary: true)

            let baseTitle = !rawTitle.isEmpty ? rawTitle : (!preview.isEmpty ? preview : "AGY Session (\(id.prefix(8)))")
            var finalTitle = baseTitle
            if relationship.isSubagent {
                if let name = agentName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    finalTitle = "[\(name)] \(baseTitle)"
                } else {
                    finalTitle = "子任务: \(baseTitle)"
                }
            }

            var projectDir: String? = nil
            var projectName = "Workspace"

            if let urisData = urisStr.data(using: .utf8),
               let uriArray = try? JSONSerialization.jsonObject(with: urisData) as? [String],
               let firstURI = uriArray.first {
                if firstURI.hasPrefix("file://") {
                    let cleaned = URL(string: firstURI)?.path ?? String(firstURI.dropFirst(7))
                    projectDir = cleaned
                    projectName = URL(fileURLWithPath: cleaned).lastPathComponent
                } else {
                    projectDir = firstURI
                    projectName = URL(fileURLWithPath: firstURI).lastPathComponent
                }
            }

            let modDate = SessionIOUtils.parseDate(timeStr) ?? Date()

            let brainLogs = (homeDir as NSString).appendingPathComponent(".gemini/antigravity-cli/brain/\(id)/.system_generated/logs")
            let brainTranscriptFull = (brainLogs as NSString).appendingPathComponent("transcript_full.jsonl")
            let brainTranscript = (brainLogs as NSString).appendingPathComponent("transcript.jsonl")
            let convDb = (homeDir as NSString).appendingPathComponent(".gemini/antigravity-cli/conversations/\(id).db")
            let convJson = (homeDir as NSString).appendingPathComponent(".gemini/antigravity-cli/conversations/\(id).json")

            let filePath: String
            if fileManager.fileExists(atPath: brainTranscriptFull) {
                filePath = brainTranscriptFull
            } else if fileManager.fileExists(atPath: brainTranscript) {
                filePath = brainTranscript
            } else if fileManager.fileExists(atPath: convDb) {
                filePath = convDb
            } else if fileManager.fileExists(atPath: convJson) {
                filePath = convJson
            } else {
                filePath = "sqlite:\(dbPath):\(id)"
            }

            sessions.append(WorkspaceSession(
                id: id,
                agent: .agy,
                title: finalTitle,
                summary: preview.isEmpty ? nil : preview,
                projectDirectory: projectDir,
                projectName: projectName,
                createdAt: modDate,
                lastActiveAt: modDate,
                filePath: filePath,
                fileSizeBytes: 0,
                messageCount: stepCount > 0 ? stepCount : 0,
                resumeCommand: WorkspaceSessionCommandBuilder.resumeCommand(agent: .agy, id: id),
                relationship: relationship
            ))
        }

        return sessions
    }

    private func parseAGYConversationDB(filePath: String, id: String) -> WorkspaceSession? {
        guard fileManager.fileExists(atPath: filePath) else { return nil }
        let attrs = (try? fileManager.attributesOfItem(atPath: filePath)) ?? [:]
        let modDate = (attrs[.modificationDate] as? Date) ?? Date()
        let fileSize = (attrs[.size] as? Int64) ?? 0

        let brainLogs = (homeDir as NSString).appendingPathComponent(".gemini/antigravity-cli/brain/\(id)/.system_generated/logs")
        let fullLog = (brainLogs as NSString).appendingPathComponent("transcript_full.jsonl")
        let regularLog = (brainLogs as NSString).appendingPathComponent("transcript.jsonl")
        let targetPath = fileManager.fileExists(atPath: fullLog) ? fullLog : (fileManager.fileExists(atPath: regularLog) ? regularLog : filePath)

        return WorkspaceSession(
            id: id,
            agent: .agy,
            title: "AGY Session (\(id.prefix(8)))",
            summary: nil,
            projectDirectory: nil,
            projectName: "Workspace",
            createdAt: modDate,
            lastActiveAt: modDate,
            filePath: targetPath,
            fileSizeBytes: fileSize,
            messageCount: 0,
            resumeCommand: WorkspaceSessionCommandBuilder.resumeCommand(agent: .agy, id: id),
            relationship: .init(kind: .unknown)
        )
    }

    private func parseAGYBrainTranscript(filePath: String, id: String) -> WorkspaceSession? {
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8192), !data.isEmpty,
              let chunk = String(data: data, encoding: .utf8) else { return nil }

        var title: String?
        var date: Date?
        var projectDir: String?

        for line in chunk.components(separatedBy: .newlines) {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if date == nil, let ts = json["created_at"] as? String {
                date = SessionIOUtils.parseDate(ts)
            }

            let type = json["type"] as? String ?? ""
            if type == "USER_INPUT" && title == nil {
                let content = (json["content"] as? String ?? "")
                    .replacingOccurrences(of: "<USER_REQUEST>", with: "")
                    .replacingOccurrences(of: "</USER_REQUEST>", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    let firstLine = content.components(separatedBy: .newlines).first ?? ""
                    title = String(firstLine.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            if projectDir == nil, let content = json["content"] as? String {
                if let range = content.range(of: "file:///") {
                    let sub = content[range.lowerBound...]
                    if let end = sub.firstIndex(of: "\"") ?? sub.firstIndex(of: "\n") ?? sub.firstIndex(of: " ") {
                        let uriStr = String(sub[..<end])
                        if let url = URL(string: uriStr) {
                            projectDir = url.path
                        }
                    }
                }
            }
        }

        let attrs = (try? fileManager.attributesOfItem(atPath: filePath)) ?? [:]
        let modDate = date ?? (attrs[.modificationDate] as? Date) ?? Date()
        let fileSize = (attrs[.size] as? Int64) ?? 0
        let projectName = projectDir.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "Workspace"

        return WorkspaceSession(
            id: id,
            agent: .agy,
            title: title ?? "AGY Session (\(id.prefix(8)))",
            summary: nil,
            projectDirectory: projectDir,
            projectName: projectName,
            createdAt: modDate,
            lastActiveAt: modDate,
            filePath: filePath,
            fileSizeBytes: fileSize,
            messageCount: 0,
            resumeCommand: WorkspaceSessionCommandBuilder.resumeCommand(agent: .agy, id: id),
            relationship: .init(kind: .unknown)
        )
    }

    private func parseAGYConversationJSON(filePath: String, id: String) -> WorkspaceSession? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        return parseAGYConversationMetadata(json, filePath: filePath, id: id)
    }

    /// 旧 JSON 与 1.2.x 缓存 summary 的字段命名不同，集中做展示字段适配，避免从正文提取项目路径。
    private func parseAGYConversationMetadata(_ json: [String: Any], filePath: String, id: String) -> WorkspaceSession {
        let title = json["title"] as? String ?? json["Title"] as? String ?? json["name"] as? String ?? "AGY Session (\(id.prefix(8)))"
        let uri = (json["WorkspaceURIs"] as? [String])?.first
        let projectDir = json["project_dir"] as? String ?? json["cwd"] as? String
            ?? uri.map { $0.hasPrefix("file://") ? URL(string: $0)?.path ?? $0 : $0 }
        let projectName = projectDir.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "Workspace"

        let attrs = (try? fileManager.attributesOfItem(atPath: filePath)) ?? [:]
        let modDate = (json["UpdatedAt"] as? String).flatMap(SessionIOUtils.parseDate) ?? (attrs[.modificationDate] as? Date) ?? Date()
        let fileSize = (attrs[.size] as? Int64) ?? 0

        return WorkspaceSession(
            id: id,
            agent: .agy,
            title: title,
            summary: nil,
            projectDirectory: projectDir,
            projectName: projectName,
            createdAt: modDate,
            lastActiveAt: modDate,
            filePath: agyTranscriptPath(id: id) ?? filePath,
            fileSizeBytes: fileSize,
            messageCount: 0,
            resumeCommand: WorkspaceSessionCommandBuilder.resumeCommand(agent: .agy, id: id),
            // 合法 JSON 不等于已识别的摘要；空字典或未来格式保留 unknown，等待明确身份元数据。
            relationship: WorkspaceSessionRelationshipAdapter.agy(metadata: json,
                hasSummary: json["title"] is String || json["Title"] is String || json["name"] is String)
        )
    }

    private func scanLegacyGeminiTmp(tmpDir: String) -> [WorkspaceSession] {
        guard let items = try? fileManager.contentsOfDirectory(atPath: tmpDir) else { return [] }
        var sessions: [WorkspaceSession] = []

        for item in items {
            let itemPath = (tmpDir as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: itemPath, isDirectory: &isDir), isDir.boolValue else { continue }

            let transcriptPath = (itemPath as NSString).appendingPathComponent("transcript.jsonl")
            guard fileManager.fileExists(atPath: transcriptPath) else { continue }

            let attrs = (try? fileManager.attributesOfItem(atPath: transcriptPath)) ?? [:]
            let modDate = (attrs[.modificationDate] as? Date) ?? Date()
            let fileSize = (attrs[.size] as? Int64) ?? 0

            sessions.append(WorkspaceSession(
                id: item,
                agent: .agy,
                title: "Legacy Session (\(item.prefix(8)))",
                summary: nil,
                projectDirectory: nil,
                projectName: "Legacy",
                createdAt: modDate,
                lastActiveAt: modDate,
                filePath: transcriptPath,
                fileSizeBytes: fileSize,
                messageCount: 0,
                resumeCommand: WorkspaceSessionCommandBuilder.resumeCommand(agent: .agy, id: item)
            ))
        }

        return sessions
    }

    @concurrent
    public func loadMessages(for session: WorkspaceSession) async throws -> [WorkspaceSessionMessage] {
        let brainLogs = (homeDir as NSString).appendingPathComponent(".gemini/antigravity-cli/brain/\(session.id)/.system_generated/logs")
        let fullPath = (brainLogs as NSString).appendingPathComponent("transcript_full.jsonl")
        let regularPath = (brainLogs as NSString).appendingPathComponent("transcript.jsonl")

        let transcriptPath: String
        if session.filePath.hasSuffix(".jsonl") && fileManager.fileExists(atPath: session.filePath) {
            transcriptPath = session.filePath
        } else if fileManager.fileExists(atPath: fullPath) {
            transcriptPath = fullPath
        } else if fileManager.fileExists(atPath: regularPath) {
            transcriptPath = regularPath
        } else {
            transcriptPath = regularPath
        }

        guard fileManager.fileExists(atPath: transcriptPath),
              let content = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else { return [] }

        var messages: [WorkspaceSessionMessage] = []
        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let type = json["type"] as? String ?? ""
            let contentStr = json["content"] as? String ?? ""
            let ts = (json["created_at"] as? String).flatMap { SessionIOUtils.parseDate($0) }

            if type == "USER_INPUT" && !contentStr.isEmpty {
                let clean = contentStr.replacingOccurrences(of: "<USER_REQUEST>", with: "")
                    .replacingOccurrences(of: "</USER_REQUEST>", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                messages.append(WorkspaceSessionMessage(role: .user, content: clean, timestamp: ts))
            } else if type == "PLANNER_RESPONSE" && !contentStr.isEmpty {
                messages.append(WorkspaceSessionMessage(role: .assistant, content: contentStr, timestamp: ts))
            }
        }
        return messages
    }


    @concurrent
    public func deleteSession(_ session: WorkspaceSession) async throws -> Bool {
        // 路径校验、完整级联计划和回滚策略由统一引擎负责，避免各客户端实现漂移。
        let related = await scanSessions()
        return try WorkspaceSessionDeletionEngine.delete(session, expectedAgent: .agy, homeDirectory: homeDir, relatedSessions: related)
    }
}
