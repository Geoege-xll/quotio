//
//  OpenCodeSessionProvider.swift
//  Quotio
//

import Foundation
import SQLite3

/// 原 OpenCode 会话 Provider，数据库、旧 JSON、消息加载与私有 homeDir 按完整类型迁移。
/// 保留数据库优先及旧目录回退、父子关系和原消息顺序，不创建新的 SQLite 连接管理宿主。
/// 删除仍复用原引擎与必要的文件关系重扫，保留 nonisolated／@concurrent 与错误语义。
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

