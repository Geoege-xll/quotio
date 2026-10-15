import Foundation

/// 历史归属直接使用当前运行模式、提供商和原精确账号键，不按邮箱／显示名称合并。
/// 运行模式也是身份的一部分，远端 CPA 与本地监控的同名账号不能混用历史。
nonisolated struct QuotaHistoryAccount: Hashable, Codable, Sendable {
    let mode: String
    let provider: AIProvider
    let accountKey: String
}

/// 同步发布契约由共享账号能力定义，App 负责订阅和历史服务生命周期。
/// 只传已提交的值快照；不向 QuotaViewModel 增存储，也不延后猜测发布时的运行模式。
nonisolated struct QuotaHistoryPublication: Sendable {
    static let notification = Notification.Name("QuotaHistoryPublication")
    let mode: String
    let current: [AIProvider: [String: ProviderQuotaData]]
    let previous: [AIProvider: [String: ProviderQuotaData]]

    init(mode: String, current: [AIProvider: [String: ProviderQuotaData]],
         previous: [AIProvider: [String: ProviderQuotaData]], aliases: [AIProvider: [String: String]] = [:]) {
        self.mode = mode
        self.current = current
        // 纯目录重键只是搬运已有快照，不是当前模式的新观测。只使用目录已确认的一对一
        // 别名补齐比较基线，精确旧键仍优先；不按邮箱、时间或数值猜测两个账号相同。
        let canonical = AuthFileIdentity.rekey(previous, aliases: aliases) { $0.lastUpdated > $1.lastUpdated }
        var comparison = previous
        for (provider, accounts) in canonical {
            for (key, quota) in accounts where comparison[provider]?[key] == nil {
                comparison[provider, default: [:]][key] = quota
            }
        }
        self.previous = comparison
    }
}

nonisolated enum QuotaHistoryRange: String, CaseIterable, Identifiable, Hashable, Sendable {
    case day, week, month
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self { case .day: 86_400; case .week: 7 * 86_400; case .month: 30 * 86_400 }
    }
    var titleKey: String { "quota.history.range." + rawValue }
}

/// 一个真实数值观测；没有数值的状态行和未知百分比不生成零值采样。
/// basis 包含指标单位、额度总量、套餐和本轮重置时间，图表与速率不能跨这些语义边界连接。
nonisolated struct QuotaHistoryPoint: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case percentage, amount }
    enum Direction: String, Codable, Sendable { case decreasing, increasing }
    let metricID: String
    let metricName: String
    let date: Date
    let value: Double
    let kind: Kind
    let unit: QuotaMetricUnit?
    let direction: Direction
    let basis: String
    let resetAt: Date?
    let windowSeconds: TimeInterval?
    var id: String { metricID + ":" + String(date.timeIntervalSince1970) }

    static func make(model: ModelQuota, quota: ProviderQuotaData) -> QuotaHistoryPoint? {
        guard !quota.isForbidden, quota.lastUpdated.timeIntervalSince1970.isFinite else { return nil }
        let reset = resetDate(model.resetTime)
        let kind: Kind, value: Double, unit: QuotaMetricUnit?, direction: Direction
        var limit: Double?
        switch model.presentation {
        case .status: return nil
        case .amount(let amount, let metricUnit, let semantics):
            guard amount.isFinite, amount >= 0 else { return nil }
            kind = .amount; value = amount; unit = metricUnit
            direction = semantics == .balance ? .decreasing : .increasing
        case .progress(let used, let total, let metricUnit):
            guard used.isFinite, total.isFinite, used >= 0, total > 0 else { return nil }
            limit = total; unit = metricUnit; direction = .decreasing
            if model.percentage.isFinite, model.percentage >= 0 {
                kind = .percentage; value = min(100, model.percentage)
            } else {
                // 原百分比未知时，金额本身仍可形成历史；不擅自补一个百分比替换未知语义。
                kind = .amount; value = max(0, total - used)
            }
        case nil:
            guard model.percentage.isFinite, model.percentage >= 0 else { return nil }
            kind = .percentage; value = min(100, model.percentage); unit = nil; direction = .decreasing
            limit = model.limit.map(Double.init)
        }
        // JSON 数组保留空值和字段边界，避免简单拼接遇到名称包含分隔符时发生碰撞。
        let fields: [String?] = [kind.rawValue, unit?.rawValue, direction.rawValue,
            limit.map(String.init(describing:)), quota.planType,
            model.resetTimeIsEstimated == true ? "relative-reset" : reset.map { String($0.timeIntervalSince1970) }]
        guard let basisData = try? JSONEncoder().encode(fields),
              let basis = String(data: basisData, encoding: .utf8) else { return nil }
        return QuotaHistoryPoint(metricID: model.id, metricName: model.sourceDisplayName ?? model.displayName,
            date: quota.lastUpdated, value: value, kind: kind, unit: unit, direction: direction,
            basis: basis, resetAt: reset,
            windowSeconds: model.resetTimeIsEstimated == true ? nil : model.windowSeconds)
    }

    static func resetDate(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// 最近七天中同一额度基线的实际日均消耗。充值／重置造成的反向增加不抵扣已观测消耗。
    /// 用首尾观测之间的真实跨度作分母，至少覆盖一天；这是观测期平均值，不代表每小时均匀消耗。
    /// 只取末尾连续使用同一基线的样本，套餐来回切换也不能把中间不兼容的观测跳过后拼接。
    static func usedPerDay(_ points: [QuotaHistoryPoint], now: Date = Date()) -> Double? {
        let recent = points.filter { $0.date <= now && $0.date >= now.addingTimeInterval(-7 * 86_400) }
            .sorted { $0.date < $1.date }
        guard let last = recent.last, last.resetAt == nil else { return nil }
        let compatible = Array(recent.reversed().prefix { $0.basis == last.basis }.reversed())
        guard let first = compatible.first else { return nil }
        let days = last.date.timeIntervalSince(first.date) / 86_400
        guard days >= 1 else { return nil }
        let consumed = zip(compatible, compatible.dropFirst()).reduce(0.0) { result, pair in
            let delta = last.direction == .decreasing ? pair.0.value - pair.1.value : pair.1.value - pair.0.value
            return result + max(0, delta)
        }
        let rate = consumed / days
        return rate.isFinite ? rate : nil
    }
}

/// 图表抽样保留真实点，并把原始数据中的断点带到显示层。
/// 消耗速率另外使用完整分钟样本计算，不能用抽样后的折线点计算，否则会漏掉充值前的消耗。
nonisolated struct QuotaHistoryChartPoint: Identifiable, Sendable {
    let point: QuotaHistoryPoint
    let segment: Int
    var id: String { point.id }

    static func sample(_ points: [QuotaHistoryPoint], range: QuotaHistoryRange, now: Date) -> [Self] {
        let from = now.addingTimeInterval(-range.seconds)
        var buckets: [Int: Self] = [:]
        var previous: QuotaHistoryPoint?, segment = 0
        for point in points where point.date >= from && point.date <= now {
            if let previous {
                let refill = point.direction == .decreasing ? point.value > previous.value : point.value < previous.value
                // 兼容倒计时推算允许一分钟内的传输抖动；重置时间跳到下一周期时必须断开，
                // 即使用户在两次观测之间已消费，剩余值没有出现上升，也不能跨周期连线。
                let movedReset: Bool
                if let oldReset = previous.resetAt, let newReset = point.resetAt {
                    movedReset = abs(newReset.timeIntervalSince(oldReset)) > 60
                } else { movedReset = (previous.resetAt == nil) != (point.resetAt == nil) }
                if previous.basis != point.basis || previous.direction != point.direction
                    || point.date.timeIntervalSince(previous.date) > 3600 || refill || movedReset { segment += 1 }
            }
            previous = point
            // 右端点恰好等于 now 时仍归最后一桶，避免出现第 721 桶后丢掉最新读数。
            let bucket = min(719, max(0, Int(point.date.timeIntervalSince(from) / (range.seconds / 720))))
            buckets[bucket] = Self(point: point, segment: segment)
        }
        return buckets.keys.sorted().compactMap { buckets[$0] }
    }
}

nonisolated struct QuotaHistoryDailyRate: Sendable {
    let basis: String
    let value: Double
}

/// 仅明确周期长度、精确重置时刻且快照仍新鲜时提供估算；周期未知绝不根据倒计时猜总时长。
nonisolated struct QuotaPace: Equatable, Sendable {
    let expectedRemaining: Double
    let usedPerDay: Double
    let budgetPerDay: Double
    let projectedEmpty: Date?
    let resetAt: Date

    init?(point: QuotaHistoryPoint, now: Date = Date()) {
        guard point.kind == .percentage, point.value.isFinite, (0...100).contains(point.value),
              let window = point.windowSeconds, window.isFinite, window > 0,
              let reset = point.resetAt, reset > now, point.date <= now.addingTimeInterval(60),
              now.timeIntervalSince(point.date) <= 30 * 60 else { return nil }
        let start = reset.addingTimeInterval(-window)
        let elapsed = point.date.timeIntervalSince(start), remaining = reset.timeIntervalSince(now)
        guard elapsed > 0, elapsed < window, point.date <= reset else { return nil }
        expectedRemaining = min(100, max(0, remaining / window * 100))
        usedPerDay = (100 - point.value) / elapsed * 86_400
        budgetPerDay = point.value / remaining * 86_400
        // 消耗截止时刻是观测时间，不能把旧快照当成刚刚观测而延后耗尽时间。
        projectedEmpty = usedPerDay > 0 ? point.date.addingTimeInterval(point.value / usedPerDay * 86_400) : nil
        resetAt = reset
    }
}
