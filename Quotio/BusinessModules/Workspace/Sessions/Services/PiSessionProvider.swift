//
//  PiSessionProvider.swift
//  Quotio
//

import Foundation

/// 原 Pi 会话 Provider，私有扫描和消息方法随类型迁移，不把消息 parentId 当作会话父子关系。
/// 保留两处原扫描根路径、显式会话关系规范化及 @concurrent 边界。
/// 删除继续先扫描相关会话再进入原事务引擎，状态与任务所有权不变。
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

