import Foundation
import CryptoKit

/// 仅保存筛选和性能分析需要的元数据。原始账号来源、API 密钥、IP、请求/错误正文不进入归档。
nonisolated struct CPAUsageContext: Codable, Sendable, Equatable {
    var sourceID: String?
    var apiKeyID: String?
    var apiKeyLabel: String?
    var canceled = false
    var statusCode: Int?
    var ttft: Double?
    var cacheRead: Int?
    var cacheWrite: Int?
    var generate = true
    var alias: String?
    var reasoningEffort: String?
    var endpoint: String?

    private enum RawKeys: String, CodingKey {
        case source, canceled, fail, generate, tokens, alias, endpoint
        case apiKey = "api_key", apiKeyHash = "api_key_hash", ttft = "ttft_ms"
        case effort = "reasoning_effort", executor = "executor_type"
    }
    private enum TokenKeys: String, CodingKey {
        case read = "cache_read_tokens", write = "cache_creation_tokens"
        case cached = "cached_tokens", legacy = "cache_tokens"
    }
    private struct Failure: Decodable {
        var status: Int?
        var canceled: Bool
        enum CodingKeys: String, CodingKey { case status = "status_code", camelStatus = "statusCode", body }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try c.decodeIfPresent(Int.self, forKey: .status) ?? c.decodeIfPresent(Int.self, forKey: .camelStatus)
            canceled = try c.decodeIfPresent(CancellationSignal.self, forKey: .body)?.value ?? false
        }
    }
    /// 上游把错误正文中的这两个信号归为取消。这里只提取布尔结论，绝不保存正文。
    private struct CancellationSignal: Decodable {
        let value: Bool
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let text = try? c.decode(String.self) {
                let bounded = text.prefix(2_000).lowercased()
                value = bounded.contains("context canceled") || bounded.contains("client closed request")
            } else if let fields = try? c.decode([String: CancellationSignal].self) {
                value = fields.values.contains(where: \.value)
            } else if let items = try? c.decode([CancellationSignal].self) {
                value = items.contains(where: \.value)
            } else { value = false }
        }
    }

    static func read(from decoder: Decoder, failed: Bool, tokens: UsageRecord.Tokens) throws -> Self? {
        let c = try decoder.container(keyedBy: RawKeys.self)
        var context = Self()
        if let source = try c.decodeIfPresent(String.self, forKey: .source), !source.isEmpty {
            context.sourceID = digest("source:" + source)
        }
        if let key = try c.decodeIfPresent(String.self, forKey: .apiKey), !key.isEmpty {
            context.apiKeyID = digest(key)
            // 最后四位只用于用户识别；过短的值不显示，避免把短密钥完整暴露在界面。
            context.apiKeyLabel = key.count > 8 ? "****" + key.suffix(4) : "****"
        } else if let hash = try c.decodeIfPresent(String.self, forKey: .apiKeyHash), !hash.isEmpty {
            let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
            context.apiKeyID = hash.count == 64 && hash.unicodeScalars.allSatisfy({ hex.contains($0) })
                ? hash.lowercased() : digest(hash)
        }
        let failure = try c.decodeIfPresent(Failure.self, forKey: .fail)
        context.statusCode = failure?.status.flatMap { (100...599).contains($0) ? $0 : nil }
        let explicitCanceled = try c.decodeIfPresent(Bool.self, forKey: .canceled) ?? false
        context.canceled = failed && (explicitCanceled || failure?.status == 499 || failure?.canceled == true)
        context.ttft = finite(try c.decodeIfPresent(Double.self, forKey: .ttft))
        context.alias = try c.decodeIfPresent(String.self, forKey: .alias).map { String($0.prefix(512)) }
        context.reasoningEffort = try c.decodeIfPresent(String.self, forKey: .effort).map { String($0.prefix(64)) }
        if let endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) {
            // 只保留路由路径，不保留可能带有密钥的查询串、主机凭据或片段。
            context.endpoint = URLComponents(string: endpoint).map { String($0.path.prefix(256)) }
        }
        let executor = try c.decodeIfPresent(String.self, forKey: .executor) ?? ""
        context.generate = try c.decodeIfPresent(Bool.self, forKey: .generate)
            ?? !(executor == "CodexWebsocketsExecutor" && !failed && tokens.total == 0)
        if c.contains(.tokens), !(try c.decodeNil(forKey: .tokens)) {
            let t = try c.nestedContainer(keyedBy: TokenKeys.self, forKey: .tokens)
            let read = try t.decodeIfPresent(Int.self, forKey: .read)
            let cached = try t.decodeIfPresent(Int.self, forKey: .cached)
            let legacy = try t.decodeIfPresent(Int.self, forKey: .legacy)
            // 与 EasyCLIProxyAPI normalize_usage_record 一致：原始队列缺省缓存为零，
            // cache_tokens / cached_tokens 仅在显式读取字段缺失时作为兼容别名。
            context.cacheRead = clamp(read ?? max(cached ?? 0, legacy ?? 0))
            context.cacheWrite = clamp(try t.decodeIfPresent(Int.self, forKey: .write) ?? 0)
        } else {
            context.cacheRead = 0
            context.cacheWrite = 0
        }
        // 无扩展字段的历史记录继续使用 nil，保持旧版 Codable 调用者的语义。
        return context == Self() ? nil : context
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func clamp(_ value: Int?) -> Int? { value.map { min(1_000_000_000_000, max(0, $0)) } }
    static func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
}

nonisolated enum CPAUsageOutcome: String, Codable, Sendable, CaseIterable {
    case all, success, failed, canceled
    var titleKey: String { "usage.records.outcome." + rawValue }
}

/// 事件 ID 使用既有去重身份；无 request_id 时独立分配 UUID，不能把相同 Token 的并发请求合并。
nonisolated struct CPAUsageEvent: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let timestamp: Date
    let provider: String
    let model: String
    let outcome: CPAUsageOutcome
    let tokens: UsageRecord.Tokens
    let latency: Double?
    let context: CPAUsageContext
    /// 保存写入日账本时的绝对日桶起点；用户之后切换时区也不改变事件所属桶。
    let ledgerDay: Date?

    init(record: UsageRecord, ledgerDay: Date? = nil) {
        id = record.deduplicationID ?? UUID().uuidString
        timestamp = record.timestamp
        provider = String(record.provider.prefix(512)); model = String(record.model.prefix(512))
        context = record.context ?? CPAUsageContext()
        outcome = record.failed ? (context.canceled ? .canceled : .failed) : .success
        tokens = record.tokens
        latency = CPAUsageContext.finite(record.latencyMilliseconds)
        self.ledgerDay = ledgerDay
    }
    /// 与上游一致：只有成功生成且有有效 TTFT 的请求才参与 TPS，不能用总延迟替代生成耗时。
    var generationMilliseconds: Double? {
        guard outcome == .success, context.generate, tokens.output > 0,
              let latency, let ttft = context.ttft, ttft > 0, latency > ttft else { return nil }
        return latency - ttft
    }
    var tokensPerSecond: Double? { generationMilliseconds.map { Double(tokens.output) * 1000 / $0 } }
}

nonisolated enum CPAUsageTimeRange: String, CaseIterable, Sendable {
    case hours4 = "4h", hours24 = "24h", today, days7 = "7d", days30 = "30d", all, custom
    /// 仪表盘顶部胶囊只提供预设时间段，自定义时间统一在「更多筛选」面板中编辑。
    /// 保留 custom 及 allCases，完整面板与子页仍可使用精确日期查询。
    static let dashboardOptions: [Self] = [.hours4, .hours24, .today, .days7, .days30, .all]
    var titleKey: String { "usage.records.range." + rawValue }
}

/// 筛选状态与分页分离：修改任一条件时回到第一页，翻页本身不清空筛选。
nonisolated struct CPAUsageSelection: Hashable, Sendable {
    var range: CPAUsageTimeRange = .hours24
    var start = Calendar.current.startOfDay(for: Date())
    var end = Date()
    var provider = ""
    var model = ""
    var source = ""
    var apiKey = ""
    var outcome: CPAUsageOutcome = .all

    func query(now: Date, page: Int, pageSize: Int) -> CPAUsageQuery {
        let lower: Date?
        let upper: Date?
        switch range {
        case .all: lower = nil; upper = nil
        case .custom: lower = min(start, end); upper = max(start, end)
        case .today: lower = Calendar.current.startOfDay(for: now); upper = now
        default:
            let hours: Double = range == .hours4 ? 4 : (range == .hours24 ? 24 : (range == .days7 ? 168 : 720))
            lower = now.addingTimeInterval(-hours * 3600); upper = now
        }
        return CPAUsageQuery(start: lower, end: upper, provider: provider, model: model, source: source,
                             apiKey: apiKey, outcome: outcome, page: page, pageSize: pageSize)
    }
}

nonisolated struct CPAUsageQuery: Sendable {
    var start: Date?
    var end: Date?
    var provider = ""
    var model = ""
    var source = ""
    var apiKey = ""
    var outcome: CPAUsageOutcome = .all
    var page = 1
    var pageSize = 50
}

nonisolated struct CPAUsageOption: Sendable, Identifiable {
    let id: String
    let title: String
}

nonisolated struct CPAUsageEventMetrics: Sendable {
    var requests = 0, successes = 0, failures = 0, canceled = 0
    var input = 0, output = 0, reasoning = 0, cached = 0, tokens = 0
    var cacheRead = 0, cacheReadSamples = 0, cacheWrite = 0, cacheWriteSamples = 0
    var latencyTotal: Double = 0, latencySamples = 0
    var ttftTotal: Double = 0, ttftSamples = 0
    var generationTokens: Double = 0, generationMilliseconds: Double = 0, generationSamples = 0
    var minutes: Double?
    /// 日归档的非成功数没有区分取消，不能将其当成上游排除取消后的失败数。
    var unclassifiedFailures = 0
    var successRate: Double? {
        guard unclassifiedFailures == 0, successes + failures > 0 else { return nil }
        return Double(successes) / Double(successes + failures) * 100
    }
    var latency: Double? { latencySamples > 0 ? latencyTotal / Double(latencySamples) : nil }
    var ttft: Double? { ttftSamples > 0 ? ttftTotal / Double(ttftSamples) : nil }
    var tps: Double? { generationMilliseconds > 0 ? generationTokens * 1000 / generationMilliseconds : nil }
    var rpm: Double? { minutes.map { Double(requests) / $0 } }
    var tpm: Double? { minutes.map { Double(tokens) / $0 } }
    var cacheReadRate: Double? {
        requests > 0 && cacheReadSamples == requests && input > 0 ? min(1, Double(cacheRead) / Double(input)) * 100 : nil
    }
}

/// 完整筛选面板的本地目录。只包含可选身份，不携带统计数值、请求正文或已应用筛选。
/// 独立于页面当前时间窗，用户扩大草稿时间范围时即可选择旧模型、来源和密钥。
nonisolated struct CPAUsageFilterOptions: Sendable {
    var providers: [CPAUsageOption] = []
    var models: [CPAUsageOption] = []
    var sources: [CPAUsageOption] = []
    var apiKeys: [CPAUsageOption] = []
}

nonisolated struct CPAUsageEventPage: Sendable {
    var events: [CPAUsageEvent]
    var metrics: CPAUsageEventMetrics
    var providers: [CPAUsageOption]
    var models: [CPAUsageOption]
    var sources: [CPAUsageOption]
    var apiKeys: [CPAUsageOption]
    var page: Int
    var pageSize: Int
    var totalPages: Int
    var collectionStartedAt: Date?
    /// 存在任意真实明细时，空分页代表当前条件未匹配，不能误报旧版本从未保存明细。
    var hasStoredEvents = false
    /// 旧版本保存的真实日汇总，独立于请求事件展示；不能用这些桶填充事件分页或成功率。
    var historicalBuckets: [UsageBucket] = []
    var historicalRequests: Int { historicalBuckets.reduce(0) { $0 + $1.requests } }
    /// 受部分日、来源、密钥或结果条件限制而无法纳入本次查询的历史请求数量。
    var omittedHistoricalRequests = 0
    /// 全库历史规模只用于区分“从未保存明细”和“当前条件无匹配”，不参与当前筛选的指标。
    var allHistoricalRequests = 0
}
