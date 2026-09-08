// Copyright 2026 AIUsage contributors
// SPDX-License-Identifier: Apache-2.0
// 改编自 sylearn/AIUsage（bdb83bbe）；Quotio 修改：隔离扫描、可取消、私有统计归档与原生展示。
// 只保留调用分类与聚合元数据，不归档原始对话、工具参数或凭据。

import Foundation
import CryptoKit

// MARK: - Codex Call Event Source
// 解析 Codex 的本地会话日志，提取工具 / MCP / Skill 调用计数。
// 数据来源: ~/.codex/sessions、archived_sessions（或 $CODEX_HOME）下的 *.jsonl。
// 关注三类信号（皆带根 timestamp，ISO8601）：
//   • response_item.payload.type==function_call → 内置工具（取 payload.name）
//   • event_msg.type==mcp_tool_call_end → MCP 调用（取 invocation.{server,tool}）
//   • Codex 自 2025/12 起原生支持 Skills（~/.codex/skills，SKILL.md 开放标准）。
//     技能调用不是离散事件：渐进式披露下「用到才读全文」，体现为 exec_command
//     读取 skills/<name>/SKILL.md。故按 function_call 行内的 SKILL.md 路径启发式
//     计数（每个读取命令计一次），排除 .system 系统技能。属弱信号、可能有噪声。
// 与用量读取器共用有界流式扫描，按真实事件头跳过大正文，完整解析相关事件。

nonisolated struct CodexCallEventSource {
    let homeDirectory: String
    let timeZone: TimeZone
    let environment: [String: String]

    private static let skillMarker = "/SKILL.md"
    private static let skillsSegment = "skills"
    /// 合法技能目录名字符集：排除 glob（* ? [ ]）、空白等，避免把 `skills/*/SKILL.md` 当成技能。
    private static let skillNameAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    func resolveSessionRoots() -> [String] {
        let codexHome: String
        if let value = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            codexHome = value
        } else {
            codexHome = "\(homeDirectory)/.codex"
        }
        return ["\(codexHome)/sessions", "\(codexHome)/archived_sessions"]
    }

    func collect(cutoff: Date?) throws -> (entries: [CallAnalyticsEntry], status: CallSourceStatus) {
        let clock = CallAnalyticsClock(timeZone: timeZone)
        let roots = resolveSessionRoots().filter { FileManager.default.fileExists(atPath: $0) }
        guard !roots.isEmpty else {
            return ([], CallSourceStatus(source: .codex, available: false, eventCount: 0, filesScanned: 0, errorCode: nil))
        }

        let files = try collectJSONLFiles(roots: roots, cutoff: cutoff)
        var accumulator = CallEventAccumulator()
        var calls: [String: ParsedCall] = [:]
        var hadErrors = false
        var filesScanned = 0
        for file in files {
            try Task.checkCancellation()
            let fallbackDayKey = clock.dayKey(fileModificationDate(file) ?? Date())
            do {
                let stamp = try CodexUsageFileStamp(path: file)
                let read = try CodexUsageLineReader.read(path: file, offset: 0, limit: stamp.size,
                    acceptFinalLine: false, progress: { _ in },
                    isIrrelevantLine: { CodexLogEnvelope.isIrrelevantToCalls($0) }) { line in
                    parseLine(line, clock: clock, fallbackDayKey: fallbackDayKey,
                              calls: &calls, hadErrors: &hadErrors)
                }
                hadErrors = hadErrors || read.oversized
                filesScanned += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 单文件故障只标记来源不完整，保留其它已成功解析的调用，不再整批归零。
                hadErrors = true
            }
        }

        for call in calls.values {
            accumulator.add(source: .codex, kind: call.kind, name: call.name, server: call.server, dayKey: call.day, success: call.success, durationMs: call.duration)
        }
        let status = CallSourceStatus(
            source: .codex,
            available: true,
            eventCount: accumulator.eventCount,
            filesScanned: filesScanned,
            errorCode: hadErrors ? "read_partial" : nil
        )
        return (accumulator.entries(), status)
    }

    // MARK: - Parsing

    /// 同一个 call_id 可以同时出现在声明与 MCP 结束事件中；以结束事件补全同一条调用，避免重复。
    private struct ParsedCall {
        let kind: CallKind
        let name: String
        let server: String?
        let day: String
        var success: Bool?
        var duration: Double?
    }

    private func parseLine(
        _ line: Data, clock: CallAnalyticsClock, fallbackDayKey: String,
        calls: inout [String: ParsedCall], hadErrors: inout Bool
    ) {
        // 只接受结构化事件，防止工具输出正文里的 function_call 字样被当作真实调用。
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any],
              let eventType = payload["type"] as? String else { hadErrors = true; return }
        let day = (object["timestamp"] as? String).flatMap(clock.date(fromISO:)).map(clock.dayKey) ?? fallbackDayKey
        let identity = (payload["call_id"] as? String) ?? (payload["id"] as? String)
        // 缺少调用 ID 的日志仍可分析，但用完整记录的稳定摘要式值去重；该值只留在内存中。
        let key = identity ?? SHA256.hash(data: line).map { String(format: "%02x", $0) }.joined()
        if type == "event_msg", eventType == "mcp_tool_call_end",
           let invocation = payload["invocation"] as? [String: Any],
           let server = invocation["server"] as? String, let tool = invocation["tool"] as? String {
            let result = payload["result"] as? [String: Any]
            let success: Bool? = result?["Ok"] != nil ? true : (result?["Err"] != nil ? false : nil)
            let duration = payload["duration"] as? [String: Any]
            let secs = (duration?["secs"] as? NSNumber)?.doubleValue
            let nanos = (duration?["nanos"] as? NSNumber)?.doubleValue
            let milliseconds = secs != nil || nanos != nil ? (secs ?? 0) * 1000 + (nanos ?? 0) / 1_000_000 : nil
            calls[key] = ParsedCall(kind: .mcp, name: CallAnalyticsNaming.mcpDisplayName(server: server, tool: tool),
                server: server, day: day, success: success, duration: milliseconds)
        } else if type == "response_item", ["function_call", "custom_tool_call"].contains(eventType),
                  let rawName = payload["name"] as? String {
            // 新版 Codex 的自定义工具使用 input 而非 arguments；两类调用均按 call_id 去重。
            // 标准 functions 命名空间不影响 MCP/内置工具识别，保留工具自身名称。
            let name = rawName.hasPrefix("functions.") ? String(rawName.dropFirst("functions.".count)) : rawName
            let mcp = CallAnalyticsNaming.parseClaudeMCP(name)
            if calls[key] == nil {
                calls[key] = ParsedCall(kind: mcp == nil ? .builtin : .mcp,
                    name: mcp.map { CallAnalyticsNaming.mcpDisplayName(server: $0.server, tool: $0.tool) } ?? name,
                    server: mcp?.server, day: day)
            }
            // Skill 读取是启发式使用信号，只看执行工具参数，不将普通工具输出当作技能使用。
            if ["exec", "exec_command", "shell", "shell_command"].contains(name),
               let arguments = (payload["arguments"] as? String) ?? (payload["input"] as? String) {
                for skill in Self.skillReads(in: Data(arguments.utf8)) {
                    calls[key + ":skill:" + skill] = ParsedCall(kind: .skill, name: skill, server: nil, day: day)
                }
            }
        } else {
            hadErrors = true
        }
    }

    /// 判定 MCP 调用成功/失败：result 对象首 key 为 `Ok`→成功、`Err`→失败，缺失/截断→nil。
    /// 用「对象首 key」而非整行子串，避免正文里的 "Ok"/"Err" 误判（大行可能被 256KB 截断 → nil，优雅降级）。
    private static func mcpSuccess(in line: Data) -> Bool? {
        guard let resultRange = CallAnalyticsJSON.objectRange(forKey: "result", in: line),
              let key = CallAnalyticsJSON.firstKey(inObject: resultRange, in: line) else { return nil }
        switch key {
        case "Ok": return true
        case "Err": return false
        default: return nil
        }
    }

    /// 从 `"duration":{"secs":S,"nanos":N}` 算耗时（毫秒）。缺失/截断返回 nil。
    private static func mcpDurationMs(in line: Data) -> Double? {
        guard let durationRange = CallAnalyticsJSON.objectRange(forKey: "duration", in: line) else { return nil }
        let secs = CallAnalyticsJSON.intValue(forKey: "secs", in: line, range: durationRange) ?? 0
        let nanos = CallAnalyticsJSON.intValue(forKey: "nanos", in: line, range: durationRange) ?? 0
        if secs == 0 && nanos == 0 { return nil }
        return Double(secs) * 1000 + Double(nanos) / 1_000_000
    }

    /// 从 function_call 行内提取被读取的技能名（skills/<name>/SKILL.md 的父目录名）。
    /// 排除 .system 系统技能；按读取命令去重（function_call 输出行不含闭合的
    /// "function_call" 串，不会被本分支命中，因此天然避免文件内容造成的重复计数）。
    private static func skillReads(in line: Data) -> [String] {
        guard var text = String(data: line, encoding: .utf8), text.contains(skillMarker) else { return [] }
        // JSON 里转义的 \/ 归一为 /，保证路径段切分稳定。
        if text.contains("\\/") { text = text.replacingOccurrences(of: "\\/", with: "/") }

        var names = Set<String>()
        var cursor = text.startIndex
        while let marker = text.range(of: skillMarker, range: cursor..<text.endIndex) {
            cursor = marker.upperBound
            let before = text[text.startIndex..<marker.lowerBound]
            guard let nameSlash = before.lastIndex(of: "/") else { continue }
            let name = String(before[before.index(after: nameSlash)...])
            // 父级路径段必须是 skills/，排除系统技能、空名与含 glob/非法字符的名。
            let parentPath = before[before.startIndex..<nameSlash]
            guard parentPath.hasSuffix("/\(skillsSegment)") || parentPath == skillsSegment,
                  !name.isEmpty, name != ".system",
                  !before.contains("/.system/"),
                  name.unicodeScalars.allSatisfy(skillNameAllowed.contains) else { continue }
            names.insert(name)
        }
        return Array(names)
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
