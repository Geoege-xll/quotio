import Foundation

// 本文件仅维护设置页面的高级草稿及精确补丁；共享 CPA 策略、权重与错误契约按实际使用方归位。
// 原字段、初始化、scope 比较和校验正文不变；草稿与保存基线继续归原设置视图持有。

/// 高级表单使用文本草稿，非法输入不会悄悄变成 0，也不会因打开页面触发保存。
/// 保存时只提交与本次读取基线不同的字段，避免覆盖高级选项里尚未编辑的已有值。
nonisolated struct CPAAdvancedSettingsDraft: Equatable, Sendable {
    enum Scope: Sendable, Equatable { case requests, logging }
    var sessionTTL = "1h"
    var sessionSubagents = true
    var maxRetryCredentials = "0"
    var keepaliveSeconds = "0"
    var bootstrapRetries = "0"
    var logsMaxSizeMB = "0"
    var errorLogsMaxFiles = "10"

    init() {}

    init(config: ProxyConfig) {
        sessionTTL = config.sessionAffinityTTL ?? "1h"
        sessionSubagents = config.sessionAffinitySubagents ?? true
        maxRetryCredentials = String(config.maxRetryCredentials ?? 0)
        keepaliveSeconds = String(config.streamingKeepaliveSeconds ?? 0)
        bootstrapRetries = String(config.streamingBootstrapRetries ?? 0)
        logsMaxSizeMB = String(config.logsMaxTotalSizeMB ?? 0)
        errorLogsMaxFiles = String(config.errorLogsMaxFiles ?? 10)
    }

    func patch(comparedTo baseline: Self, scope: Scope) throws -> Data? {
        var root: [String: Any] = [:]
        switch scope {
        case .requests:
            var routing: [String: Any] = [:]
            if sessionTTL != baseline.sessionTTL {
                let ttl = sessionTTL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.isValidSessionTTL(ttl) else { throw CPASettingsValidationError.emptySessionTTL }
                // 实测 CPA 会接收不合法的时长字符串，因此客户端先校验 Go duration 语法和范围。
                // 只校验本轮修改值，已有小数、组合单位与未编辑的历史值仍保持原样。
                routing["session-affinity-ttl"] = ttl
            }
            if sessionSubagents != baseline.sessionSubagents { routing["session-affinity-subagents"] = sessionSubagents }
            if maxRetryCredentials != baseline.maxRetryCredentials {
                routing["retry"] = ["max-retry-credentials": try integer(maxRetryCredentials, field: "settings.cpa.maxRetryCredentials")]
            }
            if !routing.isEmpty { root["routing"] = routing }
            var streaming: [String: Any] = [:]
            if keepaliveSeconds != baseline.keepaliveSeconds {
                // 官方允许非正数关闭 SSE 保活，不能把已有负值强制改成 0。
                streaming["keepalive-seconds"] = try integer(keepaliveSeconds, field: "settings.cpa.keepaliveSeconds", allowsNegative: true)
            }
            if bootstrapRetries != baseline.bootstrapRetries {
                streaming["bootstrap-retries"] = try integer(bootstrapRetries, field: "settings.cpa.bootstrapRetries")
            }
            if !streaming.isEmpty { root["requests"] = ["streaming": streaming] }
        case .logging:
            var logs: [String: Any] = [:]
            if logsMaxSizeMB != baseline.logsMaxSizeMB {
                logs["logs-max-total-size-mb"] = try integer(logsMaxSizeMB, field: "settings.cpa.logsMaxSize")
            }
            if errorLogsMaxFiles != baseline.errorLogsMaxFiles {
                logs["error-logs-max-files"] = try integer(errorLogsMaxFiles, field: "settings.cpa.errorLogsMaxFiles")
            }
            if !logs.isEmpty { root["observability"] = ["logs": logs] }
        }
        guard !root.isEmpty else { return nil }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// 一次日志保存不能将另一区域尚未保存的请求草稿标记成成功。
    mutating func accept(_ draft: Self, scope: Scope) {
        switch scope {
        case .requests:
            sessionTTL = draft.sessionTTL; sessionSubagents = draft.sessionSubagents
            maxRetryCredentials = draft.maxRetryCredentials
            keepaliveSeconds = draft.keepaliveSeconds; bootstrapRetries = draft.bootstrapRetries
        case .logging:
            logsMaxSizeMB = draft.logsMaxSizeMB; errorLogsMaxFiles = draft.errorLogsMaxFiles
        }
    }

    /// 判定指定范围内的草稿内容是否相对于基线发生了变化，驱动应用按钮的可用状态。
    func hasChanges(comparedTo baseline: Self, scope: Scope) -> Bool {
        switch scope {
        case .requests:
            return sessionTTL != baseline.sessionTTL
                || sessionSubagents != baseline.sessionSubagents
                || maxRetryCredentials != baseline.maxRetryCredentials
                || keepaliveSeconds != baseline.keepaliveSeconds
                || bootstrapRetries != baseline.bootstrapRetries
        case .logging:
            return logsMaxSizeMB != baseline.logsMaxSizeMB
                || errorLogsMaxFiles != baseline.errorLogsMaxFiles
        }
    }

    private func integer(_ text: String, field: String, allowsNegative: Bool = false) throws -> Int {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), allowsNegative || value >= 0 else {
            throw CPASettingsValidationError.invalidNumber(field)
        }
        return value
    }

    /// Go duration 支持 h/m/s/ms/us/µs/μs/ns、符号、小数和组合单位，单位缺省仅允许 0。
    /// 用十进制按组件截取纳秒并检查 Int64 范围，避免 Double 把溢出边界误判为合法值。
    static func isValidSessionTTL(_ text: String) -> Bool {
        var source = text
        let negative = source.hasPrefix("-")
        if source.hasPrefix("-") || source.hasPrefix("+") { source.removeFirst() }
        if source == "0" { return true }
        guard !source.isEmpty, let regex = try? NSRegularExpression(
            pattern: #"([0-9]+(?:\.[0-9]*)?|\.[0-9]+)(ns|us|µs|μs|ms|s|m|h)"#
        ) else { return false }
        let units: [String: Decimal] = ["ns": 1, "us": 1_000, "µs": 1_000, "μs": 1_000,
            "ms": 1_000_000, "s": 1_000_000_000, "m": 60_000_000_000, "h": 3_600_000_000_000]
        let string = source as NSString
        var end = 0
        var total = Decimal.zero
        let maximum = Decimal(Int64.max) + (negative ? 1 : 0)
        for match in regex.matches(in: source, range: NSRange(location: 0, length: string.length)) {
            guard match.range.location == end,
                  let amount = Decimal(string: string.substring(with: match.range(at: 1)), locale: Locale(identifier: "en_US_POSIX")),
                  let unit = units[string.substring(with: match.range(at: 2))] else { return false }
            var raw = amount * unit
            var component = Decimal.zero
            NSDecimalRound(&component, &raw, 0, .down)
            total += component
            guard !total.isNaN, total <= maximum else { return false }
            end = NSMaxRange(match.range)
        }
        return end == string.length
    }
}
