import Foundation

/// Claude Code 的本地 assistant 消息带实际 usage；来源由 .claude/projects 确认，
/// 不依赖模型名。消息分块、重试和复制到其它会话文件不能重复累计同一 message.id。
nonisolated struct ClaudeClientUsageSource {
    let homeDirectory: String
    let environment: [String: String]

    func collect(cacheURL: URL? = nil, cacheStore: ClientUsageSQLiteStore? = nil,
                 progress: ClientUsageProgressHandler? = nil, incremental: Bool = false) throws -> ClientUsageScan {
        try Task.checkCancellation()
        let persistence = cacheStore ?? ClientUsageSQLiteStore.forCache(cacheURL)
        let writesIncrementally = incremental && persistence != nil
        var cache = try persistence?.loadLineCache(source: .claude, legacyURL: cacheURL, includeRecords: !writesIncrementally) ?? ClaudeClientUsageReader.Cache()
        let configured = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = (configured?.isEmpty == false ? configured! : homeDirectory + "/.claude") + "/projects"
        var scan = ClientUsageScan(source: .claude)
        var state = ClientUsageProgress(source: .claude)
        var lastProgress = Date.distantPast
        func report(force: Bool = false) {
            let now = Date()
            if force || now.timeIntervalSince(lastProgress) >= 0.1 { progress?(state); lastProgress = now }
        }
        // 每次重放全部脱敏记录：即使上轮索引已提交、永久账本尚未提交便退出，也不会丢失用量。
        func replay() {
            // 生产只发布来源状态；持久化 dirty scope 在取消、退出后仍能恢复未完成投影。
            guard !writesIncrementally else { return }
            var messages: [String: ClientUsageRecord] = [:]
            for entry in cache.files.values {
                for record in entry.records where messages[record.id].map({ $0.total <= record.total }) ?? true {
                    messages[record.id] = record
                }
            }
            scan.records = messages.values.sorted { $0.id < $1.id }
        }
        guard FileManager.default.fileExists(atPath: root) else { replay(); report(force: true); return scan }
        scan.available = true
        let files: [String]
        do { files = try ClientUsageFiles.jsonlFiles(roots: [root]) }
        catch is CancellationError { throw CancellationError() }
        catch { scan.hasErrors = true; replay(); report(force: true); return scan }
        state.filesTotal = files.count
        var fingerprints: [String: ClaudeClientUsageReader.Fingerprint] = [:]
        for path in files {
            try Task.checkCancellation()
            if let value = try? ClaudeClientUsageReader.fingerprint(path: path) {
                fingerprints[path] = value
                let previous = cache.files[ClaudeClientUsageReader.key(for: path)]
                if previous?.fingerprint != value {
                    let appending = previous?.fingerprint.canAppend(to: value) == true
                    state.bytesTotal += value.size - (appending ? previous!.offset : 0)
                    // 变化文件额外读取有限的边界探针，进度如实计入这些物理读取字节。
                    state.bytesTotal += value.size <= 4096 ? value.size : 8192
                    if appending, let previous { state.bytesTotal += previous.fingerprint.size <= 4096 ? previous.fingerprint.size : 8192 }
                }
            }
        }
        report(force: true)
        let clock = CallAnalyticsClock(timeZone: .current)
        for path in files {
            try Task.checkCancellation()
            let key = ClaudeClientUsageReader.key(for: path)
            do {
                guard let fingerprint = fingerprints[path] else { throw CallAnalyticsReadError.unreadable }
                if let previous = cache.files[key], previous.fingerprint == fingerprint {
                    state.filesReused += 1
                } else {
                    var entry = try ClaudeClientUsageReader.read(path: path, previous: cache.files[key],
                        bytesRead: { amount in
                            let firstRead = state.bytesRead == 0 && amount > 0
                            state.bytesRead += amount; state.bytesTotal = max(state.bytesTotal, state.bytesRead)
                            report(force: firstRead)
                        },
                        parse: { data in parse(data, clock: clock) })
                    if writesIncrementally, let persistence {
                        // metadata seed 的 records 为空，读取器只构造本轮追加/重扫所得记录。
                        // 事实与游标同事务写入，随后立即释放数组，不等待其它文件完成。
                        try persistence.saveLineIncrement(entry, source: .claude, key: key)
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
        // 变化文件的游标与解析记录同事务提交；未变化缓存不再整份序列化或写盘。
        if !writesIncrementally { try persistence?.saveLineCache(cache, source: .claude) }
        replay(); report(force: true)
        // 最后一条进度也可能触发取消；只保留已提交批次，不再向上发布成功完成。
        try Task.checkCancellation()
        return scan
    }

    /// 只解析含 usage 的行，保留合法零值与非法字段的既有区别；原始 JSON 仅在这一轮内存中存在。
    private func parse(_ data: Data, clock: CallAnalyticsClock) -> (record: ClientUsageRecord?, hasErrors: Bool) {
        guard data.range(of: Data("\"usage\"".utf8)) != nil else { return (nil, false) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, true) }
        guard object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return (nil, false) }
        guard let id = message["id"] as? String, !id.isEmpty,
              let stamp = object["timestamp"] as? String,
              let timestamp = clock.date(fromISO: stamp) else { return (nil, true) }
        let keys = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
        guard keys.contains(where: { usage[$0] != nil }),
              let read = ClientUsageFiles.validatedNumber(usage["cache_read_input_tokens"]),
              let write = ClientUsageFiles.validatedNumber(usage["cache_creation_input_tokens"]),
              let uncached = ClientUsageFiles.validatedNumber(usage["input_tokens"]),
              let output = ClientUsageFiles.validatedNumber(usage["output_tokens"]) else { return (nil, true) }
        // Anthropic 的 input_tokens 不含缓存；归一为含缓存输入，页面才可跨客户端比较。
        let input = uncached + read + write
        guard input <= 1_000_000_000_000 else { return (nil, true) }
        guard input > 0 || output > 0 else { return (nil, false) }
        let model = message["model"] as? String ?? "unknown"
        guard model != "<synthetic>", model != "synthetic" else { return (nil, false) }
        return (ClientUsageRecord(identity: id, source: .claude, timestamp: timestamp,
                    model: model, input: input, output: output, cached: read + write), false)
    }
}
