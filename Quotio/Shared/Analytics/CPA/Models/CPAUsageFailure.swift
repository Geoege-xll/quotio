import Foundation

/// 错误正文只在解码时参与有限分类，不保存原始文本、URL、密钥或请求内容。
/// 与 HTTP 状态码分开：CPA 可能将超时、无可用凭据等错误统一上报为 500。
nonisolated enum CPAUsageFailureKind: String, Codable, Sendable, CaseIterable {
    case quotaExhausted, rateLimited, noAvailableAccount, contextTooLong, modelUnavailable
    case authentication, permissionDenied, invalidRequest, timeout, connection, overloaded
    case serverError, badGateway, serviceUnavailable, rateOrQuota, endpointUnavailable, requestTooLarge, unknown

    var titleKey: String { "routing.failure." + rawValue + ".title" }
    var reasonKey: String { "routing.failure." + rawValue + ".reason" }
    var adviceKey: String { "routing.failure." + rawValue + ".advice" }

    /// 历史记录只有状态码时只能给出通用含义，尤其 429 不能直接断言账号没额度。
    static func from(status: Int?) -> Self {
        switch status {
        case 400, 422: .invalidRequest
        case 401: .authentication
        case 403: .permissionDenied
        case 404: .endpointUnavailable
        case 408, 504: .timeout
        case 413: .requestTooLarge
        case 429: .rateOrQuota
        case 500: .serverError
        case 502: .badGateway
        case 503: .serviceUnavailable
        default: .unknown
        }
    }

    /// 只匹配明确错误标识或常见错误短语，不用孤立的 quota、model、token 等词猜测。
    /// 前部类别更具体：结构化 type=rate_limit_error、message=usage_limit_reached 时
    /// 应解释为额度耗尽，而不是丢掉 message 中提供的具体失败类型。
    static func recognize(_ text: String) -> Self? {
        let text = String(text.prefix(8_192)).lowercased()
        let rules: [(Self, [String])] = [
            // quota exceeded／quota exhausted 本身也可能是每分钟请求配额，不能
            // 直接归为账号额度耗尽。只接受余额、订阅额度的明确标识或说明。
            (.quotaExhausted, ["insufficient_quota", "usage_limit_reached",
                "credit balance is too low", "额度不足", "额度耗尽", "余额不足"]),
            (.noAvailableAccount, ["auth_unavailable", "no auth available", "no available credentials"]),
            (.contextTooLong, ["context_length_exceeded", "maximum context length", "prompt is too long"]),
            (.modelUnavailable, ["model_not_found", "model not found", "model does not exist", "unsupported model"]),
            (.authentication, ["invalid_api_key", "invalid api key", "authentication_error", "token_expired", "expired token", "token has expired"]),
            (.permissionDenied, ["permission_denied", "permission_error", "access denied", "not authorized"]),
            (.timeout, ["context deadline exceeded", "i/o timeout", "timed out", "request_timeout", "tls handshake timeout", "timeout awaiting response headers"]),
            (.connection, ["connection refused", "connection reset", "no such host", "tls handshake", "dial tcp", "closed network connection", "unexpected eof"]),
            (.overloaded, ["overloaded_error", "server overloaded", "capacity exceeded"]),
            (.rateLimited, ["rate_limit_exceeded", "rate_limit_error", "too many requests", "rate limit reached", "rate limit exceeded", "请求过于频繁"]),
            (.invalidRequest, ["invalid_request_error", "invalid_argument", "bad_request"]),
            (.serverError, ["internal_server_error", "server_error"])
        ]
        return rules.first { $0.1.contains(where: text.contains) }?.0
    }

    /// 跨字段仍按明确程度取值，不依赖 JSON 字段遍历顺序。
    static func preferred(_ kinds: [Self]) -> Self? {
        let order: [Self] = [.quotaExhausted, .noAvailableAccount, .contextTooLong, .modelUnavailable,
            .authentication, .permissionDenied, .timeout, .connection, .overloaded, .rateLimited, .invalidRequest, .serverError]
        return order.first(where: kinds.contains)
    }
}

/// CPA 的 fail.body 通常是包含 JSON 的字符串，也兼容对象／数组。
/// 只访问错误字段；忽略 prompt、headers、api_key 等任意业务字段，避免误分类。
/// 超大正文和过深结构不做识别，原始字符串在此临时解码后立即释放。
nonisolated struct CPAUsageFailureSignal: Decodable {
    let kind: CPAUsageFailureKind?
    private enum Keys: String, CodingKey { case error, errors, code, type, message, detail, details, reason, status }

    init(from decoder: Decoder) throws {
        guard decoder.codingPath.count < 16 else { kind = nil; return }
        let value = try decoder.singleValueContainer()
        if let text = try? value.decode(String.self) {
            guard text.utf8.count <= 32_768 else { kind = nil; return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                // JSON 字符串只按错误字段读，不把完整 JSON 当普通文本匹配提示词。
                kind = (try? JSONDecoder().decode(Self.self, from: Data(trimmed.utf8)))?.kind
            } else { kind = CPAUsageFailureKind.recognize(trimmed) }
        } else if let fields = try? decoder.container(keyedBy: Keys.self) {
            kind = CPAUsageFailureKind.preferred(fields.allKeys.compactMap {
                (try? fields.decode(Self.self, forKey: $0))?.kind
            })
        } else if var items = try? decoder.unkeyedContainer() {
            var kinds: [CPAUsageFailureKind] = [], count = 0
            while !items.isAtEnd && count < 16 {
                if let kind = try? Self(from: items.superDecoder()).kind { kinds.append(kind) }
                count += 1
            }
            kind = CPAUsageFailureKind.preferred(kinds)
        } else { kind = nil }
    }
}

/// 两处路由 UI 共用解释，成功／主动取消不显示失败处理建议。
/// 正文分类与状态码解释分别标注来源，不声称归一状态码是厂商原始响应。
nonisolated struct CPAUsageFailureExplanation: Sendable, Equatable {
    enum Evidence: Sendable, Equatable { case errorInformation, statusCode, unavailable }
    let kind: CPAUsageFailureKind
    let status: Int?
    let evidence: Evidence

    static func make(for event: CPAUsageEvent) -> Self? {
        guard event.outcome == .failed else { return nil }
        if let kind = event.context.failureKind, kind != .unknown {
            return Self(kind: kind, status: event.context.statusCode, evidence: .errorInformation)
        }
        let status = event.context.statusCode
        let knownStatus = status.map { (400...599).contains($0) } ?? false
        return Self(kind: .from(status: status), status: status, evidence: knownStatus ? .statusCode : .unavailable)
    }

    @MainActor var summary: String {
        [status.map { "HTTP \($0)" }, kind.titleKey.localized()].compactMap { $0 }.joined(separator: " · ")
    }
    var evidenceKey: String {
        switch evidence {
        case .errorInformation: "routing.failure.evidence.error"
        case .statusCode: "routing.failure.evidence.status"
        case .unavailable: "routing.failure.evidence.unavailable"
        }
    }
    @MainActor var help: String {
        [summary, kind.reasonKey.localized(), kind.adviceKey.localized(), evidenceKey.localized()].joined(separator: "\n")
    }
}
