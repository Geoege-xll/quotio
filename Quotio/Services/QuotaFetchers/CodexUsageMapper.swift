import Foundation

nonisolated struct CodexQuotaIdentity: Sendable {
    var planType: String?
}

nonisolated enum CodexUsageMapper {
    static func map(
        data: Data,
        identity: CodexQuotaIdentity = CodexQuotaIdentity(),
        updatedAt: Date = Date()
    ) throws -> ProviderQuotaData {
        let response = try JSONDecoder().decode(CodexUsageResponseV2.self, from: data)
        let rawJSON = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        // 所有来源共用 ID 注册表：相同周期或显示名称不意味着同一额度池。
        // 第一次出现保留旧 ID，后续冲突才加入来源与窗口位置，避免列表覆盖有效窗口。
        var usedIDs = Set<String>()
        var models = standardModels(from: response.rateLimit, usedIDs: &usedIDs)
        models.append(contentsOf: extraModels(from: response.additionalRateLimits, usedIDs: &usedIDs))
        // 代码审查是独立限额，不能用普通对话窗口覆盖，也不能因主窗口缺失而丢弃。
        models.append(contentsOf: standardModels(from: response.codeReviewRateLimit, codeReview: true, usedIDs: &usedIDs))
        guard !models.isEmpty else { throw QuotaFetchError.invalidResponse }

        let planType = response.planType ?? identity.planType
        return ProviderQuotaData(
            models: models,
            lastUpdated: updatedAt,
            // limit_reached 是配额耗尽，并非 HTTP 403 或账号封禁；仍须显示各窗口与重置时间。
            isForbidden: false,
            planType: planType,
            analytics: analytics(from: rawJSON)
        )
    }

    private static func modelQuota(name: String, from snapshot: CodexUsageResponseV2.WindowSnapshot?, reached: Bool = false) -> ModelQuota? {
        guard let snapshot else { return nil }
        return ModelQuota(
            name: name,
            percentage: remaining(snapshot, reached: reached),
            resetTime: snapshot.resetDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        )
    }

    private static func standardModels(
        from rateLimit: CodexUsageResponseV2.RateLimitDetails?,
        codeReview: Bool = false,
        usedIDs: inout Set<String>
    ) -> [ModelQuota] {
        let windows: [(CodexUsageResponseV2.WindowSnapshot?, StandardWindowKind, String)] = [
            (rateLimit?.primaryWindow, .session, "primary"),
            (rateLimit?.secondaryWindow, .weekly, "secondary")
        ]

        return windows.compactMap { snapshot, fallbackKind, position in
            guard let snapshot else { return nil }
            let kind = standardWindowKind(for: snapshot, fallback: fallbackKind)
            let preferredID = codeReview
                ? kind.id.replacingOccurrences(of: "codex-", with: "codex-code-review-")
                : kind.id
            // primary/secondary 即使时长相同，也分别保留各自的数值和重置时间。
            let source = codeReview ? "code-review" : "standard"
            let id = reserveID(preferredID, position: source + "-" + position, usedIDs: &usedIDs)
            return modelQuota(name: id, from: snapshot, reached: rateLimit?.isReached == true)
        }
    }

    private static func standardWindowKind(
        for snapshot: CodexUsageResponseV2.WindowSnapshot,
        fallback: StandardWindowKind
    ) -> StandardWindowKind {
        let day = 24 * 60 * 60
        if let seconds = snapshot.limitWindowSeconds, seconds > 0 {
            if (28 * day...31 * day).contains(seconds) { return .monthly }
            if seconds == 7 * day { return .weekly }
            if seconds == 5 * 3600 { return .session }
            return .custom(seconds)
        }
        // Heuristic, used only when the authoritative `limit_window_seconds` is
        // absent. `reset_after_seconds` is the time REMAINING in the window, not
        // the window's length, so it is only ever a lower bound: a horizon of
        // more than a day rules out the 5h session window, but it cannot tell how
        // long the window actually is, and a weekly window that is less than a day
        // from resetting is indistinguishable from a session one and falls through
        // to the positional fallback below.
        if let resetAfter = snapshot.resetAfterSeconds, resetAfter > day { return .weekly }
        return fallback
    }

    private static func extraModels(
        from limits: [CodexUsageResponseV2.AdditionalRateLimit]?,
        usedIDs: inout Set<String>
    ) -> [ModelQuota] {
        guard let limits, !limits.isEmpty else { return [] }
        return limits.enumerated().flatMap { index, limit in
            if isSpark(limit) {
                return sparkModels(from: limit, sourceIndex: index, usedIDs: &usedIDs)
            }

            // 官方允许附加限额仅有 rate_limit；没有名字时按来源位置生成标识，
            // 不能将实际存在的额度窗口当作坏数据丢弃。有名项仍优先使用原来的 ID。
            let id = modelID(for: limit) ?? "codex-additional-\(index + 1)"
            // 同一附加能力也可能同时有会话与周限额，不能只取第一个非空窗口。
            let windows = [(limit.rateLimit?.primaryWindow, ""), (limit.rateLimit?.secondaryWindow, "-secondary")]
            return windows.compactMap { snapshot, suffix in
                guard let snapshot else { return nil }
                let kind = standardWindowKind(for: snapshot, fallback: suffix.isEmpty ? .session : .weekly)
                let position = "additional-\(index + 1)-" + (suffix.isEmpty ? "primary" : "secondary")
                let uniqueID = reserveID(id + suffix, position: position, usedIDs: &usedIDs)
                var model = modelQuota(name: uniqueID, from: snapshot, reached: limit.rateLimit?.isReached == true)
                let label = firstNonEmpty(limit.limitName, limit.meteredFeature) ?? "Additional \(index + 1)"
                model?.sourceDisplayName = label + " · " + kind.title
                return model
            }
        }
    }

    private static func sparkModels(
        from limit: CodexUsageResponseV2.AdditionalRateLimit,
        sourceIndex: Int,
        usedIDs: inout Set<String>
    ) -> [ModelQuota] {
        [
            (limit.rateLimit?.primaryWindow, sparkKind(for: limit.rateLimit?.primaryWindow, fallback: .fiveHour), "primary"),
            (limit.rateLimit?.secondaryWindow, sparkKind(for: limit.rateLimit?.secondaryWindow, fallback: .weekly), "secondary")
        ].compactMap { snapshot, kind, position in
            guard let snapshot else { return nil }
            // Spark 也可能出现同周期的多个池，周期只决定旧版展示 ID，不用于删减响应。
            let id = reserveID(kind.id, position: "additional-\(sourceIndex + 1)-" + position, usedIDs: &usedIDs)
            return ModelQuota(
                name: id,
                percentage: remaining(snapshot, reached: limit.rateLimit?.isReached == true),
                resetTime: snapshot.resetDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
            )
        }
    }

    /// 兼容已有窗口标识，同时保留同名、同周期及跨来源碰撞的独立限额。
    /// 上游名称本身也可能与生成的后缀相同，因此继续编号直到当前响应内唯一。
    /// 无名项只能使用响应中的位置定位；不根据百分比或重置时间生成会随刷新变化的 ID。
    private static func reserveID(_ preferred: String, position: String, usedIDs: inout Set<String>) -> String {
        if usedIDs.insert(preferred).inserted { return preferred }
        let base = preferred + "-" + position
        var candidate = base
        var occurrence = 2
        while !usedIDs.insert(candidate).inserted {
            candidate = base + "-\(occurrence)"
            occurrence += 1
        }
        return candidate
    }

    private static func sparkKind(
        for snapshot: CodexUsageResponseV2.WindowSnapshot?,
        fallback: SparkWindowKind
    ) -> SparkWindowKind {
        guard let minutes = snapshot?.windowMinutes else { return fallback }
        if minutes <= 6 * 60 { return .fiveHour }
        if minutes >= 6 * 24 * 60 { return .weekly }
        return fallback
    }

    private static func modelID(for limit: CodexUsageResponseV2.AdditionalRateLimit) -> String? {
        guard let source = firstNonEmpty(limit.meteredFeature, limit.limitName) else { return nil }
        let slug = slug(source)
        return slug.isEmpty ? nil : "codex-\(slug)"
    }

    private static func isSpark(_ limit: CodexUsageResponseV2.AdditionalRateLimit) -> Bool {
        [limit.limitName, limit.meteredFeature]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains("spark") }
    }

    /// used_percent 是 0...100 的已用百分比（例如 0.63 表示已用 0.63%），保留小数。
    /// 缺少数值时只有明确限流且存在重置依据才显示耗尽，其余保持未知。
    private static func remaining(_ snapshot: CodexUsageResponseV2.WindowSnapshot, reached: Bool) -> Double {
        if let used = snapshot.usedPercent { return 100 - min(100, max(0, used)) }
        return reached && snapshot.resetDate != nil ? 0 : -1
    }

    private static func analytics(from json: [String: Any]?) -> QuotaAnalytics? {
        guard let json else { return nil }
        var rows: [QuotaAnalyticsRow] = []
        if let credits = creditsRemaining(from: json) {
            let creditCount = Int(max(0, credits.rounded(.down)))
            rows.append(QuotaAnalyticsRow(
                id: "codex-extra-usage",
                title: "Extra Usage",
                value: "\(formatDollars(Double(creditCount) * 0.04)) - \(creditCount) credits"
            ))
        }
        if let count = resetCreditsCount(from: json) {
            rows.append(QuotaAnalyticsRow(
                id: "codex-rate-limit-resets",
                title: "Rate Limit Resets",
                value: "\(count) available"
            ))
        }
        return rows.isEmpty ? nil : QuotaAnalytics(rows: rows)
    }

    private static func creditsRemaining(from json: [String: Any]) -> Double? {
        guard let credits = json["credits"] as? [String: Any] else { return nil }
        if let balance = doubleValue(credits["balance"]) {
            return max(0, balance)
        }
        if credits["has_credits"] as? Bool == false {
            return 0
        }
        return nil
    }

    private static func resetCreditsCount(from json: [String: Any]) -> Int? {
        guard let resets = json["rate_limit_reset_credits"] as? [String: Any],
              let count = doubleValue(resets["available_count"]),
              count >= 0
        else {
            return nil
        }
        return Int(count.rounded(.down))
    }

    private static func formatDollars(_ value: Double) -> String {
        if value >= 1000 {
            return String(format: "$%.1fK", value / 1000)
        }
        return String(format: "$%.2f", value)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value = trimmedNonEmpty(value) {
                return value
            }
        }
        return nil
    }

    private static func slug(_ value: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private enum SparkWindowKind {
        case fiveHour
        case weekly

        var id: String {
            switch self {
            case .fiveHour: "codex-spark"
            case .weekly: "codex-spark-weekly"
            }
        }
    }

    private enum StandardWindowKind: Hashable {
        case session
        case weekly
        case monthly
        case custom(Int)

        var id: String {
            switch self {
            case .session: "codex-session"
            case .weekly: "codex-weekly"
            case .monthly: "codex-monthly"
            case .custom(let seconds): "codex-window-\(seconds)s"
            }
        }
        var title: String {
            switch self {
            case .session: "Session"
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            case .custom(let seconds): "\(seconds)s"
            }
        }
    }
}

nonisolated struct CodexUsageResponseV2: Decodable {
    var planType: String?
    var rateLimit: RateLimitDetails?
    var additionalRateLimits: [AdditionalRateLimit]?
    var codeReviewRateLimit: RateLimitDetails?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case codeReviewRateLimit = "code_review_rate_limit"
        case planTypeCamel = "planType", rateLimitCamel = "rateLimit"
        case additionalRateLimitsCamel = "additionalRateLimits", codeReviewRateLimitCamel = "codeReviewRateLimit"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = (try? container.decodeIfPresent(String.self, forKey: .planType))
            ?? (try? container.decodeIfPresent(String.self, forKey: .planTypeCamel))
        rateLimit = (try? container.decodeIfPresent(RateLimitDetails.self, forKey: .rateLimit))
            ?? (try? container.decodeIfPresent(RateLimitDetails.self, forKey: .rateLimitCamel))
        codeReviewRateLimit = (try? container.decodeIfPresent(RateLimitDetails.self, forKey: .codeReviewRateLimit))
            ?? (try? container.decodeIfPresent(RateLimitDetails.self, forKey: .codeReviewRateLimitCamel))
        if let decoded = (try? container.decodeIfPresent([LossyAdditionalRateLimit].self, forKey: .additionalRateLimits))
            ?? (try? container.decodeIfPresent([LossyAdditionalRateLimit].self, forKey: .additionalRateLimitsCamel)) {
            additionalRateLimits = decoded.compactMap(\.value)
        }
    }

    struct RateLimitDetails: Decodable {
        var limitReached: Bool?
        var primaryWindow: WindowSnapshot?
        var secondaryWindow: WindowSnapshot?
        var allowed: Bool?
        var isReached: Bool { limitReached == true || allowed == false }

        enum CodingKeys: String, CodingKey {
            case limitReached = "limit_reached"
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
            case allowed
            case limitReachedCamel = "limitReached", primaryWindowCamel = "primaryWindow", secondaryWindowCamel = "secondaryWindow"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            allowed = try? container.decodeIfPresent(Bool.self, forKey: .allowed)
            limitReached = (try? container.decodeIfPresent(Bool.self, forKey: .limitReached))
                ?? (try? container.decodeIfPresent(Bool.self, forKey: .limitReachedCamel))
            primaryWindow = (try? container.decodeIfPresent(WindowSnapshot.self, forKey: .primaryWindow))
                ?? (try? container.decodeIfPresent(WindowSnapshot.self, forKey: .primaryWindowCamel))
            secondaryWindow = (try? container.decodeIfPresent(WindowSnapshot.self, forKey: .secondaryWindow))
                ?? (try? container.decodeIfPresent(WindowSnapshot.self, forKey: .secondaryWindowCamel))
        }
    }

    struct WindowSnapshot: Decodable {
        var usedPercent: Double?
        var resetAt: Int?
        var resetAfterSeconds: Int?
        var limitWindowSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case resetAfterSeconds = "reset_after_seconds"
            case limitWindowSeconds = "limit_window_seconds"
            case usedPercentCamel = "usedPercent", resetAtCamel = "resetAt"
            case resetAfterSecondsCamel = "resetAfterSeconds", limitWindowSecondsCamel = "limitWindowSeconds"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = Self.flexibleDouble(container, forKey: .usedPercent)
                ?? Self.flexibleDouble(container, forKey: .usedPercentCamel)
            resetAt = (try? Self.flexibleInt(container, forKey: .resetAt)) ?? (try? Self.flexibleInt(container, forKey: .resetAtCamel))
            resetAfterSeconds = (try? Self.flexibleInt(container, forKey: .resetAfterSeconds)) ?? (try? Self.flexibleInt(container, forKey: .resetAfterSecondsCamel))
            limitWindowSeconds = (try? Self.flexibleInt(container, forKey: .limitWindowSeconds)) ?? (try? Self.flexibleInt(container, forKey: .limitWindowSecondsCamel))
        }

        var resetDate: Date? {
            if let resetAt, resetAt > 0 {
                return Date(timeIntervalSince1970: TimeInterval(resetAt > 10_000_000_000 ? resetAt / 1000 : resetAt))
            }
            guard let resetAfterSeconds, resetAfterSeconds > 0, resetAfterSeconds < 315_576_000 else { return nil }
            return Date().addingTimeInterval(TimeInterval(resetAfterSeconds))
        }

        var windowMinutes: Int? {
            guard let limitWindowSeconds, limitWindowSeconds > 0 else { return nil }
            return limitWindowSeconds / 60
        }

        private static func flexibleInt(
            _ container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) throws -> Int {
            if let int = try? container.decode(Int.self, forKey: key) {
                return int
            }
            if let value = flexibleDouble(container, forKey: key),
               value >= Double(Int.min), value < Double(Int.max) { return Int(value) }
            throw DecodingError.dataCorrupted(.init(codingPath: [key], debugDescription: "Expected number"))
        }

        private static func flexibleDouble(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Double? {
            let value = (try? container.decode(Double.self, forKey: key))
                ?? (try? container.decode(String.self, forKey: key)).flatMap(Double.init)
            guard let value, value.isFinite else { return nil }
            return value
        }
    }

    struct AdditionalRateLimit: Decodable {
        var limitName: String?
        var meteredFeature: String?
        var rateLimit: RateLimitDetails?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case meteredFeature = "metered_feature"
            case rateLimit = "rate_limit"
            case limitNameCamel = "limitName", meteredFeatureCamel = "meteredFeature", rateLimitCamel = "rateLimit"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            limitName = (try? container.decodeIfPresent(String.self, forKey: .limitName)) ?? (try? container.decodeIfPresent(String.self, forKey: .limitNameCamel))
            meteredFeature = (try? container.decodeIfPresent(String.self, forKey: .meteredFeature)) ?? (try? container.decodeIfPresent(String.self, forKey: .meteredFeatureCamel))
            rateLimit = (try? container.decodeIfPresent(RateLimitDetails.self, forKey: .rateLimit)) ?? (try? container.decodeIfPresent(RateLimitDetails.self, forKey: .rateLimitCamel))
        }
    }

    private struct LossyAdditionalRateLimit: Decodable {
        var value: AdditionalRateLimit?

        init(from decoder: Decoder) throws {
            value = try? AdditionalRateLimit(from: decoder)
        }
    }
}

nonisolated enum CodexProfileAnalyticsError: Error, Equatable {
    case authenticationRequired
}

nonisolated struct CodexProfileAnalyticsFetcher: Sendable {
    private static let profileURL = URL(string: "https://chatgpt.com/backend-api/wham/profiles/me")!

    let urlSession: URLSession
    var now: @Sendable () -> Date = Date.init

    init(urlSession: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.urlSession = urlSession
        self.now = now
    }

    func fetch(accessToken: String, accountID: String?) async throws -> QuotaAnalytics? {
        var request = URLRequest(url: Self.profileURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codex Desktop", forHTTPHeaderField: "Originator")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw CodexProfileAnalyticsError.authenticationRequired
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            return nil
        }

        let profile = try CodexProfileAnalyticsResponse(data: data)
        return Self.analytics(from: profile, now: now())
    }

    static func analytics(from response: CodexProfileAnalyticsResponse, now: Date = Date()) -> QuotaAnalytics? {
        guard let stats = response.stats else { return nil }

        var rows: [QuotaAnalyticsRow] = []
        let calendar = Calendar.current
        let today = dayString(now, calendar: calendar)
        let yesterday = dayString(calendar.date(byAdding: .day, value: -1, to: now) ?? now, calendar: calendar)
        let bucketsByDate = Dictionary(uniqueKeysWithValues: stats.dailyUsageBuckets.map { ($0.date, $0.tokens) })

        rows.append(dayRow(id: "today", title: "Today", tokens: bucketsByDate[today]))
        rows.append(dayRow(id: "yesterday", title: "Yesterday", tokens: bucketsByDate[yesterday]))

        let latest30 = stats.dailyUsageBuckets.sorted { $0.date > $1.date }.prefix(30)
        let last30Tokens = latest30.reduce(0) { $0 + $1.tokens }
        rows.append(last30Tokens > 0
            ? QuotaAnalyticsRow(id: "last-30-days", title: "Last 30 Days", value: tokenLabel(last30Tokens))
            : .noData(id: "last-30-days", title: "Last 30 Days"))

        appendTokenRow(&rows, id: "codex-lifetime-tokens", title: "Lifetime Tokens", value: stats.lifetimeTokens)
        appendTokenRow(&rows, id: "codex-peak-daily", title: "Peak Daily", value: stats.peakDailyTokens)
        appendDurationRow(&rows, id: "codex-longest-task", title: "Longest Task", seconds: stats.longestRunningTurnSeconds)
        appendDaysRow(&rows, id: "codex-current-streak", title: "Current Streak", value: stats.currentStreakDays)
        appendDaysRow(&rows, id: "codex-longest-streak", title: "Longest Streak", value: stats.longestStreakDays)

        let trend = stats.dailyUsageBuckets
            .sorted { $0.date < $1.date }
            .suffix(371)
            .map {
                QuotaAnalyticsPoint(
                    date: $0.date,
                    value: Double($0.tokens),
                    label: $0.date,
                    valueLabel: tokenLabel($0.tokens)
                )
            }

        let analytics = QuotaAnalytics(trend: trend, rows: rows, note: "Account analytics from Codex")
        return analytics.isEmpty ? nil : analytics
    }

    private static func dayRow(id: String, title: String, tokens: Int?) -> QuotaAnalyticsRow {
        guard let tokens, tokens > 0 else {
            return .noData(id: id, title: title)
        }
        return QuotaAnalyticsRow(id: id, title: title, value: tokenLabel(tokens))
    }

    private static func appendTokenRow(_ rows: inout [QuotaAnalyticsRow], id: String, title: String, value: Int?) {
        guard let value, value > 0 else { return }
        rows.append(QuotaAnalyticsRow(id: id, title: title, value: tokenLabel(value)))
    }

    private static func appendDaysRow(_ rows: inout [QuotaAnalyticsRow], id: String, title: String, value: Int?) {
        guard let value, value >= 0 else { return }
        rows.append(QuotaAnalyticsRow(id: id, title: title, value: "\(intLabel(value)) \(value == 1 ? "day" : "days")"))
    }

    private static func appendDurationRow(_ rows: inout [QuotaAnalyticsRow], id: String, title: String, seconds: Int?) {
        guard let seconds, seconds > 0 else { return }
        rows.append(QuotaAnalyticsRow(id: id, title: title, value: durationLabel(seconds)))
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func tokenLabel(_ value: Int) -> String {
        "\(compactNumber(Double(value))) tokens"
    }

    private static func durationLabel(_ seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(remainingSeconds)s"
        }
        return "\(remainingSeconds)s"
    }

    private static func compactNumber(_ value: Double) -> String {
        let absValue = abs(value)
        if absValue >= 1_000_000_000 {
            return String(format: "%.1fB", value / 1_000_000_000).replacingOccurrences(of: ".0B", with: "B")
        }
        if absValue >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
        if absValue >= 1_000 {
            return String(format: "%.1fK", value / 1_000).replacingOccurrences(of: ".0K", with: "K")
        }
        return intLabel(Int(value))
    }

    private static func intLabel(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}

nonisolated struct CodexProfileAnalyticsResponse: Equatable, Sendable {
    var stats: Stats?

    init(data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Expected object"))
        }
        self.init(json: json)
    }

    init(json: [String: Any]) {
        stats = (json["stats"] as? [String: Any]).map(Stats.init(json:))
    }

    nonisolated struct Stats: Equatable, Sendable {
        var lifetimeTokens: Int?
        var peakDailyTokens: Int?
        var currentStreakDays: Int?
        var longestStreakDays: Int?
        var longestRunningTurnSeconds: Int?
        var dailyUsageBuckets: [UsageBucket]

        init(json: [String: Any]) {
            lifetimeTokens = intValue(json["lifetime_tokens"] ?? json["lifetimeTokens"])
            peakDailyTokens = intValue(json["peak_daily_tokens"] ?? json["peakDailyTokens"])
            currentStreakDays = intValue(json["current_streak_days"] ?? json["currentStreakDays"])
            longestStreakDays = intValue(json["longest_streak_days"] ?? json["longestStreakDays"])
            longestRunningTurnSeconds = intValue(json["longest_running_turn_sec"] ?? json["longestRunningTurnSec"])
            dailyUsageBuckets = UsageBucket.decodeBuckets(json["daily_usage_buckets"] ?? json["dailyUsageBuckets"])
        }
    }

    nonisolated struct UsageBucket: Equatable, Sendable {
        var date: String
        var tokens: Int

        static func decodeBuckets(_ value: Any?) -> [UsageBucket] {
            if let array = value as? [Any] {
                return array.compactMap(bucket(from:))
            }
            if let object = value as? [String: Any] {
                return object.compactMap { key, value in
                    guard let tokens = tokenCount(from: value) else { return nil }
                    return UsageBucket(date: normalizeDate(key), tokens: tokens)
                }
            }
            return []
        }

        private static func bucket(from value: Any) -> UsageBucket? {
            guard let object = value as? [String: Any] else { return nil }
            guard let date = stringValue(
                object["date"]
                    ?? object["day"]
                    ?? object["start_date"]
                    ?? object["startDate"]
                    ?? object["bucket"]
                    ?? object["bucket_start"]
                    ?? object["bucketStart"]
            ) else {
                return nil
            }
            guard let tokens = tokenCount(from: object) else { return nil }
            return UsageBucket(date: normalizeDate(date), tokens: tokens)
        }

        private static func tokenCount(from value: Any?) -> Int? {
            if let object = value as? [String: Any] {
                if let total = intValue(
                    object["tokens"]
                        ?? object["token_count"]
                        ?? object["tokenCount"]
                        ?? object["total_tokens"]
                        ?? object["totalTokens"]
                        ?? object["value"]
                        ?? object["count"]
                ) {
                    return total
                }
                let input = intValue(object["input_tokens"] ?? object["inputTokens"]) ?? 0
                let output = intValue(object["output_tokens"] ?? object["outputTokens"]) ?? 0
                return input + output > 0 ? input + output : nil
            }
            return intValue(value)
        }

        private static func normalizeDate(_ value: String) -> String {
            if value.count >= 10 {
                return String(value.prefix(10))
            }
            return value
        }
    }
}

nonisolated func stringValue(_ value: Any?) -> String? {
    switch value {
    case let value as String:
        value
    case let value as CustomStringConvertible:
        value.description
    default:
        nil
    }
}

nonisolated func doubleValue(_ value: Any?) -> Double? {
    switch value {
    case let value as Double:
        value
    case let value as Int:
        Double(value)
    case let value as String:
        Double(value)
    default:
        nil
    }
}

nonisolated func intValue(_ value: Any?) -> Int? {
    switch value {
    case let value as Int:
        value
    case let value as Double:
        Int(value)
    case let value as String:
        Int(value) ?? Double(value).map(Int.init)
    default:
        nil
    }
}

nonisolated func trimmedNonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    return value
}

extension Comparable {
    nonisolated func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
