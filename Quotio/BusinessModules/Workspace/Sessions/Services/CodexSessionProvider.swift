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

    /// Codex 官方交互端与标准 CLI 入口 originator 集合。
    /// 当 thread_source 不为 "user" 且 originator 为其他自定义进程标识（如子代理或自动化验收通过 app-server 拉起的非交互探针）时，
    /// 不作为用户主会话展示在左侧列表中，但保留在底层集合供删除与空间统计使用。
    private static let standardInteractiveOriginators: Set<String> = [
        "Codex Desktop",
        "codex-tui",
        "codex_exec",
        "codex_cli_rs",
        "codex_vscode"
    ]

    @concurrent
    public func scanSessions() async -> [WorkspaceSession] {
        let codexDir = (homeDir as NSString).appendingPathComponent(".codex")
        let state5Path = (codexDir as NSString).appendingPathComponent("state_5.sqlite")
        let sessionsDir = (codexDir as NSString).appendingPathComponent("sessions")
        let archivedDir = (codexDir as NSString).appendingPathComponent("archived_sessions")
        let indexPath = (codexDir as NSString).appendingPathComponent("session_index.jsonl")

        var titles: [String: String] = [:]
        if let indexContent = try? String(contentsOfFile: indexPath, encoding: .utf8) {
            for line in indexContent.components(separatedBy: .newlines) {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = json["id"] as? String,
                      let title = json["thread_name"] as? String,
                      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                titles[id] = title
            }
        }

        let fileImportedIDs = loadExternalImportedThreadIDsFromFile(codexDir: codexDir)

        // 已归档与不可浏览记录也用于存储管理与级联删除；文件扫描只补充数据库尚未登记的会话。
        let databaseSessions = fileManager.fileExists(atPath: state5Path)
            ? scanCodexSQLite(dbPath: state5Path, indexTitles: titles, fileImportedIDs: fileImportedIDs)
            : []

        var accumulated = WorkspaceSessionAccumulator()
        databaseSessions.forEach { accumulated.append($0) }
        let knownPaths = Dictionary(databaseSessions.map { ($0.filePath, $0.id) }, uniquingKeysWith: { first, _ in first })

        for root in [sessionsDir, archivedDir] where fileManager.fileExists(atPath: root) {
            let isArchivedRoot = root == archivedDir
            let enumerator = fileManager.enumerator(atPath: root)
            while let file = enumerator?.nextObject() as? String {
                guard file.hasSuffix(".jsonl") else { continue }
                let fullPath = (root as NSString).appendingPathComponent(file)
                if let id = knownPaths[fullPath] {
                    // SQLite 的展示字段优先，但不能覆盖 rollout 中更完整的关系证据。
                    accumulated.mergeRelationship(readCodexRelationship(filePath: fullPath, expectedID: id), id: id, agent: .codex)
                    continue
                }
                if let meta = parseCodexSessionMeta(
                    filePath: fullPath,
                    titles: titles,
                    isArchived: isArchivedRoot,
                    importedIDs: fileImportedIDs
                ) {
                    accumulated.append(meta)
                }
            }
        }
        return accumulated.sessions
    }

    /// 读取 ~/.codex/external_agent_session_imports.json 中登记的跨客户端导入会话 ID。
    /// Codex Desktop 会将 Claude Code 等外部客户端的历史会话导入至本地 SQLite，这些记录不应在 Codex 主会话列表中重复冒充原生会话。
    private func loadExternalImportedThreadIDsFromFile(codexDir: String) -> Set<String> {
        let importsPath = (codexDir as NSString).appendingPathComponent("external_agent_session_imports.json")
        guard fileManager.fileExists(atPath: importsPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: importsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = json["records"] as? [[String: Any]] else {
            return []
        }
        var ids = Set<String>()
        for record in records {
            if let id = record["imported_thread_id"] as? String, !id.isEmpty {
                ids.insert(id)
            }
        }
        return ids
    }

    /// 从 state_5.sqlite 的 external_agent_config_imports 表提取已导入的外部会话 ID。
    private func loadExternalImportedThreadIDsFromDatabase(_ db: OpaquePointer?) -> Set<String> {
        let importColumns = SessionIOUtils.columns(in: "external_agent_config_imports", database: db)
        guard importColumns.contains("successes") else { return [] }
        let query = "SELECT successes FROM external_agent_config_imports;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var ids = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let textPtr = sqlite3_column_text(stmt, 0) else { continue }
            let text = String(cString: textPtr)
            guard let data = text.data(using: .utf8),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            for item in items {
                let itemType = (item["item_type"] as? String)?.uppercased()
                if (itemType == nil || itemType == "SESSIONS"),
                   let target = item["target"] as? String, !target.isEmpty {
                    ids.insert(target)
                }
            }
        }
        return ids
    }

    private func scanCodexSQLite(
        dbPath: String,
        indexTitles: [String: String],
        fileImportedIDs: Set<String>
    ) -> [WorkspaceSession] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        let importedThreadIDs = fileImportedIDs.union(loadExternalImportedThreadIDsFromDatabase(db))

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
            \(column("agent_role")),
            \(column("name")),
            \(column("preview")),
            \(column("thread_source")),
            \(column("originator")),
            \(column("archived"))
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
            let threadName = sqlite3_column_text(stmt, 11).flatMap { String(cString: $0) }
            let preview = sqlite3_column_text(stmt, 12).flatMap { String(cString: $0) }
            let threadSource = sqlite3_column_text(stmt, 13).flatMap { String(cString: $0) }
            let originator = sqlite3_column_text(stmt, 14).flatMap { String(cString: $0) }
            let archivedFlag = columns.contains("archived") ? sqlite3_column_int64(stmt, 15) : 0

            // 边表缺失或父 ID 为空时，沿用 JSONL 与删除检查共同使用的结构化来源解析，
            // 避免把非 UUID 的有效父 ID 丢掉，导致原本能挂载的子会话变成孤立节点。
            if parentThreadID == nil, let source {
                parentThreadID = WorkspaceSessionDeletionEngine.parentThreadID(in: source)
            }

            let relationship = WorkspaceSessionRelationshipAdapter.codex(
                source: source,
                parentID: parentThreadID,
                threadSource: threadSource
            )
            let isSubagent = relationship.isSubagent
            let createdDate = createdAtSec > 0 ? Date(timeIntervalSince1970: TimeInterval(createdAtSec)) : Date()
            let updatedDate = updatedAtSec > 0 ? Date(timeIntervalSince1970: TimeInterval(updatedAtSec)) : createdDate
            let projectName = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown"

            // 判断该记录在左侧会话列表中的可浏览性（不影响底层删除与存储统计）：
            // 1. 已归档会话（archived != 0 或位于 archived_sessions）
            let isArchived = archivedFlag != 0 || rolloutPath.contains("/archived_sessions/")
            // 2. 从 Claude Code 等外部客户端导入至 Codex 的镜像会话
            let isExternalImport = importedThreadIDs.contains(id)
            // 3. 语音辅助线程（thread_source == "voice_chat"）
            let isVoiceChat = threadSource == "voice_chat"
            // 4. 非交互子探针：当 originator 存在且不在官方交互端集合内，同时 thread_source 不为 "user"
            let trimmedOriginator = originator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let isHeadlessProbe = !trimmedOriginator.isEmpty
                && threadSource != "user"
                && !Self.standardInteractiveOriginators.contains(trimmedOriginator)
            // 5. 未发送任何消息且无落盘 rollout 文件的空 TUI 壳（与 Codex 官方 idx_threads_visible 索引 WHERE preview <> '' 对齐）
            let hasAnyText = Self.nonEmpty(preview) != nil
                || Self.nonEmpty(rawTitle) != nil
                || Self.nonEmpty(firstUserMsg) != nil
                || Self.nonEmpty(threadName) != nil
                || Self.nonEmpty(indexTitles[id]) != nil
            let isEmptyShell = columns.contains("preview")
                && !hasAnyText
                && (rolloutPath.isEmpty || !fileManager.fileExists(atPath: rolloutPath))

            let isBrowseVisible = !isArchived && !isExternalImport && !isVoiceChat && !isHeadlessProbe && !isEmptyShell

            let cleanedTitle = Self.cleanCodexDisplayText(rawTitle)
            let cleanedFirstMsg = Self.cleanCodexDisplayText(firstUserMsg)
            let cleanedPreview = Self.cleanCodexDisplayText(preview)

            var displayTitle = ""
            if isSubagent {
                if let nick = Self.nonEmpty(agentNickname) {
                    if let role = Self.nonEmpty(agentRole) {
                        displayTitle = "\(nick) (\(role))"
                    } else {
                        displayTitle = nick
                    }
                } else if let first = cleanedFirstMsg {
                    displayTitle = first
                } else if let title = cleanedTitle {
                    displayTitle = title
                } else {
                    displayTitle = "子任务 (\(id.prefix(8)))"
                }
            } else {
                // 优先采用官方自定义/索引会话名（threads.name 或 session_index.jsonl），再回退至清洗后的标题与首条用户消息。
                if let customName = Self.nonEmpty(threadName) {
                    displayTitle = customName
                } else if let indexedName = Self.nonEmpty(indexTitles[id]) {
                    displayTitle = indexedName
                } else if let title = cleanedTitle {
                    displayTitle = title
                } else if let first = cleanedFirstMsg {
                    displayTitle = first
                } else if let prev = cleanedPreview {
                    displayTitle = prev
                } else if let raw = Self.nonEmpty(rawTitle) {
                    displayTitle = raw
                } else {
                    displayTitle = "Codex Session (\(id.prefix(8)))"
                }
            }

            let singleLineTitle = displayTitle
                .components(separatedBy: .newlines)
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? displayTitle

            sessions.append(WorkspaceSession(
                id: id,
                agent: .codex,
                title: singleLineTitle,
                summary: cleanedFirstMsg ?? cleanedPreview ?? firstUserMsg,
                projectDirectory: cwd,
                projectName: projectName,
                createdAt: createdDate,
                lastActiveAt: updatedDate,
                filePath: rolloutPath,
                fileSizeBytes: 0,
                messageCount: 0,
                resumeCommand: WorkspaceSessionCommandBuilder.resumeCommand(agent: .codex, id: id),
                relationship: relationship,
                isBrowseVisible: isBrowseVisible
            ))
        }

        return sessions
    }

    private func parseCodexSessionMeta(
        filePath: String,
        titles: [String: String],
        isArchived: Bool = false,
        importedIDs: Set<String> = []
    ) -> WorkspaceSession? {
        guard let (head, tail) = SessionIOUtils.readHeadAndTailLines(path: filePath, headCount: 40, tailCount: 25) else {
            return nil
        }

        var sessionID: String?
        var cwd: String?
        var createdAt: Date?
        var firstPrompt: String?
        var originator: String?
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
                if originator == nil {
                    originator = payload?["originator"] as? String
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
                        if let txt = item["text"] as? String,
                           let cleaned = Self.cleanCodexDisplayText(txt) {
                            firstPrompt = cleaned
                            break
                        }
                    }
                } else if let prompt = json["prompt"] as? String,
                          let cleaned = Self.cleanCodexDisplayText(prompt) {
                    firstPrompt = cleaned
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

        let trimmedOriginator = originator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isHeadlessProbe = !trimmedOriginator.isEmpty && !Self.standardInteractiveOriginators.contains(trimmedOriginator)
        let isBrowseVisible = !isArchived
            && !filePath.contains("/archived_sessions/")
            && !importedIDs.contains(sid)
            && !isHeadlessProbe

        let isSubagent = relationship.isSubagent
        let knownTitle = Self.nonEmpty(titles[sid])
        let projectName = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown"
        let fallbackTitle = isSubagent ? "子任务 (\(sid.prefix(8)))" : "Codex Session (\(sid.prefix(8)))"
        let rawDisplayTitle = knownTitle ?? firstPrompt ?? fallbackTitle
        let displayTitle = rawDisplayTitle
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? rawDisplayTitle

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
            relationship: relationship,
            isBrowseVisible: isBrowseVisible
        )
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// 清洗 Codex 标题与用户首条提示词：
    /// 1. 若包含 Codex Desktop 注入的文件引用头（`## My request for Codex:`），提取其后的真实用户请求；
    /// 2. 剥离环境上下文、权限说明、子任务通知等系统注入标签；
    /// 3. 过滤纯系统指令块，保留真实用户意图文本。
    private static func cleanCodexDisplayText(_ raw: String?) -> String? {
        guard var text = nonEmpty(raw) else { return nil }

        let requestMarkers = ["## My request for Codex:", "## My request:"]
        for marker in requestMarkers {
            if let range = text.range(of: marker) {
                let extracted = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !extracted.isEmpty {
                    text = extracted
                    break
                }
            }
        }

        let patterns = [
            #"<environment_context>[\s\S]*?</environment_context>"#,
            #"<permissions instructions>[\s\S]*?</permissions instructions>"#,
            #"<collaboration_mode>[\s\S]*?</collaboration_mode>"#,
            #"<subagent_notification>[\s\S]*?</subagent_notification>"#,
            #"<INSTRUCTIONS>[\s\S]*?</INSTRUCTIONS>"#,
            #"<model_switch>[\s\S]*?</model_switch>"#,
            #"<recommended_plugins>[\s\S]*?</recommended_plugins>"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                text = regex.stringByReplacingMatches(
                    in: text,
                    options: [],
                    range: NSRange(text.startIndex..., in: text),
                    withTemplate: ""
                )
            }
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              !text.hasPrefix("<"),
              !text.hasPrefix("# AGENTS.md"),
              !text.hasPrefix("# Files") else {
            return nil
        }
        return text
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
        var messages: [WorkspaceSessionMessage] = []

        // 1. 若本地 rollout JSONL 文件存在且路径安全，优先从文件解析完整消息
        if !session.filePath.isEmpty, fileManager.fileExists(atPath: session.filePath) {
            if let _ = try? WorkspaceSessionPathPolicy(homeDirectory: homeDir, agent: .codex).validate(session.filePath),
               let content = try? String(contentsOfFile: session.filePath, encoding: .utf8) {
                messages = parseRolloutMessages(content: content)
            }
        }

        // 2. 若文件已被清理/归档或解析为空，从 ~/.codex/thread_history_1.sqlite (thread_items) 回退读取
        if messages.isEmpty {
            messages = loadMessagesFromThreadHistory(threadID: session.id)
        }

        // 3. 若数据库亦无多轮记录，回退展示 threads 表登记的首条用户消息（summary）
        if messages.isEmpty, let summary = session.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(WorkspaceSessionMessage(role: .user, content: summary, timestamp: session.createdAt))
        }

        return messages
    }

    /// 解析 rollout JSONL 格式的会话文本
    private func parseRolloutMessages(content: String) -> [WorkspaceSessionMessage] {
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

    /// 从现代 Codex 的 thread_history_1.sqlite 读取结构化消息记录，解决大部分 rollout 文件缺失问题
    private func loadMessagesFromThreadHistory(threadID: String) -> [WorkspaceSessionMessage] {
        let historyPath = (homeDir as NSString).appendingPathComponent(".codex/thread_history_1.sqlite")
        guard fileManager.fileExists(atPath: historyPath) else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(historyPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        let query = """
        SELECT item_type, item_json, created_at_ms
        FROM thread_items
        WHERE thread_id = ?
        ORDER BY rollout_ordinal ASC, created_at_ms ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (threadID as NSString).utf8String, -1, nil)

        var messages: [WorkspaceSessionMessage] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let itemType = sqlite3_column_text(stmt, 0).flatMap { String(cString: $0) } ?? ""
            guard let jsonBytes = sqlite3_column_text(stmt, 1) else { continue }
            let jsonString = String(cString: jsonBytes)
            let createdAtMs = sqlite3_column_int64(stmt, 2)
            let date = createdAtMs > 0 ? Date(timeIntervalSince1970: TimeInterval(createdAtMs) / 1000.0) : nil

            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            switch itemType {
            case "userMessage":
                var texts: [String] = []
                if let content = json["content"] as? [[String: Any]] {
                    for item in content {
                        if item["type"] as? String == "text", let text = item["text"] as? String, !text.isEmpty {
                            texts.append(text)
                        }
                    }
                } else if let directText = json["text"] as? String, !directText.isEmpty {
                    texts.append(directText)
                }
                let combined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !combined.isEmpty {
                    messages.append(WorkspaceSessionMessage(role: .user, content: combined, timestamp: date))
                }

            case "agentMessage":
                if let text = json["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    messages.append(WorkspaceSessionMessage(role: .assistant, content: text, timestamp: date))
                }

            case "reasoning":
                if let summary = json["summary"] as? [[String: Any]] {
                    let summaryText = summary.compactMap { $0["text"] as? String }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !summaryText.isEmpty {
                        messages.append(WorkspaceSessionMessage(role: .assistant, content: "💭 \(summaryText)", timestamp: date))
                    }
                }

            case "commandExecution":
                if let cmd = json["command"] as? String, !cmd.isEmpty {
                    messages.append(WorkspaceSessionMessage(role: .tool, content: "执行命令: \(cmd)", timestamp: date, toolCalls: [cmd]))
                }

            case "mcpToolCall", "custom_tool_call", "collabAgentToolCall":
                let toolName = json["tool"] as? String ?? json["name"] as? String ?? "tool"
                let input = json["input"] as? String ?? json["parameters"] as? String ?? ""
                let content = input.isEmpty ? "调用工具: \(toolName)" : "调用工具: \(toolName)\n\(input)"
                messages.append(WorkspaceSessionMessage(role: .tool, content: content, timestamp: date, toolCalls: [toolName]))

            case "fileChange":
                let files = (json["files"] as? [String])?.joined(separator: ", ") ?? (json["path"] as? String ?? "")
                if !files.isEmpty {
                    messages.append(WorkspaceSessionMessage(role: .tool, content: "修改文件: \(files)", timestamp: date))
                }

            case "webSearch":
                if let query = json["query"] as? String, !query.isEmpty {
                    messages.append(WorkspaceSessionMessage(role: .tool, content: "网页检索: \(query)", timestamp: date))
                }

            default:
                break
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

