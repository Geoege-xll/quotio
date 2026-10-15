//
//  AGYSessionProvider.swift
//  Quotio
//

import Foundation
import SQLite3

/// 原 Antigravity（AGY）会话 Provider，数据库、JSON、brain 与旧缓存适配按完整类型归位。
/// 保留摘要到实体来源的原合并顺序、WAL 兼容、transcript 选择优先级与私有 homeDir。
/// 原 @concurrent、删除前重扫和统一引擎事务顺序完整保留，不建立缓存或额外任务。
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

