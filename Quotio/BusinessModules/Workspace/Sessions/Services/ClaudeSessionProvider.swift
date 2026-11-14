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

            if json["type"] as? String == "api-request-blob" { continue }
            if cwd == nil { cwd = json["cwd"] as? String }
            if createdAt == nil, let ts = json["timestamp"] as? String {
                createdAt = SessionIOUtils.parseDate(ts)
            }
            if firstPrompt == nil {
                if json["isMeta"] as? Bool == true || json["toolUseResult"] != nil || json["sourceToolAssistantUUID"] != nil {
                    continue
                }
                var ignoredCommand = false
                if let msg = json["message"] as? [String: Any],
                   let role = msg["role"] as? String, role == "user" {
                    firstPrompt = extractUserPrompt(from: msg["content"], sawCommandWrapper: &ignoredCommand)
                } else if let prompt = json["prompt"] as? String, !prompt.isEmpty {
                    firstPrompt = Self.cleanUserPromptText(prompt, sawCommandWrapper: &ignoredCommand)
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
        let rawDisplayTitle = description.map { "\(typePrefix)\($0)" } ?? firstPrompt ?? "子任务 (\(subagentID.prefix(8)))"
        let displayTitle = Self.singleLineTitle(rawDisplayTitle)

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
        guard let (head, tail) = SessionIOUtils.readHeadAndTailLines(path: filePath, headCount: 80, tailCount: 60) else {
            return nil
        }

        var sessionID: String?
        var cwd: String?
        var createdAt: Date?
        var firstUserPrompt: String?
        var firstSlashCommand: String?
        var agentID: String?
        var entrypoint: String?
        var customTitle: String?
        var aiTitle: String?
        var hasAssistantTurn = false
        var sawCommandWrapper = false
        var sawLocalCommandCaveat = false
        var sawLifecycleEnvelope = false
        var relationshipMetadata: [[String: Any]] = []

        // 优先尝试读取同目录关联的 <sessionDir>/custom-title.json（若存在）
        let companionDir = (filePath as NSString).deletingPathExtension
        let customTitlePath = (companionDir as NSString).appendingPathComponent("custom-title.json")
        if fileManager.fileExists(atPath: customTitlePath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: customTitlePath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            customTitle = Self.nonEmpty(json["customTitle"] as? String ?? json["title"] as? String)
        }

        for line in head {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let recordType = json["type"] as? String
            if recordType == "last-prompt" || recordType == "cost-state" || recordType == "permission-mode" {
                sawLifecycleEnvelope = true
            }
            if sessionID == nil, let sid = json["sessionId"] as? String {
                sessionID = sid
            }
            if entrypoint == nil, let ep = Self.nonEmpty(json["entrypoint"] as? String) {
                entrypoint = ep
            }
            relationshipMetadata.append(json)
            if agentID == nil { agentID = WorkspaceSessionRelationship.identifier(json["agentId"] as? String) }
            if cwd == nil {
                if let dir = Self.nonEmpty(json["cwd"] as? String) {
                    cwd = dir
                } else if let attachment = json["attachment"] as? [String: Any],
                          let snapshot = attachment["snapshot"] as? [String: Any],
                          let dir = Self.nonEmpty(snapshot["workingDirectory"] as? String) {
                    cwd = dir
                }
            }
            if createdAt == nil, let ts = json["timestamp"] as? String {
                createdAt = SessionIOUtils.parseDate(ts)
            }

            if recordType == "custom-title", let t = Self.nonEmpty(json["customTitle"] as? String) {
                customTitle = t
            } else if recordType == "ai-title", let t = Self.nonEmpty(json["aiTitle"] as? String) {
                aiTitle = t
            } else if customTitle == nil, let t = Self.nonEmpty(json["title"] as? String) {
                customTitle = t
            }

            // api-request-blob 是请求快照载荷，内部包含完整的 <system-reminder>，不能当作用户提问或正文消息。
            if recordType == "api-request-blob" {
                continue
            }

            if recordType == "assistant" || ((json["message"] as? [String: Any])?["role"] as? String == "assistant") {
                hasAssistantTurn = true
            }

            if firstUserPrompt == nil {
                if json["isMeta"] as? Bool == true || recordType == "system" {
                    if let content = (json["message"] as? [String: Any])?["content"] as? String {
                        if content.contains("<local-command-caveat>") {
                            sawLocalCommandCaveat = true
                            sawCommandWrapper = true
                        } else if content.contains("<local-command-") || content.contains("<command-name>") {
                            sawCommandWrapper = true
                        }
                    } else if recordType == "system", json["subtype"] as? String == "local_command" {
                        sawCommandWrapper = true
                    }
                    continue
                }
                if json["toolUseResult"] != nil || json["sourceToolAssistantUUID"] != nil {
                    continue
                }
                if let msg = json["message"] as? [String: Any],
                   let role = msg["role"] as? String, role == "user" {
                    if !sawLocalCommandCaveat, firstSlashCommand == nil {
                        firstSlashCommand = Self.extractSlashCommand(from: msg["content"])
                    }
                    sawLocalCommandCaveat = false
                    firstUserPrompt = extractUserPrompt(from: msg["content"], sawCommandWrapper: &sawCommandWrapper)
                } else if let prompt = json["prompt"] as? String, !prompt.isEmpty {
                    if !sawLocalCommandCaveat, firstSlashCommand == nil {
                        firstSlashCommand = Self.extractSlashCommand(from: prompt)
                    }
                    sawLocalCommandCaveat = false
                    firstUserPrompt = Self.cleanUserPromptText(prompt, sawCommandWrapper: &sawCommandWrapper)
                }
            }

            // 继续检查有界头部中的关系字段，不能因标题已经齐全就跳过后续 sidechain 标记。
        }

        var lastActiveAt = createdAt ?? Date()
        var foundLastActiveTimestamp = false

        for line in tail.reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if !foundLastActiveTimestamp,
               let ts = json["timestamp"] as? String,
               let date = SessionIOUtils.parseDate(ts) {
                lastActiveAt = date
                foundLastActiveTimestamp = true
            }

            let recordType = json["type"] as? String
            if recordType == "last-prompt" || recordType == "cost-state" || recordType == "permission-mode" {
                sawLifecycleEnvelope = true
            }
            if recordType != "api-request-blob",
               (recordType == "assistant" || ((json["message"] as? [String: Any])?["role"] as? String == "assistant")) {
                hasAssistantTurn = true
            }
            if customTitle == nil, recordType == "custom-title", let t = Self.nonEmpty(json["customTitle"] as? String) {
                customTitle = t
            }
            if customTitle == nil, let t = Self.nonEmpty(json["title"] as? String) {
                customTitle = t
            }
            if aiTitle == nil, recordType == "ai-title", let t = Self.nonEmpty(json["aiTitle"] as? String) {
                aiTitle = t
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

        // 判断该会话是否应在左侧主列表中可见：
        // 1. entrypoint == "sdk-cli" 代表通过 `claude -p` / SDK 非交互式启动的后台调用（如子代理或自动化脚本探针），不应混入交互式主会话列表；
        // 2. 仅执行过本地斜杠命令（如 /model、/clear）或刚打开即退出、无任何有效用户提问与助手回复的空命令壳不展示在主列表中。
        let isHeadlessSDK = entrypoint?.lowercased() == "sdk-cli"
        let isEmptyOrCommandOnlyShell = (sawCommandWrapper || sawLifecycleEnvelope)
            && firstUserPrompt == nil
            && !hasAssistantTurn
            && customTitle == nil
            && aiTitle == nil
        let isBrowseVisible = !isHeadlessSDK && !isEmptyOrCommandOnlyShell

        // 若会话由 Skill 斜杠命令发起且已有真实助手回复，允许使用斜杠命令本身作为回退提问标题
        let effectivePrompt = firstUserPrompt ?? (hasAssistantTurn ? firstSlashCommand : nil)
        let fallbackTitle = relationship.isSubagent ? "子任务 (\(sid.prefix(8)))" : "Claude Session (\(sid.prefix(8)))"
        let rawDisplayTitle = customTitle ?? aiTitle ?? effectivePrompt ?? fallbackTitle
        let displayTitle = Self.singleLineTitle(rawDisplayTitle)

        return WorkspaceSession(
            id: sid,
            agent: .claude,
            title: displayTitle,
            summary: effectivePrompt ?? aiTitle,
            projectDirectory: cwd,
            projectName: projectName,
            createdAt: createdAt,
            lastActiveAt: modDate,
            filePath: filePath,
            fileSizeBytes: fileSize,
            messageCount: 0,
            resumeCommand: WorkspaceSessionCommandBuilder.resumeCommand(agent: .claude, id: sid, parentID: relationship.parentSessionID),
            relationship: relationship,
            isBrowseVisible: isBrowseVisible
        )
    }

    private func extractUserPrompt(from content: Any?, sawCommandWrapper: inout Bool) -> String? {
        if let str = content as? String {
            return Self.cleanUserPromptText(str, sawCommandWrapper: &sawCommandWrapper)
        }
        if let array = content as? [[String: Any]] {
            for item in array {
                guard let text = item["text"] as? String else { continue }
                if let cleaned = Self.cleanUserPromptText(text, sawCommandWrapper: &sawCommandWrapper) {
                    return cleaned
                }
            }
        }
        return nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func singleLineTitle(_ raw: String) -> String {
        raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? raw
    }

    /// 从用户消息中提取非本地命令的斜杠命令名与参数（如 `/rex`、`/agent-workflow:agent-config status`），
    /// 供已产生真实助手回复的斜杠命令会话回退作为标题或消息内容。
    private static func extractSlashCommand(from content: Any?) -> String? {
        let raw: String
        if let str = content as? String {
            raw = str
        } else if let array = content as? [[String: Any]] {
            raw = array.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            return nil
        }
        guard !raw.contains("<local-command-stdout>"),
              !raw.contains("<local-command-stderr>"),
              !raw.contains("<local-command-caveat>") else {
            return nil
        }
        guard let nameRegex = try? NSRegularExpression(pattern: #"<command-name>([\s\S]*?)</command-name>"#, options: [.caseInsensitive]),
              let nameMatch = nameRegex.firstMatch(in: raw, options: [], range: NSRange(raw.startIndex..., in: raw)),
              let nameRange = Range(nameMatch.range(at: 1), in: raw) else {
            return nil
        }
        let cmdName = String(raw[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmdName.isEmpty else { return nil }

        var cmdArgs = ""
        if let argsRegex = try? NSRegularExpression(pattern: #"<command-args>([\s\S]*?)</command-args>"#, options: [.caseInsensitive]),
           let argsMatch = argsRegex.firstMatch(in: raw, options: [], range: NSRange(raw.startIndex..., in: raw)),
           let argsRange = Range(argsMatch.range(at: 1), in: raw) {
            cmdArgs = String(raw[argsRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cmdArgs.isEmpty ? cmdName : "\(cmdName) \(cmdArgs)"
    }

    /// 剥离 Claude Code 注入的系统提示块（`<system-reminder>` 等）与本地命令包装标签（`<command-name>` 等），
    /// 提取真实用户提问文本，避免 `<system-reminder>` 或 `/model`、`/clear` 污染会话标题与摘要。
    private static func cleanUserPromptText(_ raw: String, sawCommandWrapper: inout Bool) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.contains("<local-command-") || text.contains("<command-name>") || text.contains("<command-message>") {
            sawCommandWrapper = true
        }

        let strippedBlocks = [
            #"<system-reminder>[\s\S]*?</system-reminder>"#,
            #"<local-command-caveat>[\s\S]*?</local-command-caveat>"#,
            #"<local-command-stdout>[\s\S]*?</local-command-stdout>"#,
            #"<local-command-stderr>[\s\S]*?</local-command-stderr>"#,
            #"<command-message>[\s\S]*?</command-message>"#,
            #"<command-name>[\s\S]*?</command-name>"#,
            #"<command-args>[\s\S]*?</command-args>"#
        ]
        for pattern in strippedBlocks {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                text = regex.stringByReplacingMatches(
                    in: text,
                    options: [],
                    range: NSRange(text.startIndex..., in: text),
                    withTemplate: ""
                )
            }
        }

        // 剥离截图附件路径前缀（如 `[Image: source: /var/folders/...]`），保留后续真实提问
        if let imageRegex = try? NSRegularExpression(pattern: #"^\[Image:\s*source:[^\]]+\]\s*"#, options: []) {
            text = imageRegex.stringByReplacingMatches(
                in: text,
                options: [],
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("<system-reminder>") else {
            return nil
        }
        return text
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

            // 忽略 api-request-blob 快照载荷与系统注入的 meta 行，避免 <system-reminder> 混入会话详情
            if json["type"] as? String == "api-request-blob" || json["isMeta"] as? Bool == true {
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
        let raw: String
        if let str = content as? String {
            raw = str
        } else if let array = content as? [[String: Any]] {
            raw = array.compactMap { item -> String? in
                if item["type"] as? String == "text", let text = item["text"] as? String {
                    return text
                }
                if item["type"] == nil, let text = item["text"] as? String {
                    return text
                }
                return nil
            }.joined(separator: "\n")
        } else {
            return ""
        }
        var ignoredCommand = false
        return Self.cleanUserPromptText(raw, sawCommandWrapper: &ignoredCommand) ?? ""
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

