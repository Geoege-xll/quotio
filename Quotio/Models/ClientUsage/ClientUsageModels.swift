import Foundation
import CryptoKit

/// 数据源表示生成本地会话的客户端，不使用模型名、API提供商或账号来猜测客户端身份。
nonisolated enum ClientUsageSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude, codex, opencode, pi
    var id: String { rawValue }
    var title: String {
        switch self { case .claude: return "Claude Code"; case .codex: return "Codex"; case .opencode: return "OpenCode"; case .pi: return "Pi" }
    }
}

/// 只保留一次已识别用量事件的脱敏投影。缓存包含在input中，推理包含在output中。
/// 各客户端原始口径由解析器归一，页面不能再次把缓存或推理加进总量。
nonisolated struct ClientUsageRecord: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let source: ClientUsageSource
    let timestamp: Date
    let model: String
    let input: Int
    let output: Int
    let cached: Int
    let reasoning: Int
    /// Pi 部分 provider 不报告思考明细；nil 兼容原有客户端归档，false 表示不能展示为确定的零。
    let hasReasoningBreakdown: Bool?
    let total: Int

    init(identity: String, source: ClientUsageSource, timestamp: Date, model: String,
         input: Int, output: Int, cached: Int = 0, reasoning: Int = 0, total: Int? = nil, hasReasoningBreakdown: Bool? = nil) {
        self.init(hashedID: ClientUsageDigest.sha256(source.rawValue + ":" + identity),
            source: source, timestamp: timestamp, model: model, input: input, output: output, cached: cached, reasoning: reasoning, total: total, hasReasoningBreakdown: hasReasoningBreakdown)
    }

    /// 检查点身份已在首次解析时完成散列，重投影不能再次散列，否则跨扫描记录身份会漂移。
    init(checkpoint: CodexUsageCheckpoint, input: Int, output: Int, cached: Int, reasoning: Int, total: Int) {
        self.init(hashedID: checkpoint.id, source: .codex, timestamp: checkpoint.timestamp, model: checkpoint.model,
            input: input, output: output, cached: cached, reasoning: reasoning, total: total)
    }

    /// SQLite 读取已散列的稳定身份，不能再次调用 identity 构造器，否则重启后会重复记账。
    init(hashedID: String, source: ClientUsageSource, timestamp: Date, model: String,
                 input: Int, output: Int, cached: Int, reasoning: Int, total: Int?, hasReasoningBreakdown: Bool? = nil) {
        self.hasReasoningBreakdown = hasReasoningBreakdown
        self.id = hashedID
        self.source = source; self.timestamp = timestamp
        self.model = String(model.prefix(512))
        let limit = 1_000_000_000_000
        self.input = min(limit, max(0, input)); self.output = min(limit, max(0, output))
        self.cached = min(limit, max(0, cached)); self.reasoning = min(limit, max(0, reasoning))
        self.total = min(2 * limit, max(0, total ?? (self.input + self.output)))
    }
}

nonisolated struct ClientUsageScan: Sendable {
    let source: ClientUsageSource
    var records: [ClientUsageRecord] = []
    var codexCheckpoints: [CodexUsageCheckpoint] = []
    /// 只反映本次文件/语法错误；缺失父会话等投影错误可在合并归档检查点后消除。
    var codexReadErrors = false
    var filesScanned = 0
    var available = false
    var hasErrors = false
}

nonisolated struct ClientUsageStatus: Codable, Sendable, Equatable, Identifiable {
    let source: ClientUsageSource
    var available: Bool
    var hasErrors: Bool
    var filesScanned: Int
    /// 新字段可选以兼容旧 JSON 归档；旧状态在下一次真实扫描前仍按原有错误提示处理，
    /// 不能仅根据历史缓存猜测本轮文件是否读取成功。
    var readErrors: Bool? = nil
    var incompleteSessionCount: Int? = nil
    var hasReadErrors: Bool { readErrors ?? hasErrors }
    var hasIncompleteHistory: Bool { (incompleteSessionCount ?? 0) > 0 }
    /// 读取结果与全部历史的完整性分开表达；历史有缺口不再伪装成当前读取失败。
    var readingStatusKey: String {
        if hasReadErrors { return "usage.client.readFailed" }
        guard available else { return "usage.client.missing" }
        return hasIncompleteHistory ? "usage.client.readableWithHistory" : "usage.client.readable"
    }
    var id: String { source.rawValue }
}

/// 客户端账本独立于CPA事件账本，避免同一请求在网关记录和客户端日志中被重复相加。
nonisolated struct ClientUsageSnapshot: Codable, Sendable {
    var version = 1
    var records: [ClientUsageRecord] = []
    /// 可选字段保证旧版无检查点归档仍能解码；新归档保存原始用量检查点以便重建差额。
    var codexCheckpoints: [CodexUsageCheckpoint]?
    var statuses: [ClientUsageStatus] = []
    var collectedAt: Date?

    func buckets(source: ClientUsageSource?, calendar: Calendar = .current) -> [UsageBucket] {
        var result: [String: UsageBucket] = [:]
        for entry in records where source == nil || entry.source == source {
            let bucket = UsageBucket(day: calendar.startOfDay(for: entry.timestamp), provider: entry.source.title, model: entry.model)
            var value = result[bucket.id] ?? bucket
            value.requests += 1
            value.inputTokens += entry.input; value.outputTokens += entry.output
            value.cachedTokens += entry.cached; value.reasoningTokens += entry.reasoning
            value.totalTokens += entry.total
            result[bucket.id] = value
        }
        return result.values.sorted { $0.id < $1.id }
    }
    func hasData(source: ClientUsageSource?) -> Bool {
        records.contains { source == nil || $0.source == source }
            || statuses.contains { (source == nil || $0.source == source) && $0.available && !$0.hasErrors }
    }
}


/// Codex 日志的最小可重算检查点。只保存散列会话关联与 Token 元数据，不包含正文、路径和凭据。
/// 累计差额可能因迟到前驱或父会话补入而变小，因此归档必须保留检查点，不能对差额记录做 max。
nonisolated struct CodexUsageCheckpoint: Codable, Sendable, Equatable, Identifiable {
    nonisolated struct Tokens: Codable, Sendable, Equatable, Hashable {
        var input: Int
        var output: Int
        var cached: Int
        var reasoning: Int
        var total: Int
        var fingerprint: String { "\(input):\(output):\(cached):\(reasoning):\(total)" }
    }
    let id: String
    let sessionID: String
    var parentSessionID: String?
    let timestamp: Date
    var forkDate: Date?
    var model: String
    var cumulative: Tokens?
    var last: Tokens?
    var ordinal: Int
    var hasErrors: Bool

    /// 数据库中的会话关联已经脱敏；直接恢复列值，保持旧 JSON 与日志解析产生的身份不变。
    init(id: String, sessionID: String, parentSessionID: String?, timestamp: Date, forkDate: Date?,
         model: String, cumulative: Tokens?, last: Tokens?, ordinal: Int, hasErrors: Bool) {
        self.id = id; self.sessionID = sessionID; self.parentSessionID = parentSessionID
        self.timestamp = timestamp; self.forkDate = forkDate; self.model = model
        self.cumulative = cumulative; self.last = last; self.ordinal = ordinal; self.hasErrors = hasErrors
    }

    /// 同一个累计检查点的副本可能缺少last/model或父关联。合并补充字段，
    /// 不让后扫描到的不完整副本抹掉已经获得的证据；任一有效副本可修复旧解析标记。
    func merging(_ other: Self) -> Self {
        guard id == other.id else { return self }
        var value = self
        if let last = other.last { value.last = last }
        if let cumulative = other.cumulative { value.cumulative = cumulative }
        if other.model != "unknown", !other.model.isEmpty { value.model = other.model }
        if let parent = other.parentSessionID { value.parentSessionID = parent }
        if let fork = other.forkDate { value.forkDate = fork }
        value.ordinal = min(ordinal, other.ordinal)
        value.hasErrors = hasErrors && other.hasErrors
        return value
    }

    /// 此入口仅接收本次内存解析的原始会话ID；Codable读取不再调用它，因而不会二次散列。
    init(rawSessionID: String, rawParentSessionID: String?, timestamp: Date, forkDate: Date?, model: String,
         cumulative: Tokens?, last: Tokens?, ordinal: Int, hasErrors: Bool = false) {
        func digest(_ value: String) -> String {
            ClientUsageDigest.sha256(value)
        }
        let usage = cumulative ?? last ?? Tokens(input: 0, output: 0, cached: 0, reasoning: 0, total: 0)
        let key = "\(timestamp.timeIntervalSince1970):\(cumulative == nil ? "last" : "total"):\(usage.fingerprint)"
        // 保持旧 ClientUsageRecord 的身份公式，使补入检查点后原来已存在的事件仍保持同一个ID。
        id = digest("codex:" + rawSessionID + ":" + key)
        sessionID = digest(rawSessionID)
        parentSessionID = rawParentSessionID.map(digest)
        self.timestamp = timestamp; self.forkDate = forkDate
        self.model = String(model.prefix(512)); self.cumulative = cumulative; self.last = last
        self.ordinal = ordinal; self.hasErrors = hasErrors
    }
}

/// 固定十六进制查表避免每个 SHA 字节创建格式化器，保持既有 64 位哈希完全不变。
nonisolated enum ClientUsageDigest {
    static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }
    static func sha256(_ data: Data) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        let digest = SHA256.hash(data: data)
        var bytes = [UInt8](); bytes.reserveCapacity(64)
        for byte in digest { bytes.append(alphabet[Int(byte >> 4)]); bytes.append(alphabet[Int(byte & 15)]) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
