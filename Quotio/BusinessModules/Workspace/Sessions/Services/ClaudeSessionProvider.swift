//
//  ClaudeSessionProvider.swift
//  Quotio
//

import Foundation

/// 原 Claude 会话 Provider，私有 homeDir、文件访问及全部解析方法随类型完整迁移。
/// 保留官方 subagents 路径优先于历史平铺副本的合并顺序，消息与关系语义不变。
/// 原 @concurrent 边界及统一删除引擎入口保留，不新增任务、缓存或另一套删除计划。
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
        guard fileManager.fileExists(atPath: session.filePath) else { return [] }

        var messages: [WorkspaceSessionMessage] = []
        let fileURL = URL(fileURLWithPath: session.filePath)

        // 使用异步行流逐行读取，避免大文件（可达 100MB+）一次性加载耗尽内存或引起主线程卡顿
        for try await line in fileURL.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            // 过滤子链/sidechain记录（除非当前会话本身为子任务会话）
            if !session.isSubagent, json["isSidechain"] as? Bool == true {
                continue
            }

            let ts = (json["timestamp"] as? String).flatMap { SessionIOUtils.parseDate($0) }

            // 1. 处理现代 Claude Code 记录的本地斜杠命令 (system.local_command)
            if json["type"] as? String == "system", json["subtype"] as? String == "local_command",
               let cmdContent = json["content"] as? String, !cmdContent.isEmpty {
                messages.append(WorkspaceSessionMessage(role: .user, content: cmdContent, timestamp: ts))
                continue
            }

            // 2. 处理直接 prompt 字段
            if let prompt = json["prompt"] as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append(WorkspaceSessionMessage(role: .user, content: prompt, timestamp: ts))
                continue
            }

            // 3. 处理标准 message 结构体
            if let msg = json["message"] as? [String: Any] {
                let roleStr = msg["role"] as? String ?? (json["type"] as? String ?? "assistant")

                if roleStr == "user" {
                    // 若记录仅携带 toolUseResult 或 sourceToolAssistantUUID，属于工具回传载荷而非用户提问
                    if json["toolUseResult"] != nil || json["sourceToolAssistantUUID"] != nil {
                        continue
                    }

                    let text = extractUserText(from: msg["content"])
                    if !text.isEmpty {
                        messages.append(WorkspaceSessionMessage(role: .user, content: text, timestamp: ts))
                    }
                } else {
                    // assistant 消息：提取正文文本、思考过程与工具调用
                    let parsed = extractAssistantBlocks(from: msg["content"])
                    if let text = parsed.text, !text.isEmpty {
                        messages.append(WorkspaceSessionMessage(role: .assistant, content: text, timestamp: ts))
                    }
                    for tool in parsed.tools {
                        messages.append(WorkspaceSessionMessage(
                            role: .tool,
                            content: tool.detail.isEmpty ? "调用工具: \(tool.name)" : "调用工具: \(tool.name)\n\(tool.detail)",
                            timestamp: ts,
                            toolCalls: [tool.name]
                        ))
                    }
                }
            }
        }

        // 4. 若解析结果为空，回退展示扫描所得的 initial prompt (summary)
        if messages.isEmpty, let summary = session.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(WorkspaceSessionMessage(role: .user, content: summary, timestamp: session.createdAt))
        }

        return messages
    }

    private func extractUserText(from content: Any?) -> String {
        if let str = content as? String { return str.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let array = content as? [[String: Any]] {
            return array.compactMap { item -> String? in
                if item["type"] as? String == "text", let text = item["text"] as? String {
                    return text
                }
                if item["type"] == nil, let text = item["text"] as? String {
                    return text
                }
                return nil
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private struct ParsedAssistantContent {
        var text: String?
        var tools: [(name: String, detail: String)]
    }

    private func extractAssistantBlocks(from content: Any?) -> ParsedAssistantContent {
        if let str = content as? String {
            return ParsedAssistantContent(text: str.trimmingCharacters(in: .whitespacesAndNewlines), tools: [])
        }
        guard let array = content as? [[String: Any]] else {
            return ParsedAssistantContent(text: nil, tools: [])
        }

        var textParts: [String] = []
        var tools: [(name: String, detail: String)] = []

        for item in array {
            let blockType = item["type"] as? String ?? ""
            if blockType == "text", let text = item["text"] as? String, !text.isEmpty {
                textParts.append(text)
            } else if blockType == "thinking", let thinking = item["thinking"] as? String, !thinking.isEmpty {
                textParts.append("💭 \(thinking.trimmingCharacters(in: .whitespacesAndNewlines))")
            } else if blockType == "tool_use" {
                let name = item["name"] as? String ?? "tool"
                let input = (item["input"] as? [String: Any]).flatMap {
                    try? String(data: JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted]), encoding: .utf8)
                } ?? ""
                tools.append((name: name, detail: input))
            }
        }

        let combinedText = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedAssistantContent(text: combinedText.isEmpty ? nil : combinedText, tools: tools)
    }

    @concurrent
    public func deleteSession(_ session: WorkspaceSession) async throws -> Bool {
        // 路径校验、完整级联计划和回滚策略由统一引擎负责，避免各客户端实现漂移。
        try WorkspaceSessionDeletionEngine.delete(session, expectedAgent: .claude, homeDirectory: homeDir)
    }
}

