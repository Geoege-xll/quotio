// Copyright 2026 AIUsage contributors
// SPDX-License-Identifier: Apache-2.0
// 参考 AIUsage CodexCostProvider 的累计差额和 fork 继承扣除，适配 Quotio 独立客户端 Token 账本。
// 只保留用量元数据；不保留提示词、工具参数、工作目录、provider 凭据或原始 JSON 行。
import Foundation
import CryptoKit
import CoreFoundation

nonisolated struct CodexClientUsageSource {
    let homeDirectory: String
    let environment: [String: String]

    private struct Totals: Hashable {
        var input = 0
        var output = 0
        var cached = 0
        var reasoning = 0
        var total = 0
        static let zero = Totals()
        var fingerprint: String { "\(input):\(output):\(cached):\(reasoning):\(total)" }
        var hasUsage: Bool { total > 0 || input > 0 || output > 0 }
        func subtracting(_ old: Totals) -> Totals {
            Totals(input: max(0, input - old.input), output: max(0, output - old.output),
                cached: max(0, cached - old.cached), reasoning: max(0, reasoning - old.reasoning), total: max(0, total - old.total))
        }
        func adding(_ other: Totals) -> Totals {
            Totals(input: input + other.input, output: output + other.output, cached: cached + other.cached,
                reasoning: reasoning + other.reasoning, total: total + other.total)
        }
    }

    private struct Event {
        let timestamp: Date
        let model: String
        let cumulative: Totals?
        let last: Totals?
        let ordinal: Int
        var checkpoint: CodexUsageCheckpoint? = nil
        /// 稳定身份只使用时间与用量值，不使用原始日志/参数；累计事件不因 last 字段补全而变成新事件。
        var key: String {
            "\(timestamp.timeIntervalSince1970):\(cumulative == nil ? "last" : "total"):\((cumulative ?? last ?? .zero).fingerprint)"
        }
    }

    private struct Session {
        var id: String
        var parent: String?
        var forkDate: Date?
        var events: [Event] = []
        var hasErrors = false
    }

    /// cacheURL 只供首次导入旧索引；生产 actor 传入 SQL store，只恢复小型文件水位。
    /// 永久账本投影与扫描检查点职责独立，但统一在一份数据库内持久化。
    func collect(cacheURL: URL? = nil, cacheStore: ClientUsageSQLiteStore? = nil, progress: ClientUsageProgressHandler? = nil,
                 projectRecords: Bool = true, incremental: Bool = false) throws -> ClientUsageScan {
        try Task.checkCancellation()
        let persistence = cacheStore ?? ClientUsageSQLiteStore.forCache(cacheURL)
        let writesIncrementally = incremental && persistence != nil
        var fileCaches = try persistence?.loadCodexCaches(legacyURL: cacheURL, includeCheckpoints: !writesIncrementally) ?? [:]
        let configured = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let codexHome = configured.flatMap { $0.isEmpty ? nil : $0 } ?? homeDirectory + "/.codex"
        var scan = ClientUsageScan(source: .codex)
        var paths = Set<String>()
        for root in [codexHome + "/sessions", codexHome + "/archived_sessions"] where FileManager.default.fileExists(atPath: root) {
            scan.available = true
            do { paths.formUnion(try ClientUsageFiles.jsonlFiles(roots: [root])) }
            catch is CancellationError { throw CancellationError() }
            catch { scan.hasErrors = true }
        }
        var state = ClientUsageProgress(source: .codex, filesTotal: paths.count)
        var files: [(String, CodexUsageFileStamp)] = []
        var consumedCacheKeys = Set<String>()
        for path in paths.sorted() {
            try Task.checkCancellation()
            do { let stamp = try CodexUsageFileStamp(path: path); files.append((path, stamp)); state.bytesTotal += stamp.size }
            catch { scan.hasErrors = true }
        }
        progress?(state)
        var lastProgressAt = ProcessInfo.processInfo.systemUptime
        for (path, stamp) in files {
            try Task.checkCancellation()
            scan.filesScanned += 1
            func readBytes(_ count: Int64) {
                state.bytesRead += count
                let now = ProcessInfo.processInfo.systemUptime
                // 大文件最多每秒四次字节进度，避免后台块读取制造成千上万个主线程更新任务。
                if now - lastProgressAt >= 0.25 { progress?(state); lastProgressAt = now }
            }
            do {
                let fileKey = CodexUsageFileCache.key(path: path)
                let cached = fileCaches[fileKey]
                if let cached, cached.version == 2, !cached.hasErrors, cached.stamp == stamp {
                    if !writesIncrementally { scan.codexCheckpoints.append(contentsOf: cached.checkpoints) }
                    scan.hasErrors = scan.hasErrors || cached.hasErrors
                    state.filesReused += 1
                    consumedCacheKeys.insert(fileKey)
                } else {
                    var seed: (CodexUsageFileCache, Session)?
                    if let cached, cached.version == 2, !cached.hasErrors,
                       stamp.mayAppend(to: cached.stamp), cached.foundMetadata {
                        let prefix = try CodexUsageLineReader.sample(path: path, offset: 0, count: Int(min(cached.stamp.size, 65_536)), progress: readBytes)
                        let boundaryStart = max(0, cached.offset - 4096)
                        let boundary = try CodexUsageLineReader.sample(path: path, offset: boundaryStart, count: Int(cached.offset - boundaryStart), progress: readBytes)
                        if ClientUsageDigest.sha256(prefix) == cached.prefixHash,
                           ClientUsageDigest.sha256(boundary) == cached.boundaryHash,
                           let header = headerSession(prefix), ClientUsageDigest.sha256(header.id) == cached.hashedSessionID {
                            seed = (cached, header)
                        }
                    }
                    let parsed = try parse(path: path, limit: stamp.size, seed: seed,
                        acceptFinalLine: persistence == nil, progress: readBytes)
                    // 原始采集保留旧数组的并集；生产增量的 cached 不含检查点，
                    // 旧历史由 SQL 的合并写入保留，文件截断也无需全部解码到内存。
                    var checkpointMap = Dictionary((cached?.checkpoints ?? []).map { ($0.id, $0) },
                        uniquingKeysWith: { $0.merging($1) })
                    for event in parsed.session.events {
                        try Task.checkCancellation()
                        let checkpoint = CodexUsageCheckpoint(rawSessionID: parsed.session.id, rawParentSessionID: parsed.session.parent,
                            timestamp: event.timestamp, forkDate: parsed.session.parent == nil ? nil : parsed.session.forkDate, model: event.model,
                            cumulative: event.cumulative.map(Self.checkpointTokens), last: event.last.map(Self.checkpointTokens),
                            ordinal: event.ordinal, hasErrors: parsed.session.hasErrors)
                        checkpointMap[checkpoint.id] = checkpointMap[checkpoint.id]?.merging(checkpoint) ?? checkpoint
                    }
                    let checkpoints = checkpointMap.values.sorted { $0.id < $1.id }
                    if !writesIncrementally { scan.codexCheckpoints.append(contentsOf: checkpoints) }
                    consumedCacheKeys.insert(fileKey)
                    scan.hasErrors = scan.hasErrors || parsed.session.hasErrors
                    if let persistence {
                        let prefix = try CodexUsageLineReader.sample(path: path, offset: 0, count: Int(min(stamp.size, 65_536)), progress: readBytes)
                        let boundaryStart = max(0, parsed.offset - 4096)
                        let boundary = try CodexUsageLineReader.sample(path: path, offset: boundaryStart, count: Int(parsed.offset - boundaryStart), progress: readBytes)
                        let value = CodexUsageFileCache(stamp: stamp, offset: parsed.offset, ordinal: parsed.ordinal,
                            model: String(parsed.model.prefix(512)), hashedSessionID: ClientUsageDigest.sha256(parsed.session.id),
                            foundMetadata: parsed.foundMetadata, hasErrors: parsed.session.hasErrors,
                            prefixHash: ClientUsageDigest.sha256(prefix), boundaryHash: ClientUsageDigest.sha256(boundary), checkpoints: checkpoints)
                        // 每个文件的检查点与水位同事务保存，取消后可以复用已完成大文件。
                        if writesIncrementally {
                            try persistence.saveCodexIncrement(value, key: fileKey)
                            fileCaches[fileKey] = value.withoutCheckpoints
                        } else {
                            try persistence.saveCodexCache(value, key: fileKey)
                            fileCaches[fileKey] = value
                        }
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { scan.hasErrors = true }
            state.filesCompleted += 1
            progress?(state)
            lastProgressAt = ProcessInfo.processInfo.systemUptime
        }
        // 数据库保留源文件消失后的已解析输入，取消到下一次账本投影之间不会丢历史。
        for (key, cached) in fileCaches where !consumedCacheKeys.contains(key) {
            try Task.checkCancellation()
            if !writesIncrementally { scan.codexCheckpoints.append(contentsOf: cached.checkpoints) }
            // 已消失文件的统计检查点仍保留在账本，但其旧读取失败不属于本轮读取结果。
            // 相关检查点的证据不足仍由历史投影状态表达；当前文件失败由上面的实际读取捕获。
        }
        scan.codexReadErrors = scan.hasErrors
        if projectRecords && !writesIncrementally {
            let result = Self.project(checkpoints: scan.codexCheckpoints)
            try Task.checkCancellation()
            scan.records = result.records
            scan.hasErrors = scan.hasErrors || result.hasErrors
        }
        try Task.checkCancellation()
        return scan
    }

    /// 追加扫描重读一个小文件头取得原始身份，只驻留内存，以保持旧记录 ID 的散列公式不变。
    /// 超大/非标准头无法在窗口内证实时返回 nil，安全回退全文件扫描。
    private func headerSession(_ data: Data) -> Session? {
        let clock = CallAnalyticsClock(timeZone: .current)
        for line in data.split(separator: 10) {
            guard line.range(of: Data("\"session_meta\"".utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any],
                  let id = firstString(payload["id"], payload["session_id"], payload["sessionId"], object["session_id"], object["id"]) else { continue }
            return Session(id: id,
                parent: firstString(payload["forked_from_id"], payload["forkedFromId"], payload["parent_session_id"], payload["parentSessionId"]),
                forkDate: firstString(payload["timestamp"], object["timestamp"]).flatMap(clock.date(fromISO:)))
        }
        return nil
    }

    /// 输入包含目标会话及其父基线；只输出指定会话，允许迟到历史使旧差额下降。
    /// 原始采集未传 outputSessionIDs 时仍返回完整投影，兼容既有解析测试。
    static func project(checkpoints: [CodexUsageCheckpoint], outputSessionIDs: Set<String>? = nil) -> (records: [ClientUsageRecord], hasErrors: Bool) {
        var scan = ClientUsageScan(source: .codex)
        var sessions: [String: Session] = [:]
        for checkpoint in checkpoints {
            if Task.isCancelled { return ([], true) }
            var session = sessions.removeValue(forKey: checkpoint.sessionID) ?? Session(id: checkpoint.sessionID)
            if session.parent == nil { session.parent = checkpoint.parentSessionID; session.forkDate = checkpoint.forkDate }
            else if let parent = checkpoint.parentSessionID, parent != session.parent { session.hasErrors = true }
            else if session.forkDate == nil { session.forkDate = checkpoint.forkDate }
            session.hasErrors = session.hasErrors || checkpoint.hasErrors
            session.events.append(Event(timestamp: checkpoint.timestamp, model: checkpoint.model,
                cumulative: checkpoint.cumulative.map(totals), last: checkpoint.last.map(totals),
                ordinal: checkpoint.ordinal, checkpoint: checkpoint))
            sessions[session.id] = session
        }
        // 先去重并排序，再建立父会话在分叉时间点的原始累计量索引；索引不写磁盘。
        var timelines: [String: [(Date, Totals)]] = [:]
        for id in sessions.keys.sorted() {
            if Task.isCancelled { return ([], true) }
            guard var session = sessions[id] else { continue }
            var unique: [String: Event] = [:]
            for event in session.events {
                if Task.isCancelled { return ([], true) }
                if let old = unique[event.key] {
                    let oldScore = (old.model == "unknown" ? 0 : 1) + (old.last == nil ? 0 : 2)
                    let newScore = (event.model == "unknown" ? 0 : 1) + (event.last == nil ? 0 : 2)
                    if oldScore >= newScore { continue }
                }
                unique[event.key] = event
            }
            // 同一 token_count 的 last-only 版本可能随后补齐 total；只有时间、模型与显式 last 值匹配才消除重复。
            // 其它同时间事件保留，不能把毫秒级并发的不同调用全部合并。
            let byTime = Dictionary(grouping: Array(unique.values), by: \.timestamp)
            var normalized: [Event] = []
            for group in byTime.values {
                if Task.isCancelled { return ([], true) }
                // 将同时间补全关系建立为哈希集合，避免大量同毫秒事件形成两层全量匹配。
                struct LastModel: Hashable { let totals: Totals; let model: String }
                var knownMatches = Set<LastModel>(), unknownMatches = Set<Totals>(), allLast = Set<Totals>()
                var hasCumulative = false
                for event in group where event.cumulative != nil {
                    hasCumulative = true
                    if let last = event.last {
                        allLast.insert(last)
                        if event.model == "unknown" { unknownMatches.insert(last) }
                        else { knownMatches.insert(LastModel(totals: last, model: event.model)) }
                    }
                }
                for event in group {
                    if Task.isCancelled { return ([], true) }
                    if event.cumulative == nil, let last = event.last, hasCumulative {
                        if unknownMatches.contains(last) || knownMatches.contains(LastModel(totals: last, model: event.model))
                            || (event.model == "unknown" && allLast.contains(last)) { continue }
                        // 缺少明确匹配关系时保持部分状态，并先处理 last 再由累计收敛，避免无证据多加一次。
                        session.hasErrors = true
                    }
                    normalized.append(event)
                }
            }
            session.events = normalized.sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                if ($0.cumulative == nil) != ($1.cumulative == nil) { return $0.cumulative == nil }
                if let left = $0.cumulative, let right = $1.cumulative, left.total != right.total { return left.total < right.total }
                return $0.ordinal == $1.ordinal ? $0.key < $1.key : $0.ordinal < $1.ordinal
            }
            sessions[id] = session
            var current = Totals.zero
            for event in session.events {
                current = event.cumulative ?? current.adding(event.last ?? .zero)
                timelines[id, default: []].append((event.timestamp, current))
            }
        }

        for id in sessions.keys.sorted() {
            if Task.isCancelled { return ([], true) }
            guard outputSessionIDs?.contains(id) != false else { continue }
            guard let session = sessions[id] else { continue }
            scan.hasErrors = scan.hasErrors || session.hasErrors
            var inherited: Totals?
            var unresolvedFork = false
            if let parent = session.parent {
                if let cutoff = session.forkDate, let parentTimeline = timelines[parent] {
                    // 时间线已排序，以二分替代每个 fork 扫描整条父历史。
                    var lower = 0, upper = parentTimeline.count
                    while lower < upper {
                        let middle = lower + (upper - lower) / 2
                        if parentTimeline[middle].0 <= cutoff { lower = middle + 1 } else { upper = middle }
                    }
                    if lower > 0 { inherited = parentTimeline[lower - 1].1 }
                }
                if inherited == nil { unresolvedFork = true; scan.hasErrors = true }
            }
            var previous = inherited ?? .zero
            var remainingInherited = inherited
            var seenAny = false
            for event in session.events {
                if Task.isCancelled { return ([], true) }
                // 子会话复制的分叉前历史属于父会话；不能再次产生客户端账单。
                if let fork = session.forkDate, session.parent != nil, event.timestamp < fork { continue }
                let delta: Totals
                if let totals = event.cumulative {
                    if unresolvedFork && !seenAny {
                        // 父日志缺失时无法知道首次累计包含多少继承量，只建立基线；之后可证明的增量仍可统计。
                        previous = totals; seenAny = true; remainingInherited = nil
                        continue
                    }
                    if totals.total < previous.total || totals.input < previous.input || totals.output < previous.output {
                        // 同 session 的新 rollout/压缩可能重置计数。首次 fork 回落无法证明继承口径，保守以 last 为依据。
                        if inherited != nil && !seenAny {
                            scan.hasErrors = true
                            delta = event.last ?? .zero
                        } else {
                            if event.last == nil { scan.hasErrors = true }
                            delta = event.last ?? totals
                        }
                    } else { delta = totals.subtracting(previous) }
                    previous = totals
                    remainingInherited = nil
                } else if let last = event.last {
                    // 没有累计量时使用 last；进入累计路径后 previous 已包含这些 last，后续不会再次计入。
                    if unresolvedFork && !seenAny {
                        // 无父基线的首条 last 也可能来自继承历史；先保守建立基线并维持部分状态。
                        previous = last; seenAny = true; continue
                    }
                    if let remaining = remainingInherited {
                        delta = last.subtracting(remaining)
                        let rest = remaining.subtracting(last)
                        remainingInherited = rest.hasUsage ? rest : nil
                        // previous 已经包含父累计量，只添加扣除后的增量，不能再把继承量加第二遍。
                        previous = previous.adding(delta)
                    } else { delta = last; previous = previous.adding(last) }
                } else { continue }
                seenAny = true
                guard delta.hasUsage else { continue }
                guard let checkpoint = event.checkpoint else { scan.hasErrors = true; continue }
                scan.records.append(ClientUsageRecord(checkpoint: checkpoint, input: delta.input, output: delta.output,
                    cached: min(delta.cached, delta.input), reasoning: min(delta.reasoning, delta.output), total: delta.total))
            }
        }
        scan.records.sort { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        return (scan.records, scan.hasErrors)
    }

    private static func checkpointTokens(_ value: Totals) -> CodexUsageCheckpoint.Tokens {
        .init(input: value.input, output: value.output, cached: value.cached, reasoning: value.reasoning, total: value.total)
    }
    private static func totals(_ value: CodexUsageCheckpoint.Tokens) -> Totals {
        .init(input: value.input, output: value.output, cached: value.cached, reasoning: value.reasoning, total: value.total)
    }

    private struct ParsedFile {
        let session: Session; let offset: Int64; let ordinal: Int; let model: String; let foundMetadata: Bool
    }
    private func parse(path: String, limit: Int64, seed: (CodexUsageFileCache, Session)?,
                       acceptFinalLine: Bool, progress: (Int64) -> Void) throws -> ParsedFile {
        let clock = CallAnalyticsClock(timeZone: .current)
        // 缺少 session_meta 时使用文件名散列隔离会话，同时标注不完整；不会把完整路径写进记录。
        let fallback = ClientUsageDigest.sha256(URL(fileURLWithPath: path).lastPathComponent)
        var session = seed?.1 ?? Session(id: fallback)
        session.hasErrors = seed?.0.hasErrors ?? false
        var foundMetadata = seed?.0.foundMetadata ?? false
        var currentModel = seed?.0.model ?? "unknown"
        var ordinal = seed?.0.ordinal ?? 0
        let read = try CodexUsageLineReader.read(path: path, offset: seed?.0.offset ?? 0, limit: limit,
            acceptFinalLine: acceptFinalLine, progress: progress,
            isIrrelevantLine: { CodexLogEnvelope.isIrrelevantToUsage($0) }) { line in
            ordinal += 1
            // 读取器已按顶层类型过滤正文，不能再搜索正文里的 token_count 字样判断事件。
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = object["type"] as? String else {
                session.hasErrors = true; return
            }
            let payload = object["payload"] as? [String: Any] ?? [:]
            if type == "session_meta" {
                // fork rollout 的首条元数据描述子会话，随后可能复制父会话的 session_meta。
                // 首条身份和分叉关系为准，继承头既不是身份冲突，也不能清除子会话 parent。
                guard !foundMetadata else { return }
                if let id = firstString(payload["id"], payload["session_id"], payload["sessionId"], object["session_id"], object["id"]) {
                    session.id = id; foundMetadata = true
                }
                session.parent = firstString(payload["forked_from_id"], payload["forkedFromId"], payload["parent_session_id"], payload["parentSessionId"])
                session.forkDate = firstString(payload["timestamp"], object["timestamp"]).flatMap(clock.date(fromISO:))
                currentModel = firstString(payload["model"], payload["model_name"]) ?? currentModel
                return
            }
            if type == "turn_context" {
                currentModel = firstString(payload["model"], payload["model_name"]) ?? currentModel
                return
            }
            guard type == "event_msg", payload["type"] as? String == "token_count" else { return }
            // info:null 是正常的限额广播，并不代表新用量。
            guard let info = payload["info"] as? [String: Any] else { return }
            guard let timestamp = firstString(object["timestamp"]).flatMap(clock.date(fromISO:)) else { session.hasErrors = true; return }
            var invalid = false
            let cumulative = parseTotals(info["total_token_usage"], invalid: &invalid)
            let last = parseTotals(info["last_token_usage"], invalid: &invalid)
            if invalid { session.hasErrors = true; return }
            guard cumulative != nil || last != nil else { return }
            let model = firstString(info["model"], info["model_name"], payload["model"], payload["model_name"]) ?? currentModel
            session.events.append(Event(timestamp: timestamp, model: model, cumulative: cumulative, last: last, ordinal: ordinal))
        }
        session.hasErrors = session.hasErrors || !foundMetadata || read.oversized
        return ParsedFile(session: session, offset: read.offset, ordinal: ordinal, model: currentModel, foundMetadata: foundMetadata)
    }

    /// 非法数值不能悄悄转成零；缓存/推理作为输入/输出子集归一，不再次累加到总Token。
    private func parseTotals(_ raw: Any?, invalid: inout Bool) -> Totals? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let object = raw as? [String: Any], object["input_tokens"] != nil, object["output_tokens"] != nil else { invalid = true; return nil }
        func value(_ key: String) -> Int {
            guard let raw = object[key] else { return 0 }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue >= 0, number.doubleValue <= 1_000_000_000_000,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue else { invalid = true; return 0 }
            return Int(number.doubleValue)
        }
        let input = value("input_tokens"), output = value("output_tokens")
        let cached = object["cached_input_tokens"] == nil ? value("cache_read_input_tokens") : value("cached_input_tokens")
        let reasoning = value("reasoning_output_tokens")
        let total = object["total_tokens"] == nil ? input + output : value("total_tokens")
        return Totals(input: input, output: output, cached: min(cached, input), reasoning: min(reasoning, output), total: total)
    }

    private func firstString(_ values: Any?...) -> String? {
        values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }
}
