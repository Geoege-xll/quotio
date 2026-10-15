// Copyright 2026 AIUsage contributors
// SPDX-License-Identifier: Apache-2.0
// 改编自 sylearn/AIUsage（bdb83bbe）；Quotio 修改：隔离扫描、可取消、私有统计归档与原生展示。
// 只保留调用分类与聚合元数据，不归档原始对话、工具参数或凭据。

import Foundation
import SQLite3
import Darwin

// MARK: - OpenCode Call Event Source
// 解析 OpenCode 的 opencode.db `part` 表，提取工具 / MCP / Skill 调用计数。
// 数据来源: ~/.local/share/opencode/opencode.db（或 $XDG_DATA_HOME / Application Support）。
// part 行 data(JSON)：{ "type":"tool", "tool":"<名>", "state":{ "status":..., "input":{...} } }。
// 使用 SQLite 只读连接查询，包括 WAL 中已提交的数据；绝不复制原始会话数据库。


nonisolated struct OpenCodeCallEventSource {
    let homeDirectory: String
    let timeZone: TimeZone
    let environment: [String: String]
    /// 已配置的 OpenCode MCP server 名（来自 opencode.json）。用于把工具名 `<server>_<tool>`
    /// 按已知 server 做最长前缀匹配，处理 server 名本身含 `_`/`-` 的情况；缺省回退首个 `_` 启发式。
    var knownMCPServers: Set<String> = []

    private static let databaseFilename = "opencode.db"
    /// OpenCode 内置工具名（单词、无下划线）。其余含下划线者按 MCP 处理（启发式，见 classify）。
    private static let builtinTools: Set<String> = [
        "read", "write", "edit", "multiedit", "bash", "glob", "grep",
        "list", "webfetch", "patch", "task", "question", "todowrite", "todoread", "invalid"
    ]

    func collect(cutoff: Date?) throws -> (entries: [CallAnalyticsEntry], status: CallSourceStatus) {
        let clock = CallAnalyticsClock(timeZone: timeZone)
        guard let dataDirectory = resolveDataDirectory() else {
            return ([], CallSourceStatus(source: .opencode, available: false, eventCount: 0, filesScanned: 0, errorCode: nil))
        }

        // SQLite 只读连接本身提供一致性读取；不复制数据库及 WAL，避免把原始对话落入临时文件。
        let databaseURL = URL(fileURLWithPath: dataDirectory).appendingPathComponent(Self.databaseFilename)
        guard (try? databaseURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
            return ([], CallSourceStatus(source: .opencode, available: true, eventCount: 0, filesScanned: 0, errorCode: "db_symlink"))
        }
        // macOS 的 /var 本身指向 /private/var；先规范合法的目录别名，再让 SQLite 拒绝最终数据库链接。
        guard let resolvedDirectory = realpath(databaseURL.deletingLastPathComponent().path, nil) else {
            throw CallAnalyticsReadError.database
        }
        let canonicalDirectory = String(cString: resolvedDirectory)
        free(resolvedDirectory)
        let snapshotPath = URL(fileURLWithPath: canonicalDirectory).appendingPathComponent(Self.databaseFilename).path
        try Task.checkCancellation()

        let sinceMillis: Int64? = cutoff.map { Int64($0.timeIntervalSince1970 * 1000) }
        var accumulator = CallEventAccumulator()
        do {
            try forEachToolPart(databasePath: snapshotPath, sinceMillis: sinceMillis) { millis, data in
                parsePart(data, millis: millis, clock: clock, into: &accumulator)
            }
        } catch {
            if error is CancellationError { throw error }
            let code = "db_query_failed"
            return ([], CallSourceStatus(source: .opencode, available: true, eventCount: 0, filesScanned: 0, errorCode: code))
        }

        let status = CallSourceStatus(
            source: .opencode,
            available: true,
            eventCount: accumulator.eventCount,
            filesScanned: 1,
            errorCode: nil
        )
        return (accumulator.entries(), status)
    }

    // MARK: - Parsing

    private func parsePart(
        _ data: Data,
        millis: Int64,
        clock: CallAnalyticsClock,
        into accumulator: inout CallEventAccumulator
    ) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["type"] as? String) == "tool",
              let tool = (object["tool"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tool.isEmpty else {
            return
        }
        let dayKey = clock.dayKey(fromMillis: millis)
        let state = object["state"] as? [String: Any]
        classify(tool: tool, state: state, dayKey: dayKey, into: &accumulator)
    }

    private func classify(
        tool: String,
        state: [String: Any]?,
        dayKey: String,
        into accumulator: inout CallEventAccumulator
    ) {
        let lower = tool.lowercased()
        // OpenCode 每条 tool part 自带 status 与 time，故成功率/耗时对所有类别（MCP/技能/工具）通用。
        let success = Self.outcome(from: state)
        let durationMs = Self.durationMs(from: state)

        if lower == "skill" {
            let input = state?["input"] as? [String: Any]
            let raw = (input?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let skillName = raw.isEmpty ? "(unknown)" : raw
            accumulator.add(source: .opencode, kind: .skill, name: skillName, server: nil, dayKey: dayKey,
                            success: success, durationMs: durationMs)
            return
        }

        if Self.builtinTools.contains(lower) {
            let kind: CallKind = lower == "webfetch" ? .webSearch : .builtin
            accumulator.add(source: .opencode, kind: kind, name: tool, server: nil, dayKey: dayKey,
                            success: success, durationMs: durationMs)
            return
        }

        // 优先用已装 server 名做最长前缀匹配（server 名本身含 `_`/`-` 时切分才准），匹配不到再回退。
        if let match = matchKnownServer(tool: tool) {
            accumulator.add(
                source: .opencode,
                kind: .mcp,
                name: CallAnalyticsNaming.mcpDisplayName(server: match.server, tool: match.tool),
                server: match.server,
                dayKey: dayKey,
                success: success,
                durationMs: durationMs
            )
            return
        }

        // 回退启发式：OpenCode 把 MCP 工具命名为 `<server>_<tool>`；非内置且含下划线者归为 MCP。
        if let sep = tool.firstIndex(of: "_") {
            let server = String(tool[tool.startIndex..<sep])
            let toolName = String(tool[tool.index(after: sep)...])
            if !server.isEmpty, !toolName.isEmpty {
                accumulator.add(
                    source: .opencode,
                    kind: .mcp,
                    name: CallAnalyticsNaming.mcpDisplayName(server: server, tool: toolName),
                    server: server,
                    dayKey: dayKey,
                    success: success,
                    durationMs: durationMs
                )
                return
            }
        }

        accumulator.add(source: .opencode, kind: .other, name: tool, server: nil, dayKey: dayKey,
                        success: success, durationMs: durationMs)
    }

    /// 从 part.state 判定成功/失败：completed→成功，error→失败，其余（pending/running 等）→nil（不计入分母）。
    private static func outcome(from state: [String: Any]?) -> Bool? {
        guard let status = (state?["status"] as? String)?.lowercased() else { return nil }
        switch status {
        case "completed": return true
        case "error": return false
        default: return nil
        }
    }

    /// 从 part.state.time.{start,end}（毫秒时间戳）算耗时；缺失或非法返回 nil。
    private static func durationMs(from state: [String: Any]?) -> Double? {
        guard let time = state?["time"] as? [String: Any],
              let start = (time["start"] as? NSNumber)?.doubleValue,
              let end = (time["end"] as? NSNumber)?.doubleValue,
              end >= start else { return nil }
        return end - start
    }

    /// 在已装 server 名里找能作为 `tool` 前缀的最长者（`<server>_<tool>`）。
    /// 同时尝试把 server 名的 `-` 归一为 `_` 比较，兼容工具命名替换连字符的情况；
    /// 返回的 server 用配置原名，保证与零调用清单对得上。
    private func matchKnownServer(tool: String) -> (server: String, tool: String)? {
        guard !knownMCPServers.isEmpty else { return nil }
        for server in knownMCPServers.sorted(by: { $0.count > $1.count }) {
            for candidate in [server, server.replacingOccurrences(of: "-", with: "_")] {
                let prefix = candidate + "_"
                if tool.hasPrefix(prefix) {
                    let toolName = String(tool.dropFirst(prefix.count))
                    if !toolName.isEmpty { return (server, toolName) }
                }
            }
        }
        return nil
    }

    // MARK: - Discovery + snapshot

    /// 来源变化检测与实际读取共用目录优先级，避免监测一个数据库却解析另一个。
    func resolveDataDirectory() -> String? {
        var candidates: [String] = []
        if let xdg = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !xdg.isEmpty {
            candidates.append((xdg as NSString).appendingPathComponent("opencode"))
        }
        candidates.append((homeDirectory as NSString).appendingPathComponent(".local/share/opencode"))
        candidates.append((homeDirectory as NSString).appendingPathComponent("Library/Application Support/opencode"))

        return candidates.first { directory in
            FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(Self.databaseFilename))
        }
    }

    private func forEachToolPart(
        databasePath: String,
        sinceMillis: Int64?,
        onRow: (Int64, Data) -> Void
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {

            sqlite3_close(db)
            throw CallAnalyticsReadError.database
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        var sql = "SELECT time_created, data FROM part WHERE 1 = 1"
        if sinceMillis != nil {
            sql += " AND time_created >= ?"
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {

            throw CallAnalyticsReadError.database
        }
        defer { sqlite3_finalize(statement) }

        if let sinceMillis {
            sqlite3_bind_int64(statement, 1, sinceMillis)
        }

        while true {
            try Task.checkCancellation()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {

                throw CallAnalyticsReadError.database
            }
            guard let dataCString = sqlite3_column_text(statement, 1) else { continue }
            // 单行上限与 JSONL 一致；异常巨大的工具输出不能耗尽分析进程内存。
            guard sqlite3_column_bytes(statement, 1) <= 4 * 1024 * 1024 else { throw CallAnalyticsReadError.database }
            let millis = sqlite3_column_int64(statement, 0)
            onRow(millis, Data(String(cString: dataCString).utf8))
        }

    }
}
