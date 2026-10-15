import Foundation
import CryptoKit

/// CPA 队列的最小统计投影。账号来源和密钥仅转换为脱敏上下文，
/// 原始凭据、提示词、工具参数与错误正文不进入磁盘账本。
nonisolated struct UsageRecord: Codable, Sendable, Equatable, Identifiable {
    let timestamp: Date
    let provider: String
    let model: String
    let requestID: String?
    let failed: Bool
    let latencyMilliseconds: Double?
    let tokens: Tokens
    let context: CPAUsageContext?

    nonisolated struct Tokens: Codable, Sendable, Equatable {
        let input: Int
        let output: Int
        let reasoning: Int
        let cached: Int
        let total: Int
        enum CodingKeys: String, CodingKey {
            case input = "input_tokens", output = "output_tokens", reasoning = "reasoning_tokens"
            case cached = "cached_tokens", total = "total_tokens"
            case cacheRead = "cache_read_tokens", cacheCreation = "cache_creation_tokens", legacyCache = "cache_tokens"
        }
        init(input: Int = 0, output: Int = 0, reasoning: Int = 0, cached: Int = 0, total: Int? = nil) {
            // 单请求设置宽松上限，异常上游整数不能导致加法溢出而终止整个应用。
            let limit = 1_000_000_000_000
            self.input = min(limit, max(0, input)); self.output = min(limit, max(0, output))
            self.reasoning = min(limit, max(0, reasoning)); self.cached = min(limit, max(0, cached))
            // 缓存和推理通常是输入/输出的子集，不再相加，避免双计。
            self.total = min(2 * limit, max(0, total ?? (self.input + self.output)))
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // 上游同时保留缓存总量和读写分量：显式读取量优先，旧字段取最大值，
            // cached 不能因为出现较小的 cache_read_tokens 而丢掉已报告的缓存总量。
            let legacy = max(0, min(1_000_000_000_000,
                try max(c.decodeIfPresent(Int.self, forKey: .cached) ?? 0,
                        c.decodeIfPresent(Int.self, forKey: .legacyCache) ?? 0)))
            let read = max(0, min(1_000_000_000_000, try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? legacy))
            let write = max(0, min(1_000_000_000_000, try c.decodeIfPresent(Int.self, forKey: .cacheCreation) ?? 0))
            self.init(input: try c.decodeIfPresent(Int.self, forKey: .input) ?? 0,
                      output: try c.decodeIfPresent(Int.self, forKey: .output) ?? 0,
                      reasoning: try c.decodeIfPresent(Int.self, forKey: .reasoning) ?? 0,
                      cached: max(legacy, read + write),
                      total: try c.decodeIfPresent(Int.self, forKey: .total))
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(input, forKey: .input); try c.encode(output, forKey: .output)
            try c.encode(reasoning, forKey: .reasoning); try c.encode(cached, forKey: .cached)
            try c.encode(total, forKey: .total)
        }

        /// 参考 EasyCLIProxyAPI parse_usage_record：Claude 的原始输入可能不含缓存。
        /// 只在缓存量或总量提供证据时补入输入；已经归一的记录不能再次相加。
        func normalized(provider: String, executor: String, cacheComponents: Int) -> Self {
            let isClaude = executor.lowercased() == "claudeexecutor" || provider.lowercased() == "claude"
                || provider.lowercased().contains("anthropic")
            let rawTotal = input + output
            let excludesCache = isClaude && cacheComponents > 0 && (input < cacheComponents || total == rawTotal + cacheComponents)
            var normalizedInput = input
            if excludesCache { normalizedInput += cacheComponents }
            if cacheComponents > normalizedInput { normalizedInput += cacheComponents }
            let adjustedTotal = total == 0 || (normalizedInput != input && total == rawTotal)
                ? normalizedInput + output : total
            return Self(input: normalizedInput, output: output, reasoning: reasoning, cached: cached, total: adjustedTotal)
        }
    }
    enum CodingKeys: String, CodingKey {
        case timestamp, provider, model, failed, tokens, context
        case requestID = "request_id", latencyMilliseconds = "latency_ms"
        case executorType = "executor_type"
    }
    init(timestamp: Date, provider: String, model: String, requestID: String? = nil,
         failed: Bool = false, latencyMilliseconds: Double? = nil, tokens: Tokens = Tokens(), context: CPAUsageContext? = nil) {
        self.timestamp = timestamp; self.provider = provider; self.model = model
        self.requestID = requestID; self.failed = failed
        self.latencyMilliseconds = latencyMilliseconds; self.tokens = tokens
        self.context = context
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .timestamp)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else {
            throw DecodingError.dataCorruptedError(forKey: .timestamp, in: c, debugDescription: "Invalid usage timestamp")
        }
        let provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        let executor = try c.decodeIfPresent(String.self, forKey: .executorType) ?? ""
        let tokens = try c.decodeIfPresent(Tokens.self, forKey: .tokens) ?? Tokens()
        let failed = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        let context: CPAUsageContext?
        if c.contains(.context) {
            // 自己编码的归一化缓存不是原始缓存读取量，显式上下文可防止二次推断。
            let saved = try c.decodeIfPresent(CPAUsageContext.self, forKey: .context)
            context = saved == CPAUsageContext() ? nil : saved
        } else {
            context = try CPAUsageContext.read(from: decoder, failed: failed, tokens: tokens)
        }
        self.init(timestamp: date,
                  provider: provider,
                  model: try c.decodeIfPresent(String.self, forKey: .model) ?? "",
                  requestID: try c.decodeIfPresent(String.self, forKey: .requestID),
                  failed: failed,
                  latencyMilliseconds: try c.decodeIfPresent(Double.self, forKey: .latencyMilliseconds),
                  // 自己保存的记录已经归一化；只能用原始上报的缓存读写分量补齐输入，
                  // 不能再次拿含义更宽的 cached 总量参与计算。
                  tokens: c.contains(.context) ? tokens : tokens.normalized(provider: provider, executor: executor,
                    cacheComponents: (context?.cacheRead ?? 0) + (context?.cacheWrite ?? 0)), context: context)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try c.encode(f.string(from: timestamp), forKey: .timestamp)
        try c.encode(provider, forKey: .provider); try c.encode(model, forKey: .model)
        try c.encodeIfPresent(requestID, forKey: .requestID); try c.encode(failed, forKey: .failed)
        try c.encodeIfPresent(latencyMilliseconds, forKey: .latencyMilliseconds); try c.encode(tokens, forKey: .tokens)
        try c.encode(context ?? CPAUsageContext(), forKey: .context)
    }
    /// 有 request_id 才能证明是同一记录。缺 ID 时相同时间/模型/Token 也可能是并发请求，
    /// 不能仅凭元数据相等丢弃；队列的单次消费与事务性写入负责避免本地重放。
    var deduplicationID: String? {
        guard let requestID, !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return id
    }

    /// 摘要不含密钥，持久化去重窗口不保存明文 request_id；此 id 不用于无请求ID记录的去重。
    var id: String {
        let parts = [requestID ?? "", String(timestamp.timeIntervalSince1970), provider, model,
                     String(failed), String(tokens.total), String(tokens.input), String(tokens.output)]
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// 同一天、提供商、模型的累加桶；日汇总与事件主键在同一 SQLite 事务内更新。
nonisolated struct UsageBucket: Codable, Sendable, Equatable, Identifiable {
    let day: Date
    let provider: String
    let model: String
    var requests = 0
    var failures = 0
    var inputTokens = 0
    var outputTokens = 0
    var cachedTokens = 0
    var reasoningTokens = 0
    var totalTokens = 0
    var latencyTotal: Double = 0
    var latencySamples = 0
    var id: String { "\(day.timeIntervalSince1970)|\(provider.utf8.count):\(provider)|\(model)" }
    mutating func add(_ record: UsageRecord) {
        requests += 1; failures += record.failed ? 1 : 0
        inputTokens += record.tokens.input; outputTokens += record.tokens.output
        cachedTokens += record.tokens.cached; reasoningTokens += record.tokens.reasoning
        totalTokens += record.tokens.total
        if let latency = record.latencyMilliseconds, latency.isFinite, latency >= 0 {
            latencyTotal += latency; latencySamples += 1
        }
    }
}

nonisolated struct UsageTotals: Sendable, Equatable {
    var requests = 0; var failures = 0; var inputTokens = 0; var outputTokens = 0
    var cachedTokens = 0; var reasoningTokens = 0; var totalTokens = 0
    var latencyTotal: Double = 0; var latencySamples = 0
    var successRate: Double? { requests > 0 ? Double(requests - failures) / Double(requests) * 100 : nil }
    var averageLatencyMilliseconds: Double? { latencySamples > 0 ? latencyTotal / Double(latencySamples) : nil }
    init(buckets: [UsageBucket] = []) {
        for b in buckets {
            requests += b.requests; failures += b.failures; inputTokens += b.inputTokens
            outputTokens += b.outputTokens; cachedTokens += b.cachedTokens; reasoningTokens += b.reasoningTokens
            totalTokens += b.totalTokens; latencyTotal += b.latencyTotal; latencySamples += b.latencySamples
        }
    }
}

nonisolated struct UsageLedgerSnapshot: Codable, Sendable, Equatable {
    var version = 1
    var buckets: [UsageBucket] = []
    var recentRecordIDs: [String] = []
    var lastCollectedAt: Date?
    var firstCollectedAt: Date?
    /// 仅用于解码旧 JSON 的迁移字段；统一 SQLite 后不再生成或持久化跨存储待同步区。
    var pendingEvents: [CPAUsageEvent]?
    var totals: UsageTotals { UsageTotals(buckets: buckets) }
}

/// 单条格式异常不能让同批其余已出队记录一同丢失；异常数量只作状态提示，不记录原始内容。
nonisolated struct UsageQueueBatch: Decodable, Sendable {
    let records: [UsageRecord]
    let invalidCount: Int
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var records: [UsageRecord] = []; var invalid = 0
        while !container.isAtEnd {
            let entry = try container.superDecoder()
            do { records.append(try UsageRecord(from: entry)) }
            catch { invalid += 1 }
        }
        self.records = records; self.invalidCount = invalid
    }
}
