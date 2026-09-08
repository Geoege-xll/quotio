import Foundation
import Observation

/// 日志只在页面可见时轮询。展示时间来自日志本身，接收游标与展示排序互不干扰。
@MainActor
@Observable
final class LogsViewModel {
    private var apiClient: ManagementAPIClient?
    private var configuredURL = ""
    private var configuredKey = ""
    private var generation = 0
    private var cursor: String?
    private var rawLines: [String] = []
    let retainedLineLimit = 2000

    private(set) var logs: [LogEntry] = []
    private(set) var isRefreshing = false
    private(set) var isClearing = false
    private(set) var lastUpdated: Date?
    private(set) var revision = 0
    private(set) var usesLegacySnapshot = false
    var errorMessage: String?

    // CPA 的无时区日志使用服务本地时间。本页面用于本地代理，按本机时区解释。
    // 固定 POSIX 日历与格式，不让系统语言或 12 小时制偏好改变解析结果。
    @ObservationIgnored private let dateParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        return formatter
    }()
    @ObservationIgnored private let timestampPattern = try? NSRegularExpression(
        pattern: #"^\[?(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(\.\d+)?\]?\s*"#
    )
    @ObservationIgnored private let levelPattern = try? NSRegularExpression(
        pattern: #"^(?:\[[^\]]*\]\s*){0,1}\[(trace|debug|info|warn|warning|error|fatal|panic)\]"#,
        options: .caseInsensitive
    )

    var isConfigured: Bool { apiClient != nil }

    /// 服务地址或管理密钥改变时丢弃旧游标，旧请求返回后也不能污染新连接。
    func configure(baseURL: String, authKey: String) {
        guard apiClient == nil || configuredURL != baseURL || configuredKey != authKey else { return }
        reset()
        configuredURL = baseURL
        configuredKey = authKey
        apiClient = ManagementAPIClient(baseURL: baseURL, authKey: authKey)
    }

    func refreshLogs() async {
        guard let client = apiClient, !isRefreshing, !isClearing else { return }
        isRefreshing = true
        let requestGeneration = generation
        let requestedCursor = cursor
        defer { isRefreshing = false }
        do {
            let response = try await client.fetchLogs(cursor: requestedCursor, limit: retainedLineLimit)
            guard !Task.isCancelled, requestGeneration == generation else { return }
            let incoming = response.lines ?? []
            let next = response.nextCursor.flatMap { $0.isEmpty ? nil : $0 }
            usesLegacySnapshot = next == nil

            // 新版按文件偏移追加，不按消息内容去重，真实重复日志必须完整保留。
            // 旧版没有文件游标时读取有界尾部快照，不使用 after 秒级边界，
            // 从根源上避免同一秒新事件遗漏，也避免重放边界时错误删除重复事件。
            let combined: [String]
            if requestedCursor != nil, response.cursorReset != true, next != nil {
                combined = rawLines + incoming
            } else {
                combined = incoming
            }
            let bounded = Array(combined.suffix(retainedLineLimit))
            if bounded != rawLines || response.cursorReset == true {
                rebuildEntries(bounded, preserveIdentity: response.cursorReset != true)
                rawLines = bounded
                revision += 1
            }
            cursor = next
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            guard !Task.isCancelled, requestGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func clearLogs() async {
        guard let client = apiClient, !isRefreshing, !isClearing else { return }
        isClearing = true
        let requestGeneration = generation
        defer { isClearing = false }
        do {
            try await client.clearLogs()
            guard requestGeneration == generation else { return }
            rawLines.removeAll()
            logs.removeAll()
            cursor = nil
            revision += 1
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            guard requestGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func reset() {
        generation += 1
        logs.removeAll()
        rawLines.removeAll()
        cursor = nil
        apiClient = nil
        lastUpdated = nil
        errorMessage = nil
        usesLegacySnapshot = false
        revision += 1
    }

    /// 将没有新时间头的续行合并到同一事件，倒序展示时堆栈仍保持原始行序。
    /// 快照中的同文事件按出现次数逐一复用 ID，不使用 Set 去重。
    private func rebuildEntries(_ lines: [String], preserveIdentity: Bool) {
        var messages: [String] = []
        for line in lines {
            if timestampMatch(line) == nil, !messages.isEmpty {
                messages[messages.count - 1] += "\n" + line
            } else {
                messages.append(line)
            }
        }
        var previous: [String: [LogEntry]] = [:]
        if preserveIdentity {
            for entry in logs { previous[entry.message, default: []].append(entry) }
        }
        logs = messages.map { message in
            if var matches = previous[message], !matches.isEmpty {
                let entry = matches.removeFirst()
                previous[message] = matches
                return entry
            }
            guard let match = timestampMatch(message),
                  let dateRange = Range(match.range(at: 1), in: message),
                  let baseDate = dateParser.date(from: String(message[dateRange])) else {
                return LogEntry(timestamp: nil, level: .unknown, message: message)
            }
            var date = baseDate
            if let fractionRange = Range(match.range(at: 2), in: message),
               let fraction = Double("0" + message[fractionRange]) {
                date = date.addingTimeInterval(fraction)
            }
            let suffix = (message as NSString).substring(from: match.range.length)
            let level: LogEntry.LogLevel
            if let levelMatch = levelPattern?.firstMatch(in: suffix, range: NSRange(suffix.startIndex..., in: suffix)),
               let range = Range(levelMatch.range(at: 1), in: suffix) {
                switch suffix[range].lowercased() {
                case "trace", "debug": level = .debug
                case "warn", "warning": level = .warn
                case "error", "fatal", "panic": level = .error
                default: level = .info
                }
            } else {
                level = .unknown
            }
            return LogEntry(timestamp: date, level: level, message: message)
        }
    }

    private func timestampMatch(_ line: String) -> NSTextCheckingResult? {
        timestampPattern?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
    }
}
