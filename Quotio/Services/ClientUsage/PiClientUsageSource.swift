import Foundation
import CoreFoundation

/// Pi 的默认会话目录来自官方 getSessionsDir；显式环境目录同时纳入扫描。
/// 不扫描整个 home，也不读取 auth.json，避免为了发现日志扩大隐私访问范围。
nonisolated enum PiSessionPaths {
    static func expand(_ path: String, homeDirectory: String) -> String {
        let expanded = path == "~" ? homeDirectory
            : (path.hasPrefix("~/") ? homeDirectory + String(path.dropFirst()) : path)
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: homeDirectory, isDirectory: true))
            .standardizedFileURL.path
    }

    static func agentDirectory(homeDirectory: String, environment: [String: String]) -> String {
        let value = environment["PI_CODING_AGENT_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return expand(value.isEmpty ? homeDirectory + "/.pi/agent" : value, homeDirectory: homeDirectory)
    }

    static func sessionRoots(homeDirectory: String, environment: [String: String]) -> [String] {
        var roots = [agentDirectory(homeDirectory: homeDirectory, environment: environment) + "/sessions"]
        if let value = environment["PI_CODING_AGENT_SESSION_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            roots.append(expand(value, homeDirectory: homeDirectory))
        }
        return Array(Set(roots)).sorted()
    }

    /// 新版 Pi 消息时间为毫秒，条目时间为 ISO8601。优先采用条目时间，缺失时才读取消息时间。
    static func timestamp(entry: [String: Any], message: [String: Any]?, clock: CallAnalyticsClock) -> Date? {
        if let value = entry["timestamp"] as? String, let date = clock.date(fromISO: value) { return date }
        // 时间戳与 Token 数量使用不同量纲；现代毫秒时间已经超过 Token 校验器的上限。
        guard let raw = message?["timestamp"] as? NSNumber,
              CFGetTypeID(raw) != CFBooleanGetTypeID() else { return nil }
        let milliseconds = raw.doubleValue
        guard milliseconds.isFinite, milliseconds > 0,
              milliseconds <= Date.distantFuture.timeIntervalSince1970 * 1000 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

/// 按 Pi 原始 Usage 协议归一化：input 不含 cacheRead/cacheWrite，output 已包含 reasoning。
/// 缓存只保存散列身份和 Token 投影，复用已有只读增量读取器的文件指纹与原子缓存机制。
nonisolated struct PiClientUsageSource {
    let homeDirectory: String
    let environment: [String: String]

    func collect(cacheURL: URL? = nil, cacheStore: ClientUsageSQLiteStore? = nil,
                 progress: ClientUsageProgressHandler? = nil, incremental: Bool = false) throws -> ClientUsageScan {
        let persistence = cacheStore ?? ClientUsageSQLiteStore.forCache(cacheURL)
        let writesIncrementally = incremental && persistence != nil
        var cache = try persistence?.loadLineCache(source: .pi, legacyURL: cacheURL, includeRecords: !writesIncrementally) ?? ClaudeClientUsageReader.Cache()
        var scan = ClientUsageScan(source: .pi)
        var state = ClientUsageProgress(source: .pi)
        var lastProgress = Date.distantPast
        func report(force: Bool = false) {
            if force || Date().timeIntervalSince(lastProgress) >= 0.1 { progress?(state); lastProgress = Date() }
        }
        var paths = Set<String>()
        for root in PiSessionPaths.sessionRoots(homeDirectory: homeDirectory, environment: environment)
            where FileManager.default.fileExists(atPath: root) {
            scan.available = true
            do { paths.formUnion(try ClientUsageFiles.jsonlFiles(roots: [root])) }
            catch is CancellationError { throw CancellationError() }
            catch { scan.hasErrors = true }
        }
        let files = paths.sorted()
        state.filesTotal = files.count
        let clock = CallAnalyticsClock(timeZone: .current)
        report(force: true)
        for path in files {
            try Task.checkCancellation()
            let key = ClaudeClientUsageReader.key(for: path)
            do {
                let fingerprint = try ClaudeClientUsageReader.fingerprint(path: path)
                let previous = cache.files[key]
                if let previous, previous.fingerprint == fingerprint, !previous.hasErrors, !previous.tailHasErrors {
                    state.filesReused += 1
                } else {
                    // 错误文件从头重建，避免修复 JSON 后旧错误标记永久残留。
                    let reusable = previous?.hasErrors == false ? previous : nil
                    var entry = try ClaudeClientUsageReader.read(path: path, previous: reusable, bytesRead: { count in
                        state.bytesRead += count
                        state.bytesTotal = max(state.bytesTotal, state.bytesRead)
                        report()
                    }, parse: { Self.parse($0, clock: clock) })
                    if writesIncrementally, let persistence {
                        // 只在当前文件解析期间持有新增记录，持久化后只留下可追加读取的水位。
                        try persistence.saveLineIncrement(entry, source: .pi, key: key)
                        entry.records = []
                    }
                    cache.files[key] = entry
                }
                if let entry = cache.files[key] { scan.hasErrors = scan.hasErrors || entry.hasErrors || entry.tailHasErrors }
                scan.filesScanned += 1
            } catch is CancellationError { throw CancellationError() }
            catch { scan.hasErrors = true }
            state.filesCompleted += 1
            report()
        }
        try Task.checkCancellation()
        // Pi 与 Claude 共用按文件的关系型索引，各自使用来源命名空间，避免混合记录。
        if writesIncrementally { report(force: true); try Task.checkCancellation(); return scan }
        try persistence?.saveLineCache(cache, source: .pi)
        // Pi 导出分支会复制原条目 ID 和时间，不能按文件名或新会话 ID 重复累计。
        var records: [String: ClientUsageRecord] = [:]
        for entry in cache.files.values {
            for record in entry.records where record.source == .pi {
                if records[record.id].map({ $0.total <= record.total }) ?? true { records[record.id] = record }
            }
        }
        scan.records = records.values.sorted { $0.id < $1.id }
        report(force: true)
        return scan
    }

    static func parse(_ line: Data, clock: CallAnalyticsClock) -> (record: ClientUsageRecord?, hasErrors: Bool) {
        let entry: [String: Any]
        do {
            guard let decoded = try PiSessionEntry.decode(line) else { return (nil, false) }
            entry = decoded
        } catch { return (nil, true) }
        guard let type = entry["type"] as? String else { return (nil, true) }
        let message = entry["message"] as? [String: Any]
        let usage: [String: Any]?
        if type == "message", message?["role"] as? String == "assistant" {
            usage = message?["usage"] as? [String: Any]
        } else if type == "compaction" || type == "branch_summary" {
            // 新版 Pi 会为压缩/分支摘要附带额外模型消耗；没有模型字段时如实归为 unknown。
            usage = entry["usage"] as? [String: Any]
        } else { return (nil, false) }
        guard let usage else { return (nil, false) }
        guard let id = entry["id"] as? String, !id.isEmpty,
              let date = PiSessionPaths.timestamp(entry: entry, message: message, clock: clock),
              usage["input"] != nil, usage["output"] != nil,
              let input = ClientUsageFiles.validatedNumber(usage["input"]),
              let output = ClientUsageFiles.validatedNumber(usage["output"]),
              let read = ClientUsageFiles.validatedNumber(usage["cacheRead"]),
              let write = ClientUsageFiles.validatedNumber(usage["cacheWrite"]),
              let reasoning = ClientUsageFiles.validatedNumber(usage["reasoning"]) else { return (nil, true) }
        let normalizedInput = input + read + write
        guard normalizedInput <= 1_000_000_000_000, reasoning <= output else { return (nil, true) }
        let total: Int
        if let rawTotal = usage["totalTokens"] {
            guard let parsed = ClientUsageFiles.validatedNumber(rawTotal) else { return (nil, true) }
            total = parsed
        } else { total = normalizedInput + output }
        guard total > 0 || normalizedInput > 0 || output > 0 else { return (nil, false) }
        let model = message?["model"] as? String ?? "unknown"
        let provider = message?["provider"] as? String ?? ""
        let identity = "\(type):\(id):\(date.timeIntervalSince1970):\(provider):\(model)"
        return (ClientUsageRecord(identity: identity, source: .pi, timestamp: date, model: model,
                                  input: normalizedInput, output: output, cached: read + write,
                                  reasoning: reasoning, total: total,
                                  hasReasoningBreakdown: usage["reasoning"] != nil), false)
    }
}
