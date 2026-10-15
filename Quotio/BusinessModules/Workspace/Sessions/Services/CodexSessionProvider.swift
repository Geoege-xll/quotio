//
//  CodexSessionProvider.swift
//  Quotio
//

import Foundation
import SQLite3

/// 原 Codex 会话 Provider，保留完整私有解析与数据库读取方法及原 nonisolated／@concurrent 边界。
/// 扫描仍优先采用当前数据库，随后从 rollout 和索引补齐关系与正文位置，不改变来源识别或去重。
/// 删除继续先重扫关系再调用原统一事务引擎，原文件／数据库校验、级联与回滚顺序不变。
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

