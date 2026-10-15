// Copyright 2026 AIUsage contributors
// SPDX-License-Identifier: Apache-2.0
// 改编自 sylearn/AIUsage（bdb83bbe）；Quotio 修改：隔离扫描、可取消、私有统计归档与原生展示。
// 只保留调用分类与聚合元数据，不归档原始对话、工具参数或凭据。

import Foundation

// MARK: - Claude Call Event Source
// 解析 Claude Code 的本地会话日志，提取工具 / MCP / Skill 调用计数。
// 数据来源: ~/.claude/projects/**/*.jsonl（或 $CLAUDE_CONFIG_DIR/projects）。
// 仅读 assistant 行 message.content[] 里 type==tool_use 的 name；不读 token、不读正文。
// 0.8.0 曾删除 Claude 的 JSONL 用量扫描，这里是「只为调用分析」的独立轻量扫描。

nonisolated struct ClaudeCallEventSource {
    let homeDirectory: String
    let timeZone: TimeZone
    let environment: [String: String]

    /// Claude 单行可能含 thinking 长文，给足缓冲以保证 tool_use 行被完整解析。
    private static let maxLineBytes = 4 * 1024 * 1024
    private static let webSearchTools: Set<String> = ["WebSearch", "WebFetch"]

    /// 已解析待配对的 tool_use（等其 tool_result 确定成功/失败后再计入累加器）。
    private struct PendingCall {
        let kind: CallKind
        let name: String
        let server: String?
        let agent: String   // "main" / "subagent"
        let dayKey: String
    }

    func resolveProjectRoots() -> [String] {
        if let env = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env.split(separator: ",").map { part -> String in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                return (trimmed as NSString).lastPathComponent == "projects" ? trimmed : "\(trimmed)/projects"
            }
        }
        return [
            "\(homeDirectory)/.config/claude/projects",
            "\(homeDirectory)/.claude/projects"
        ]
    }

    func collect(cutoff: Date?) throws -> (entries: [CallAnalyticsEntry], status: CallSourceStatus, agentInvocationsByDay: [String: [AgentInvocationCount]]) {
        let clock = CallAnalyticsClock(timeZone: timeZone)
        let roots = resolveProjectRoots().filter { FileManager.default.fileExists(atPath: $0) }
        guard !roots.isEmpty else {
            return ([], CallSourceStatus(source: .claude, available: false, eventCount: 0, filesScanned: 0, errorCode: nil), [:])
        }

        let files = try collectJSONLFiles(roots: roots, cutoff: cutoff)
        var accumulator = CallEventAccumulator()
        // 各 agent 的「被调用次数」：一份会话文件 = 一次。主会话（根文件）记 "main"，
        // 子代理记其具体 agentType（读不到 → "subagent"）。与该 agent 是否调过工具无关。
        // 为支持按天冻结归档（issue #32），按「会话最早事件所在日」归属该次调用——该日恒定、
        // 跨日重扫不漂移，配合归档「过去日冻结」语义可避免同一会话被多日重复计数。
        var seenCallIDs = Set<String>()
        // 会话标识只在本次扫描内去重，绝不落盘；复制日志不能增加启动次数。
        // 子代理共享父 sessionId，因此还必须包含 agentId（缺失时用稳定文件名）。
        struct SessionObservation { var day: String?; let agent: String }
        var sessions: [String: SessionObservation] = [:]
        for file in files {
            try Task.checkCancellation()
            // 路径含 subagents/ 的整文件视为 subagent；其具体类型取边车 agent-<id>.meta.json 的 agentType
            // （如 Explore / Plan），拿不到则归为通用 "subagent"。常规文件再按行内 isSidechain 兜底。
            let isSubagentFile = file.contains("/subagents/")
            let subagentType = isSubagentFile ? readSubagentType(forFile: file) : nil
            let agentName = isSubagentFile ? (subagentType ?? "subagent") : "main"
            let fallbackDayKey = clock.dayKey(fileModificationDate(file) ?? Date())
            // 同文件内按 tool_use_id 配对 tool_result（成功率）。配对发生在文件内、顺序保证 result 在 use 之后。
            var pending: [String: PendingCall] = [:]
            var earliestDayKey: String?
            var sessionID: String?
            var agentID: String?
            var hasSessionMessage = false
            try CallAnalyticsLineReader.forEachLine(
                path: file,
                // 纯文本行没有 tool_use，但其结构化时间戳仍是会话日期的证据。
                // 正文仅随单行解析短暂存在，不加入统计对象或持久化。
                needles: [],
                maxLineBytes: Self.maxLineBytes
            ) { line in
                parseLine(line, clock: clock, fallbackDayKey: fallbackDayKey,
                          isSubagentFile: isSubagentFile, subagentType: subagentType,
                          pending: &pending, seenCallIDs: &seenCallIDs, earliestDayKey: &earliestDayKey,
                          sessionID: &sessionID, agentID: &agentID, hasSessionMessage: &hasSessionMessage, into: &accumulator)
            }
            // 文件结束仍未配到 tool_result 的 tool_use：只计数，成功率未知（不计入分母）。
            for call in pending.values {
                accumulator.add(source: .claude, kind: call.kind, name: call.name,
                                server: call.server, dayKey: call.dayKey, agent: call.agent, success: nil)
            }
            guard hasSessionMessage else { continue }
            let stem = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
            let identity = isSubagentFile
                ? "sub:" + (sessionID ?? "") + ":" + (agentID ?? stem)
                : "main:" + (sessionID ?? stem)
            if var previous = sessions[identity] {
                if let day = earliestDayKey, previous.day == nil || day < previous.day! { previous.day = day }
                sessions[identity] = previous
            } else { sessions[identity] = SessionObservation(day: earliestDayKey, agent: agentName) }
        }

        let status = CallSourceStatus(
            source: .claude,
            available: true,
            eventCount: accumulator.eventCount,
            filesScanned: files.count,
            errorCode: nil
        )
        var invocationsByDay: [String: [String: Int]] = [:]
        for session in sessions.values {
            // 空键是内部「日期未知」桶，Engine 显式转换为 nil；绝不使用 mtime 或扫描日期。
            invocationsByDay[session.day ?? "", default: [:]][session.agent, default: 0] += 1
        }
        let agentInvocationsByDay = invocationsByDay.mapValues { perAgent in
            perAgent.map { AgentInvocationCount(source: .claude, agent: $0.key, count: $0.value) }
        }
        return (accumulator.entries(), status, agentInvocationsByDay)
    }

    // MARK: - Parsing

    private func parseLine(
        _ line: Data,
        clock: CallAnalyticsClock,
        fallbackDayKey: String,
        isSubagentFile: Bool,
        subagentType: String?,
        pending: inout [String: PendingCall],
        seenCallIDs: inout Set<String>,
        earliestDayKey: inout String?,
        sessionID: inout String?,
        agentID: inout String?,
        hasSessionMessage: inout Bool,
        into accumulator: inout CallEventAccumulator
    ) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return }
        // 先读取结构化会话元数据，再进入工具解析；纯文本 content 可以是字符串或数组。
        // 文件修改时间可因复制、同步或追加而改变，不能作为启动日期的证据。
        if let timestamp = object["timestamp"] as? String, let date = clock.date(fromISO: timestamp) {
            let day = clock.dayKey(date)
            if earliestDayKey == nil || day < earliestDayKey! { earliestDayKey = day }
        }
        if let value = object["sessionId"] as? String, !value.isEmpty { sessionID = value }
        if let value = object["agentId"] as? String, !value.isEmpty { agentID = value }
        guard let message = object["message"] as? [String: Any] else { return }
        if type == "assistant" || type == "user" { hasSessionMessage = true }
        guard let content = message["content"] as? [[String: Any]] else { return }

        switch type {
        case "assistant":
            let dayKey: String
            if let ts = object["timestamp"] as? String, let date = clock.date(fromISO: ts) {
                dayKey = clock.dayKey(date)
            } else {
                dayKey = fallbackDayKey
            }
            // agent：子代理文件用其具体类型（拿不到→"subagent"）；常规文件按行 isSidechain 兜底；否则 "main"。
            let agent: String
            if isSubagentFile {
                agent = subagentType ?? "subagent"
            } else if (object["isSidechain"] as? Bool) == true {
                agent = "subagent"
            } else {
                agent = "main"
            }
            for item in content {
                guard (item["type"] as? String) == "tool_use",
                      let rawName = item["name"] as? String, !rawName.isEmpty else {
                    continue
                }
                let call = makeCall(rawName: rawName, input: item["input"] as? [String: Any], agent: agent, dayKey: dayKey)
                if let id = (item["id"] as? String), !id.isEmpty {
                    guard seenCallIDs.insert(id).inserted else { continue }
                    pending[id] = call   // 等 tool_result 再计入（带成功/失败）
                } else {
                    // 无 id 无法配对：只计数，成功率未知。
                    accumulator.add(source: .claude, kind: call.kind, name: call.name,
                                    server: call.server, dayKey: call.dayKey, agent: call.agent, success: nil)
                }
            }

        case "user":
            // 用户行里的 tool_result 给出对应 tool_use 的成功/失败：is_error==true→失败，false/缺省→成功。
            for item in content {
                guard (item["type"] as? String) == "tool_result",
                      let id = item["tool_use_id"] as? String,
                      let call = pending.removeValue(forKey: id) else {
                    continue
                }
                let isError = (item["is_error"] as? Bool) == true
                accumulator.add(source: .claude, kind: call.kind, name: call.name,
                                server: call.server, dayKey: call.dayKey, agent: call.agent, success: !isError)
            }

        default:
            return
        }
    }

    private func makeCall(rawName: String, input: [String: Any]?, agent: String, dayKey: String) -> PendingCall {
        if let mcp = CallAnalyticsNaming.parseClaudeMCP(rawName) {
            return PendingCall(
                kind: .mcp,
                name: CallAnalyticsNaming.mcpDisplayName(server: mcp.server, tool: mcp.tool),
                server: mcp.server,
                agent: agent,
                dayKey: dayKey
            )
        }

        if rawName == "Skill" {
            let trimmed = (input?["skill"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let skillName = trimmed.isEmpty ? "(unknown)" : trimmed
            return PendingCall(kind: .skill, name: skillName, server: nil, agent: agent, dayKey: dayKey)
        }

        let kind: CallKind = Self.webSearchTools.contains(rawName) ? .webSearch : .builtin
        return PendingCall(kind: kind, name: rawName, server: nil, agent: agent, dayKey: dayKey)
    }

    /// 读取子代理边车 `agent-<id>.meta.json` 的 `agentType`（如 Explore / Plan）。拿不到返回 nil。
    private func readSubagentType(forFile file: String) -> String? {
        guard file.hasSuffix(".jsonl") else { return nil }
        let metaPath = String(file.dropLast(".jsonl".count)) + ".meta.json"
        guard let data = FileManager.default.contents(atPath: metaPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = (object["agentType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !type.isEmpty else {
            return nil
        }
        return type
    }

    // MARK: - File discovery

    private func collectJSONLFiles(roots: [String], cutoff: Date?) throws -> [String] {
        var files: [String] = []
        var seen = Set<String>()
        for root in roots {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            var encounteredReadFailure = false
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in encounteredReadFailure = true; return false }
            ) else { throw CallAnalyticsReadError.unreadable }

            for case let item as URL in enumerator {
                try Task.checkCancellation()
                guard item.pathExtension.lowercased() == "jsonl" else { continue }
                guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .isSymbolicLinkKey]) else {
                    throw CallAnalyticsReadError.unreadable
                }
                if values.isRegularFile != true || values.isSymbolicLink == true { continue }
                if let cutoff, let modified = values.contentModificationDate, modified < cutoff { continue }
                guard seen.insert(item.path).inserted else { continue }
                files.append(item.path)
            }
            // 文件系统枚举失败也属于读取失败，不能把无权限目录解释为‘成功扫描但没有调用’。
            if encounteredReadFailure { throw CallAnalyticsReadError.unreadable }
        }
        return files
    }

    private func fileModificationDate(_ path: String) -> Date? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }
}
