//
//  WorkspaceSessionService.swift
//  Quotio - Unified Agent Session Management Service
//  Encapsulated Provider Architecture for Claude, Codex, OpenCode, Pi, and Antigravity (AGY)
//

import Foundation
import SQLite3
import AppKit

// MARK: - Provider Protocol

public protocol AgentSessionProviderProtocol: Sendable {
    var agent: WorkspaceAgent { get }
    func scanSessions() async -> [WorkspaceSession]
    func loadMessages(for session: WorkspaceSession) async throws -> [WorkspaceSessionMessage]
    func deleteSession(_ session: WorkspaceSession) async throws -> Bool
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
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

    public func scanSessions() async -> [WorkspaceSession] {
        let projectsDir = (homeDir as NSString).appendingPathComponent(".claude/projects")
        guard fileManager.fileExists(atPath: projectsDir) else { return [] }

        var sessions: [WorkspaceSession] = []
        let enumerator = fileManager.enumerator(atPath: projectsDir)

        while let file = enumerator?.nextObject() as? String {
            guard file.hasSuffix(".jsonl") else { continue }
            let fullPath = (projectsDir as NSString).appendingPathComponent(file)

            if file.contains("/subagents/") {
                if let subMeta = parseClaudeSubagentMeta(filePath: fullPath, relativePath: file) {
                    sessions.append(subMeta)
                }
            } else {
                if let meta = parseClaudeSessionMeta(filePath: fullPath) {
                    sessions.append(meta)
                }
            }
        }

        return sessions
    }

    private func parseClaudeSubagentMeta(filePath: String, relativePath: String) -> WorkspaceSession? {
        let parts = relativePath.components(separatedBy: "/subagents/")
        guard parts.count >= 2 else { return nil }

        let parentDir = parts[0]
        let parentUUID = SessionIOUtils.extractUUID(from: parentDir) ?? URL(fileURLWithPath: parentDir).lastPathComponent
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
            parentSessionID: parentUUID,
            isSubagent: true
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

        for line in head {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if sessionID == nil, let sid = json["sessionId"] as? String {
                sessionID = sid
            }
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

            if sessionID != nil && cwd != nil && createdAt != nil && firstUserPrompt != nil {
                break
            }
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

        let sid = sessionID ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
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
            resumeCommand: WorkspaceSessionCommandBuilder.resumeCommand(agent: .claude, id: sid)
        )
    }

    private func extractUserPrompt(from content: Any?) -> String? {
        if let str = content as? String { return str }
        if let array = content as? [[String: Any]] {
            return array.compactMap { $0["text"] as? String }.first
        }
        return nil
    }

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

        var sessions = databaseSessions
        var seenIDs = Set(databaseSessions.map(\.id))
        let knownPaths = Set(databaseSessions.map(\.filePath))

        for root in [sessionsDir, archivedDir] where fileManager.fileExists(atPath: root) {
            let enumerator = fileManager.enumerator(atPath: root)
            while let file = enumerator?.nextObject() as? String {
                guard file.hasSuffix(".jsonl") else { continue }
                let fullPath = (root as NSString).appendingPathComponent(file)
                if knownPaths.contains(fullPath) { continue }
                if let meta = parseCodexSessionMeta(filePath: fullPath, titles: titles) {
                    guard !seenIDs.contains(meta.id) else { continue }
                    seenIDs.insert(meta.id)
                    sessions.append(meta)
                }
            }
        }
        return sessions
    }

    private func scanCodexSQLite(dbPath: String) -> [WorkspaceSession] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        let query = """
        SELECT
            t.id,
            t.title,
            t.first_user_message,
            t.cwd,
            t.rollout_path,
            t.created_at,
            t.updated_at,
            e.parent_thread_id,
            t.source,
            t.agent_nickname,
            t.agent_role
        FROM threads t
        LEFT JOIN thread_spawn_edges e ON t.id = e.child_thread_id
        ORDER BY t.updated_at DESC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var sessions: [WorkspaceSession] = []
        var seenIDs = Set<String>()

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            guard !seenIDs.contains(id) else { continue }
            seenIDs.insert(id)

            let rawTitle = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) }
            let firstUserMsg = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) }
            let cwd = sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) }
            let rolloutPath = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) } ?? ""
            let createdAtSec = sqlite3_column_int64(stmt, 5)
            let updatedAtSec = sqlite3_column_int64(stmt, 6)
            var parentThreadID = sqlite3_column_text(stmt, 7).flatMap { String(cString: $0) }
            let source = sqlite3_column_text(stmt, 8).flatMap { String(cString: $0) }
            let agentNickname = sqlite3_column_text(stmt, 9).flatMap { String(cString: $0) }
            let agentRole = sqlite3_column_text(stmt, 10).flatMap { String(cString: $0) }

            if (parentThreadID == nil || parentThreadID!.isEmpty), let src = source, src.contains("parent_thread_id") {
                if let range = src.range(of: "\"parent_thread_id\"\\s*:\\s*\"([^\"]+)\"", options: .regularExpression) {
                    let match = String(src[range])
                    if let uuid = SessionIOUtils.extractUUID(from: match) {
                        parentThreadID = uuid
                    }
                }
            }

            let isSubagent = parentThreadID != nil || (source?.contains("subagent") == true) || (agentNickname != nil && !agentNickname!.isEmpty)
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
                parentSessionID: parentThreadID,
                isSubagent: isSubagent
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
        var metadataParentID: String?

        for line in head {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let itemType = json["type"] as? String
            let payload = json["payload"] as? [String: Any]
            if itemType == "session_meta", let source = payload?["source"] {
                if let text = source as? String {
                    metadataParentID = WorkspaceSessionDeletionEngine.parentThreadID(in: text)
                } else if JSONSerialization.isValidJSONObject(source), let data = try? JSONSerialization.data(withJSONObject: source), let text = String(data: data, encoding: .utf8) {
                    metadataParentID = WorkspaceSessionDeletionEngine.parentThreadID(in: text)
                }
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
        var parentID: String? = metadataParentID
        let parts = filename.components(separatedBy: "_")
        let sid: String
        if parts.count > 1, let childUUID = SessionIOUtils.extractUUID(from: parts[1]) {
            sid = childUUID
            parentID = parentID ?? SessionIOUtils.extractUUID(from: parts[0])
        } else if let id = sessionID, !id.isEmpty {
            sid = id
        } else if let uuidMatch = SessionIOUtils.extractUUID(from: filename) {
            sid = uuidMatch
        } else {
            sid = filename
        }

        let isSubagent = parentID != nil || parts.count > 1
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
            parentSessionID: parentID,
            isSubagent: isSubagent
        )
    }

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

    public func deleteSession(_ session: WorkspaceSession) async throws -> Bool {
        let databasePath = URL(fileURLWithPath: homeDir).appendingPathComponent(".codex/state_5.sqlite").path
        // 无数据库的旧客户端仍需按文件元数据追踪全部子孙，不能只删被点击的一条记录。
        let related = fileManager.fileExists(atPath: databasePath) ? [] : await scanSessions()
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

    public func scanSessions() async -> [WorkspaceSession] {
        var sessions: [WorkspaceSession] = []

        // 1. Primary: SQLite database
        let dbPath = (homeDir as NSString).appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db")
        if fileManager.fileExists(atPath: dbPath) {
            sessions.append(contentsOf: scanAGYSQLite(dbPath: dbPath))
        }

        // 2. Secondary: ~/.gemini/antigravity-cli/conversations/*.json
        let convsDir = (homeDir as NSString).appendingPathComponent(".gemini/antigravity-cli/conversations")
        if fileManager.fileExists(atPath: convsDir) {
            let existingIds = Set(sessions.map { $0.id })
            if let files = try? fileManager.contentsOfDirectory(atPath: convsDir) {
                for file in files where file.hasSuffix(".json") {
                    let sid = (file as NSString).deletingPathExtension
                    if !existingIds.contains(sid) {
                        let fullPath = (convsDir as NSString).appendingPathComponent(file)
                        if let meta = parseAGYConversationJSON(filePath: fullPath, id: sid) {
                            sessions.append(meta)
                        }
                    }
                }
            }
        }

        // 3. Fallback: Legacy ~/.gemini/tmp
        let tmpDir = (homeDir as NSString).appendingPathComponent(".gemini/tmp")
        if fileManager.fileExists(atPath: tmpDir) {
            let existingIds = Set(sessions.map { $0.id })
            let legacy = scanLegacyGeminiTmp(tmpDir: tmpDir)
            for leg in legacy where !existingIds.contains(leg.id) {
                sessions.append(leg)
            }
        }

        return sessions
    }

    private func scanAGYSQLite(dbPath: String) -> [WorkspaceSession] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        let query = """
        SELECT conversation_id, title, preview, step_count, last_modified_time, workspace_uris,
               parent_conversation_id, nesting_depth, agent_name
        FROM conversation_summaries
        ORDER BY last_modified_time DESC
        ;
        """
        let queryLegacy = """
        SELECT conversation_id, title, preview, step_count, last_modified_time, workspace_uris,
               NULL, 0, NULL
        FROM conversation_summaries
        ORDER BY last_modified_time DESC
        ;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) != SQLITE_OK {
            guard sqlite3_prepare_v2(db, queryLegacy, -1, &stmt, nil) == SQLITE_OK else { return [] }
        }
        defer { sqlite3_finalize(stmt) }

        var sessions: [WorkspaceSession] = []
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

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
            let hasParent = (parentCID != nil && !parentCID!.isEmpty)
            let isSubagent = hasParent || depth > 0

            let baseTitle = !rawTitle.isEmpty ? rawTitle : (!preview.isEmpty ? preview : "AGY Session (\(id.prefix(8)))")
            var finalTitle = baseTitle
            if isSubagent {
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

            let modDate = isoFormatter.date(from: timeStr) ?? SessionIOUtils.parseDate(timeStr) ?? Date()

            let brainTranscript = (homeDir as NSString).appendingPathComponent(".gemini/antigravity-cli/brain/\(id)/.system_generated/logs/transcript.jsonl")
            let convJson = (homeDir as NSString).appendingPathComponent(".gemini/antigravity-cli/conversations/\(id).json")
            let filePath = fileManager.fileExists(atPath: brainTranscript) ? brainTranscript : (fileManager.fileExists(atPath: convJson) ? convJson : "sqlite:\(dbPath):\(id)")

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
                parentSessionID: hasParent ? parentCID : nil,
                isSubagent: isSubagent
            ))
        }

        return sessions
    }

    private func parseAGYConversationJSON(filePath: String, id: String) -> WorkspaceSession? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let title = json["title"] as? String ?? json["name"] as? String ?? "AGY Session (\(id.prefix(8)))"
        let projectDir = json["project_dir"] as? String ?? json["cwd"] as? String
        let projectName = projectDir.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "Workspace"
        let parentCID = json["parent_conversation_id"] as? String ?? json["parent_id"] as? String
        let depth = json["nesting_depth"] as? Int ?? 0
        let hasParent = parentCID != nil && !parentCID!.isEmpty
        let isSubagent = hasParent || depth > 0

        let attrs = (try? fileManager.attributesOfItem(atPath: filePath)) ?? [:]
        let modDate = (attrs[.modificationDate] as? Date) ?? Date()
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
            filePath: filePath,
            fileSizeBytes: fileSize,
            messageCount: 0,
            resumeCommand: WorkspaceSessionCommandBuilder.resumeCommand(agent: .agy, id: id),
            parentSessionID: hasParent ? parentCID : nil,
            isSubagent: isSubagent
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

    public func loadMessages(for session: WorkspaceSession) async throws -> [WorkspaceSessionMessage] {
        let transcriptPath: String
        if session.filePath.hasSuffix("transcript.jsonl") && fileManager.fileExists(atPath: session.filePath) {
            transcriptPath = session.filePath
        } else {
            transcriptPath = (homeDir as NSString).appendingPathComponent(".gemini/antigravity-cli/brain/\(session.id)/.system_generated/logs/transcript.jsonl")
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

    public func deleteSession(_ session: WorkspaceSession) async throws -> Bool {
        // 路径校验、完整级联计划和回滚策略由统一引擎负责，避免各客户端实现漂移。
        let databasePath = URL(fileURLWithPath: homeDir).appendingPathComponent(".gemini/antigravity-cli/conversation_summaries.db").path
        // 无数据库的旧客户端仍需按文件元数据追踪全部子孙，不能只删被点击的一条记录。
        let related = fileManager.fileExists(atPath: databasePath) ? [] : await scanSessions()
        return try WorkspaceSessionDeletionEngine.delete(session, expectedAgent: .agy, homeDirectory: homeDir, relatedSessions: related)
    }
}
